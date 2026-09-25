// Copyright (C) 2026 Castle Group
//
// SPDX-License-Identifier: MIT

/*
 * Castle NextGen SAMA5D27 boot-configuration fuse guard.
 *
 * The fixed production fuse word and PA29 VPP enable are inherited from the
 * historical SAM-BA burnfuse.sh flow.  The programming clock sequence mirrors
 * Microchip's published SAMA5D2 SAM-BA internalrc applet and the SFC register
 * sequence mirrors the published Softpack SFC driver.
 *
 * This code is intentionally resident in every normal NextGen bootstrap:
 *
 *   - if the fuse is already 0x00060b3f, nothing is changed;
 *   - programming is allowed only if (current | target) == target, because OTP
 *     can only change 0 -> 1 and the resulting word must be exactly the fixed
 *     NextGen target;
 *   - incompatible silicon/OTP never energises VPP; a programming/verify
 *     failure gets no second write attempt in that boot, and none of these
 *     conditions prevents the normal bootstrap from continuing;
 *   - VPP is always removed before returning to the normal clock/bootstrap path.
 *
 * The check runs before hw_init(), while AT91Bootstrap still executes entirely
 * from SRAM and before DDR has been configured.
 */

#include "hardware.h"
#include "board.h"
#include "debug.h"
#include "pmc.h"
#include "timer.h"
#include "usart.h"
#include "nextgen_fuse.h"
#include "arch/at91_pio.h"
#include "arch/at91_pmc/pmc.h"
#include "arch/sama5d2.h"

#define NEXTGEN_BOOTCFG_WORD		0x00060b3fU
#define NEXTGEN_BOOTCFG_FUSE_INDEX	16U

#define NEXTGEN_VPP_MASK		(1U << 29)	/* PA29, active high */
#define NEXTGEN_VPP_SETTLE_MS		50U
#define NEXTGEN_VPP_DISCHARGE_MS	10U

#define SFC_KR				0x00
#define SFC_SR				0x1c
#define SFC_DR(index)			(0x20 + ((index) * 4))
#define SFC_KEY				0xfbU
#define SFC_SR_PGMC			(1U << 0)
#define SFC_SR_PGMF			(1U << 1)
#define SFC_SR_LCHECK			(1U << 4)
#define SFC_SR_APLE			(1U << 16)
#define SFC_SR_ACE			(1U << 17)
#define SFC_ERROR_MASK			(SFC_SR_PGMF | SFC_SR_LCHECK | \
					 SFC_SR_APLE | SFC_SR_ACE)

/*
 * Microchip SAMA5D2 internalrc applet values:
 *   MAINCK = internal 12 MHz RC
 *   PLLA   = 12 MHz * (62 + 1) = 756 MHz
 *   PCK    = PLLA / 2 = 378 MHz
 *   MCK    = PCK / 3 = 126 MHz
 */
#define NEXTGEN_FUSE_PLLA		(AT91C_CKGR_SRCA | \
					 (0x10U << 8) | \
					 (62U << 18) | \
					 AT91C_CKGR_DIVA_BYPASS)

#define NEXTGEN_FUSE_MCK		(AT91C_PMC_H32MXDIV_H32MXDIV2 | \
					 AT91C_PMC_PLLADIV2_2 | \
					 AT91C_PMC_MDIV_3 | \
					 AT91C_PMC_PRES_ALT_CLK)

#define NEXTGEN_FUSE_MCK_MASK		(AT91C_PMC_H32MXDIV | \
					 AT91C_PMC_PLLADIV2 | \
					 AT91C_PMC_MDIV | \
					 AT91C_PMC_ALT_PRES | \
					 AT91C_PMC_CSS)

#if BOARD_MAINOSC != 12000000
#error "NextGen fuse guard must be built for the 12 MHz board clock"
#endif

#if !defined(CONFIG_CPU_CLK_498MHZ) || !defined(CONFIG_BUS_SPEED_166MHZ)
#error "NextGen fuse guard expects the normal 498/166 MHz NextGen clock plan"
#endif

#if !defined(CONFIG_MCK_BYPASS)
#error "NextGen fuse guard expects the production external-clock bypass input"
#endif

static unsigned int observed_fuse;

