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
    timing)
        DEFCONFIG=nextgen_sd_uboot_timing_defconfig
        OUT="${AT91BOOTSTRAP_OUT:-$ROOT/build-sd-timing}"
        ;;
    timing-deferred)
        DEFCONFIG=nextgen_sd_uboot_timing_deferred_defconfig
        OUT="${AT91BOOTSTRAP_OUT:-$ROOT/build-sd-timing-deferred}"
        ;;
    nor)
        DEFCONFIG=nextgen_nor_uboot_defconfig
        OUT="${AT91BOOTSTRAP_OUT:-$ROOT/build-nor}"
        ;;
    *)
        die "unknown profile '$PROFILE' (expected sd, timing, timing-deferred or nor)"
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
        sd|timing|timing-deferred)
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
            if [ "$PROFILE" = "timing" ] || [ "$PROFILE" = "timing-deferred" ]; then
                grep -q '^CONFIG_BOOT_TIMING_MARKERS=y$' "$ROOT/.config" ||
                    die "timing profile did not enable timing markers"
            fi

            if [ "$PROFILE" = "timing-deferred" ]; then
                grep -q '^CONFIG_DEFER_SLOW_CLOCK_SWITCH=y$' "$ROOT/.config" ||
                    die "deferred timing profile did not defer slow clock switch"
            fi
            ;;
        nor)
            grep -q '^CONFIG_DATAFLASH=y$' "$ROOT/.config" ||
                die "NOR profile did not enable CONFIG_DATAFLASH"
            grep -q '^CONFIG_SPI=y$' "$ROOT/.config" ||
                die "NOR profile did not enable CONFIG_SPI"
            grep -q '^CONFIG_SPI_BUS=1$' "$ROOT/.config" ||
                die "NOR profile is not using SPI bus 1"
            grep -q '^CONFIG_SPI_CLK=50000000$' "$ROOT/.config" ||
                die "NOR SPI clock request changed unexpectedly"
            # Ratified 2 MiB NOR map:
            #   0x000000-0x007fff AT91Bootstrap
            #   0x008000-0x13ffff U-Boot partition
            #   0x140000-0x14ffff env A erase slot
            #   0x150000-0x15ffff env B erase slot
            #   0x160000-0x1fffff spare
            grep -q '^CONFIG_IMG_ADDRESS="0x00008000"$' "$ROOT/.config" ||
                die "NOR U-Boot address changed unexpectedly"
            # IMG_SIZE remains the compatibility fallback if the trailer is absent
            # or invalid. Normal production images carry a validated NGUB trailer
            # at the end of the U-Boot partition so only the actual payload bytes
            # are copied.
            grep -q '^CONFIG_IMG_SIZE="0x000a0000"
            ;;
    esac

    grep -q '^CONFIG_JUMP_ADDR="0x23f00000"$' "$ROOT/.config" ||
        die "unexpected U-Boot jump address"

    grep -q '^CONFIG_NEXTGEN_BOOT_FUSE_ENSURE=y$' "$ROOT/.config" ||
        die "NextGen profile did not enable boot fuse guard"

    echo "Configured NextGen AT91Bootstrap profile: $PROFILE"
}

build_image()
{
    make_bootstrap -j"$JOBS" all

    BOOT="$OUT/binaries/boot.bin"
    [ -e "$BOOT" ] || die "boot.bin was not produced at $BOOT"

    if [ "$PROFILE" = "nor" ]; then
        BOOT_BYTES="$(wc -c < "$BOOT" | tr -d '[:space:]')"
        [ "$BOOT_BYTES" -le $((0x8000)) ] ||
            die "NOR boot.bin exceeds 32 KiB AT91Bootstrap partition: $BOOT_BYTES bytes"
    fi

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
        echo "Usage: $0 [build|rebuild|config|clean] [sd|timing|timing-deferred|nor]" >&2
        exit 2
        ;;
esac
 "$ROOT/.config" ||
                die "NOR U-Boot fallback load size changed unexpectedly"
            grep -q '^CONFIG_UBOOT_LENGTH_TRAILER=y
            ;;
    esac

    grep -q '^CONFIG_JUMP_ADDR="0x23f00000"$' "$ROOT/.config" ||
        die "unexpected U-Boot jump address"

    grep -q '^CONFIG_NEXTGEN_BOOT_FUSE_ENSURE=y$' "$ROOT/.config" ||
        die "NextGen profile did not enable boot fuse guard"

    echo "Configured NextGen AT91Bootstrap profile: $PROFILE"
}

