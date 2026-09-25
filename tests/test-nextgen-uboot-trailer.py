#!/usr/bin/env python3
"""Native regression test of the actual SPI NOR trailer decoder.

No ARM toolchain, device access, NOR writes or OTP operations are performed.
Only nextgen_update_uboot_length is extracted from driver/spi_flash.c; the SPI
read and debug output are stubbed. This does not validate the hardware driver
or establish that an AT91Bootstrap image boots.
"""
from pathlib import Path
import os
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "driver/spi_flash.c").read_text(encoding="utf-8")
start = source.index("static int nextgen_update_uboot_length(")
end = source.index("\nint spi_flash_loadimage(", start)
decoder = source[start:end]

preamble = r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#define CONFIG_UBOOT_LENGTH_TRAILER 1
#define CONFIG_UBOOT_LENGTH_TRAILER_ADDRESS 0x0013fff0U
#define CONFIG_UBOOT_MAX_SIZE 0x00137ff0U
#define dbg_info(...) ((void)0)
struct dataflash_descriptor { unsigned int unused; };
struct image_info { unsigned int offset, length; };
static unsigned char input[16];
static int read_error;
static unsigned int reads;
static int read_array(struct dataflash_descriptor *df, unsigned int offset,
                      unsigned int length, unsigned char *out)
{
    (void)df;
    assert(offset == CONFIG_UBOOT_LENGTH_TRAILER_ADDRESS);
    assert(length == sizeof(input));
    ++reads;
    if (read_error) return -1;
    memcpy(out, input, sizeof(input));
    return 0;
}
'''
harness = r'''
static void le32(unsigned char *out, uint32_t value)
{
    for (unsigned int i = 0; i < 4; ++i)
        out[i] = (unsigned char)(value >> (8 * i));
}
static void trailer(uint32_t length, uint32_t version)
{
    memcpy(input, "NGUB", 4);
    le32(input + 4, length);
    le32(input + 8, ~length);
    le32(input + 12, version);
    read_error = 0;
}
static unsigned int cases;
static void check(unsigned int offset, unsigned int expected)
{
    /* A distinctive sentinel proves invalid metadata leaves the configured
     * fallback unchanged, rather than partially changing the image length. */
    struct image_info image = {offset, 0x12345U};
    struct dataflash_descriptor df = {0};
    reads = 0;
    assert(nextgen_update_uboot_length(&df, &image) == 0);
    assert(reads == 1);
    assert(image.length == expected);
    ++cases;
}
int main(void)
{
    trailer(0x56789U, 1); check(0x8000U, 0x56789U);
    trailer(1U, 1); check(0x8000U, 1U);
    trailer(CONFIG_UBOOT_MAX_SIZE, 1);
    check(0x8000U, CONFIG_UBOOT_MAX_SIZE);
    const uint32_t versions[] = {0U, 2U, 0x100U, UINT32_MAX};
    for (unsigned int i = 0; i < sizeof(versions)/sizeof(versions[0]); ++i) {
        trailer(0x56789U, versions[i]); check(0x8000U, 0x12345U);
    }
    for (unsigned int i = 0; i < 4; ++i) {
        trailer(0x56789U, 1); input[i] ^= 1; check(0x8000U, 0x12345U);
    }
    trailer(0x56789U, 1); input[8] ^= 1; check(0x8000U, 0x12345U);
    trailer(0U, 1); check(0x8000U, 0x12345U);
    trailer(CONFIG_UBOOT_MAX_SIZE + 1U, 1); check(0x8000U, 0x12345U);
    trailer(UINT32_MAX, 1); check(0x8000U, 0x12345U);
    trailer(CONFIG_UBOOT_MAX_SIZE, 1); check(0x8001U, 0x12345U);
    trailer(0x56789U, 1); read_error = 1; check(0x8000U, 0x12345U);
    memset(input, 0xff, sizeof(input)); read_error = 0;
    check(0x8000U, 0x12345U);
    printf("PASS: %u NOR trailer decoder cases\n", cases);
    return 0;
}
'''
with tempfile.TemporaryDirectory(prefix="nextgen-trailer-test-") as directory:
    work = Path(directory)
    test_source = work / "trailer.c"
    executable = work / "trailer-test"
    test_source.write_text(preamble + decoder + harness, encoding="utf-8")
    compiler = shlex.split(os.environ.get("CC", "cc"))
    subprocess.run(compiler + ["-std=c11", "-Wall", "-Wextra", "-Werror",
                   "-O2", str(test_source), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