static int nextgen_is_sama5d27(void)
{
	unsigned int cidr;
	unsigned int exid;

	cidr = readl(AT91C_BASE_CHIPID + CHIPID_CIDR);
	if ((cidr & 0x7fffffe0U) != SAMA5D2_CIDR)
		return 0;

	exid = readl(AT91C_BASE_CHIPID + CHIPID_EXID);
	switch (exid) {
	case SAMA5D27C_D1G_EXID:
	case SAMA5D27C_D5M_EXID:
	case SAMA5D27C_LD1G_EXID:
	case SAMA5D27C_LD2G_EXID:
	case SAMA5D27CU_EXID:
	case SAMA5D27CN_EXID:
		return 1;
	default:
		return 0;
	}
}

static unsigned int nextgen_sfc_read_bootcfg(void)
{
	return readl(AT91C_BASE_SFC + SFC_DR(NEXTGEN_BOOTCFG_FUSE_INDEX));
}

static void nextgen_vpp_prepare_off(void)
{
	pmc_enable_periph_clock(AT91C_ID_PIOA, PMC_PERIPH_CLK_DIVIDER_NA);

	/*
	 * Force the output latch low before changing PA29 to GPIO output so a
	 * direction change cannot create a VPP pulse.
	 */
	writel(NEXTGEN_VPP_MASK, AT91C_BASE_PIOA + PIO_MSKR);
	writel(NEXTGEN_VPP_MASK, AT91C_BASE_PIOA + PIO_CODR);
	writel(AT91C_PIO_CFGR_FUNC_GPIO | AT91C_PIO_CFGR_DIR,
	       AT91C_BASE_PIOA + PIO_CFGR);
}

static void nextgen_vpp_set(int on)
{
	writel(NEXTGEN_VPP_MASK, AT91C_BASE_PIOA + PIO_MSKR);
	writel(NEXTGEN_VPP_MASK,
	       AT91C_BASE_PIOA + (on ? PIO_SODR : PIO_CODR));
}

static void nextgen_select_internal_rc_clock(void)
{
	unsigned int reg;

	/* Get execution off MAINCK before changing the MAINCK source. */
	pmc_mck_cfg_set(0, AT91C_PMC_CSS_SLOW_CLK, AT91C_PMC_CSS);

	/* Ensure the internal 12 MHz RC is running. */
	reg = read_pmc(PMC_MOR);
	reg &= ~AT91C_CKGR_KEY;
	reg |= AT91C_CKGR_MOSCRCEN | AT91C_CKGR_PASSWD;
	write_pmc(PMC_MOR, reg);
	while (!(read_pmc(PMC_SR) & AT91C_PMC_MOSCRCS))
		;

	/* Select the internal RC as MAINCK. */
	reg = read_pmc(PMC_MOR);
	reg &= ~(AT91C_CKGR_MOSCSEL | AT91C_CKGR_KEY);
	reg |= AT91C_CKGR_PASSWD;
	write_pmc(PMC_MOR, reg);
	while (read_pmc(PMC_SR) & AT91C_PMC_MOSCSELS)
		;

	/*
	 * Match Microchip's internalrc applet.  Establish the divisors while
	 * execution remains on the slow clock, then configure PLLA and select it.
	 */
	pmc_mck_cfg_set(0,
			NEXTGEN_FUSE_MCK | AT91C_PMC_CSS_SLOW_CLK,
			NEXTGEN_FUSE_MCK_MASK);
	pmc_cfg_plla(NEXTGEN_FUSE_PLLA);
	pmc_mck_cfg_set(0,
			NEXTGEN_FUSE_MCK | AT91C_PMC_CSS_PLLA_CLK,
			NEXTGEN_FUSE_MCK_MASK);
}

static void nextgen_restore_external_main_clock(void)
{
	unsigned int reg;

	/*
	 * lowlevel_clock_init() ran before main(), so the external 12 MHz bypass
	 * source is already enabled and remains running while the RC is selected.
	 */
	pmc_mck_cfg_set(0, AT91C_PMC_CSS_SLOW_CLK, AT91C_PMC_CSS);

	reg = read_pmc(PMC_MOR);
	reg &= ~AT91C_CKGR_KEY;
	reg |= AT91C_CKGR_MOSCSEL | AT91C_CKGR_PASSWD;
	write_pmc(PMC_MOR, reg);
	while (!(read_pmc(PMC_SR) & AT91C_PMC_MOSCSELS))
		;

	/*
	 * Return to external MAINCK.  Normal hw_init() follows immediately and
	 * creates the ordinary 498 MHz PCK / 166 MHz MCK clock plan.
	 */
	pmc_mck_cfg_set(0,
			AT91C_PMC_CSS_MAIN_CLK | AT91C_PMC_PRES_ALT_CLK,
			AT91C_PMC_CSS | AT91C_PMC_ALT_PRES);
}