build_image()
{
    make_bootstrap -j"$JOBS" all

    BOOT="$OUT/binaries/boot.bin"
    [ -e "$BOOT" ] || die "boot.bin was not produced at $BOOT"

    if [ "$PROFILE" = "nor" ]; then
        BOOT_BYTES="$(wc -c < "$BOOT" | tr -d '[:space:]')"
        [ "$BOOT_BYTES" -le $((0x8000)) ] ||
            die "NOR boot.bin exceeds 32 KiB AT91Bootstrap partition: $BOOT_BYTES bytes"
    fi

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
        echo "Usage: $0 [build|rebuild|config|clean] [sd|timing|timing-deferred|nor]" >&2
        exit 2
        ;;
esac
 "$ROOT/.config" ||
                die "NOR U-Boot length trailer is disabled"
            grep -q '^CONFIG_UBOOT_LENGTH_TRAILER_ADDRESS=0x0013fff0
            ;;
    esac

    grep -q '^CONFIG_JUMP_ADDR="0x23f00000"$' "$ROOT/.config" ||
        die "unexpected U-Boot jump address"

    grep -q '^CONFIG_NEXTGEN_BOOT_FUSE_ENSURE=y$' "$ROOT/.config" ||
        die "NextGen profile did not enable boot fuse guard"

    echo "Configured NextGen AT91Bootstrap profile: $PROFILE"
}

build_image()
{
    make_bootstrap -j"$JOBS" all

    BOOT="$OUT/binaries/boot.bin"
    [ -e "$BOOT" ] || die "boot.bin was not produced at $BOOT"

    if [ "$PROFILE" = "nor" ]; then
        BOOT_BYTES="$(wc -c < "$BOOT" | tr -d '[:space:]')"
        [ "$BOOT_BYTES" -le $((0x8000)) ] ||
            die "NOR boot.bin exceeds 32 KiB AT91Bootstrap partition: $BOOT_BYTES bytes"
    fi

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
        echo "Usage: $0 [build|rebuild|config|clean] [sd|timing|timing-deferred|nor]" >&2
        exit 2
        ;;
esac
 "$ROOT/.config" ||
                die "NOR U-Boot length trailer address changed unexpectedly"
            grep -q '^CONFIG_UBOOT_MAX_SIZE=0x00137ff0
            ;;
    esac

    grep -q '^CONFIG_JUMP_ADDR="0x23f00000"$' "$ROOT/.config" ||
        die "unexpected U-Boot jump address"

    grep -q '^CONFIG_NEXTGEN_BOOT_FUSE_ENSURE=y$' "$ROOT/.config" ||
        die "NextGen profile did not enable boot fuse guard"

    echo "Configured NextGen AT91Bootstrap profile: $PROFILE"
}

build_image()
{
    make_bootstrap -j"$JOBS" all

    BOOT="$OUT/binaries/boot.bin"
    [ -e "$BOOT" ] || die "boot.bin was not produced at $BOOT"

    if [ "$PROFILE" = "nor" ]; then
        BOOT_BYTES="$(wc -c < "$BOOT" | tr -d '[:space:]')"
        [ "$BOOT_BYTES" -le $((0x8000)) ] ||
            die "NOR boot.bin exceeds 32 KiB AT91Bootstrap partition: $BOOT_BYTES bytes"
    fi

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
        echo "Usage: $0 [build|rebuild|config|clean] [sd|timing|timing-deferred|nor]" >&2
        exit 2
        ;;
esac
 "$ROOT/.config" ||
                die "NOR U-Boot maximum payload size changed unexpectedly"
            ;;
    esac

    grep -q '^CONFIG_JUMP_ADDR="0x23f00000"$' "$ROOT/.config" ||
        die "unexpected U-Boot jump address"

    grep -q '^CONFIG_NEXTGEN_BOOT_FUSE_ENSURE=y$' "$ROOT/.config" ||
        die "NextGen profile did not enable boot fuse guard"

    echo "Configured NextGen AT91Bootstrap profile: $PROFILE"
}

build_image()
{
    make_bootstrap -j"$JOBS" all

    BOOT="$OUT/binaries/boot.bin"
    [ -e "$BOOT" ] || die "boot.bin was not produced at $BOOT"

    if [ "$PROFILE" = "nor" ]; then
        BOOT_BYTES="$(wc -c < "$BOOT" | tr -d '[:space:]')"
        [ "$BOOT_BYTES" -le $((0x8000)) ] ||
            die "NOR boot.bin exceeds 32 KiB AT91Bootstrap partition: $BOOT_BYTES bytes"
    fi

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
        echo "Usage: $0 [build|rebuild|config|clean] [sd|timing|timing-deferred|nor]" >&2
        exit 2
        ;;
esac
