#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ACTION="${1:-build}"
PROFILE="${2:-${AT91BOOTSTRAP_PROFILE:-sd}}"
TOOLCHAIN_PREFIX="${AT91BOOTSTRAP_TOOLCHAIN_PREFIX:-arm-linux-gnueabihf-}"
CROSS_COMPILE="$TOOLCHAIN_PREFIX"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

die()
{
    echo "error: $*" >&2
    exit 1
}

case "$PROFILE" in
    sd)
        DEFCONFIG=nextgen_sd_uboot_defconfig
        OUT="${AT91BOOTSTRAP_OUT:-$ROOT/build-sd}"
        ;;
    nor)
        DEFCONFIG=nextgen_nor_uboot_defconfig
        OUT="${AT91BOOTSTRAP_OUT:-$ROOT/build-nor}"
        ;;
    *)
        die "unknown profile '$PROFILE' (expected sd or nor)"
        ;;
esac

command -v "${TOOLCHAIN_PREFIX}gcc" >/dev/null 2>&1 ||
    die "ARM compiler not found: ${TOOLCHAIN_PREFIX}gcc"

make_bootstrap()
{
    make -C "$ROOT" CROSS_COMPILE="$CROSS_COMPILE" BUILDDIR="$OUT" "$@"
}

configure()
{
    make_bootstrap "$DEFCONFIG"

    case "$PROFILE" in
        sd)
            grep -q '^CONFIG_SDCARD=y$' "$ROOT/.config" ||
                die "SD profile did not enable CONFIG_SDCARD"
            grep -q '^CONFIG_SDHC0=y$' "$ROOT/.config" ||
                die "SD profile did not enable CONFIG_SDHC0"
            grep -q '^CONFIG_MMC_NONREMOVABLE=y$' "$ROOT/.config" ||
                die "SD profile did not enable forced card detect"
            grep -q '^# CONFIG_SDHC_NODMA is not set$' "$ROOT/.config" ||
                die "SD profile unexpectedly disabled SDHC DMA"
            grep -q '^CONFIG_QUIET_SUCCESS=y$' "$ROOT/.config" ||
                die "SD profile did not enable quiet successful boot"
            grep -q '^# CONFIG_HW_DISPLAY_BANNER is not set$' "$ROOT/.config" ||
                die "SD profile still enables bootstrap banner"
            ;;
        nor)
            grep -q '^CONFIG_DATAFLASH=y$' "$ROOT/.config" ||
                die "NOR profile did not enable CONFIG_DATAFLASH"
            grep -q '^CONFIG_SPI=y$' "$ROOT/.config" ||
                die "NOR profile did not enable CONFIG_SPI"
            grep -q '^CONFIG_SPI_BUS=1$' "$ROOT/.config" ||
                die "NOR profile is not using SPI bus 1"
            grep -q '^CONFIG_IMG_ADDRESS="0x00008000"$' "$ROOT/.config" ||
                die "NOR U-Boot address changed unexpectedly"
            ;;
    esac

    grep -q '^CONFIG_JUMP_ADDR="0x23f00000"$' "$ROOT/.config" ||
        die "unexpected U-Boot jump address"

    echo "Configured NextGen AT91Bootstrap profile: $PROFILE"
}

build_image()
{
    make_bootstrap -j"$JOBS" all

    BOOT="$OUT/binaries/boot.bin"
    [ -e "$BOOT" ] || die "boot.bin was not produced at $BOOT"

    echo
    echo "NextGen AT91Bootstrap build complete:"
    echo "  profile = $PROFILE"
    echo "  output  = $BOOT"
    ls -lh "$BOOT"
    sha256sum "$BOOT"
}

case "$ACTION" in
    config)
        configure
        ;;
    build)
        configure
        build_image
        ;;
    rebuild)
        rm -rf "$OUT"
        configure
        build_image
        ;;
    clean)
        rm -rf "$OUT"
        echo "Removed $OUT"
        ;;
    *)
        echo "Usage: $0 [build|rebuild|config|clean] [sd|nor]" >&2
        exit 2
        ;;
esac