static int nextgen_sfc_program_bootcfg(unsigned int *status_out)
{
	unsigned int status = 0;
	unsigned int timeout;

	pmc_enable_periph_clock(AT91C_ID_SFC, PMC_PERIPH_CLK_DIVIDER_NA);

	/* Clear stale clear-on-read status before arming programming. */
	(void)readl(AT91C_BASE_SFC + SFC_SR);

	writel(SFC_KEY, AT91C_BASE_SFC + SFC_KR);
	writel(NEXTGEN_BOOTCFG_WORD,
	       AT91C_BASE_SFC + SFC_DR(NEXTGEN_BOOTCFG_FUSE_INDEX));

	/*
	 * Microchip's applet polls PGMC without a timeout.  Keep the same
	 * completion condition but bound it so a hardware fault cannot leave VPP
	 * enabled forever.
	 */
	for (timeout = 0; timeout < 1000000U; timeout++) {
		status = readl(AT91C_BASE_SFC + SFC_SR);
		if (status & SFC_SR_PGMC)
			break;
		udelay(1);
	}

	pmc_disable_periph_clock(AT91C_ID_SFC);

	*status_out = status;
	if (!(status & SFC_SR_PGMC))
		return -1;
	if (status & SFC_ERROR_MASK)
		return -1;

	return 0;
}

int nextgen_boot_fuse_ensure(void)
{
	unsigned int current;
	unsigned int readback;
	unsigned int status = 0;
	int ret;

	if (!nextgen_is_sama5d27())
		return NEXTGEN_FUSE_WRONG_SOC;

	/* On genuine NextGen silicon, make the fuse programming rail explicitly off. */
	nextgen_vpp_prepare_off();

	current = nextgen_sfc_read_bootcfg();
	observed_fuse = current;

	if (current == NEXTGEN_BOOTCFG_WORD)
		return NEXTGEN_FUSE_OK;

	/*
	 * OTP cannot clear an existing 1-bit.  This test is the central safety
	 * invariant: after programming the deliberate target, the result must be
	 * exactly the target and nothing else.
	 */
	if ((current | NEXTGEN_BOOTCFG_WORD) != NEXTGEN_BOOTCFG_WORD)
		return NEXTGEN_FUSE_INCOMPATIBLE;

	nextgen_select_internal_rc_clock();

	/*
	 * timer_init() is repeated by normal hw_init().  Here it only provides
	 * conservative VPP delays.  The helper clock is slower than the normal
	 * compile-time NextGen MCK, so these waits err on the long side.
	 */
	timer_init();
	mdelay(NEXTGEN_VPP_DISCHARGE_MS);
	nextgen_vpp_set(1);
	mdelay(NEXTGEN_VPP_SETTLE_MS);

	ret = nextgen_sfc_program_bootcfg(&status);
	readback = nextgen_sfc_read_bootcfg();

	/* VPP is always removed before clocks are restored or boot continues. */
	nextgen_vpp_set(0);
	mdelay(NEXTGEN_VPP_DISCHARGE_MS);

	nextgen_restore_external_main_clock();

	observed_fuse = readback;

	if (ret)
		return NEXTGEN_FUSE_PROGRAM_FAILED;
	if (readback != NEXTGEN_BOOTCFG_WORD)
		return NEXTGEN_FUSE_VERIFY_FAILED;

	return NEXTGEN_FUSE_PROGRAMMED;
}

void nextgen_boot_fuse_report(int status)
{
	switch (status) {
	case NEXTGEN_FUSE_OK:
		break;
	case NEXTGEN_FUSE_PROGRAMMED:
		usart_puts("FUSE: NextGen boot configuration programmed and verified\n");
		break;
	case NEXTGEN_FUSE_WRONG_SOC:
		usart_puts("FUSE: unexpected CPU; boot fuse not modified\n");
		break;
	case NEXTGEN_FUSE_INCOMPATIBLE:
		usart_puts("FUSE: incompatible existing boot fuse; not modified\n");
		break;
	case NEXTGEN_FUSE_PROGRAM_FAILED:
		usart_puts("FUSE: boot fuse programming failed; VPP is off\n");
		break;
	case NEXTGEN_FUSE_VERIFY_FAILED:
		usart_puts("FUSE: boot fuse verify failed; VPP is off\n");
		break;
	default:
		usart_puts("FUSE: unknown fuse status; VPP is off\n");
		break;
	}

#ifdef CONFIG_DEBUG
	if (status != NEXTGEN_FUSE_OK)
		dbg_printf("FUSE: observed boot configuration = %x\n", observed_fuse);
#endif
}
