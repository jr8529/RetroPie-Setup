#!/usr/bin/env bash

# This file is part of The RetroPie Project
#
# The RetroPie Project is the legal property of its developers, whose names are
# too numerous to list here. Please refer to the COPYRIGHT.md file distributed with this source.
#
# See the LICENSE.md file at the top-level directory of this distribution and
# at https://raw.githubusercontent.com/RetroPie/RetroPie-Setup/master/LICENSE.md
#

function setup_env() {

    __ERRMSGS=()
    __INFMSGS=()

    # if no apt-get we need to fail
    [[ -z "$(which apt-get)" ]] && fatalError "Unsupported OS - No apt-get command found"

    test_chroot

    get_platform
    get_os_version

    get_retropie_depends

    install_local_debs

    conf_memory_vars
    conf_binary_vars
    conf_build_vars

    if [[ -z "$__nodialog" ]]; then
        __nodialog=0
    fi
}

function test_chroot() {
    # test if we are in a chroot
    if [[ "$(stat -c %d:%i /)" != "$(stat -c %d:%i /proc/1/root/.)" ]]; then
        [[ -z "$QEMU_CPU" && -n "$__qemu_cpu" ]] && export QEMU_CPU=$__qemu_cpu
        __chroot=1
    else
        __chroot=0
    fi
}


function conf_memory_vars() {
    __memory_total_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
    __memory_total=$(( "$__memory_total_kb" / 1024 ))
    if grep -q "^MemAvailable:" /proc/meminfo; then
        __memory_avail_kb=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
    else
        local mem_free=$(awk '/^MemFree:/{print $2}' /proc/meminfo)
        local mem_cached=$(awk '/^Cached:/{print $2}' /proc/meminfo)
        local mem_buffers=$(awk '/^Buffers:/{print $2}' /proc/meminfo)
        __memory_avail_kb=$((mem_free + mem_cached + mem_buffers))
    fi
    __memory_avail=$(( "$__memory_avail_kb" / 1024 ))
}

function conf_binary_vars() {
    [[ -z "$__has_binaries" ]] && __has_binaries=0

    # set location of binary downloads
    __binary_host="files.retropie.org.uk"
    __binary_base_url="https://$__binary_host/binaries"

    __binary_path="$__os_codename/$__platform"
    isPlatform "kms" && __binary_path+="/kms"
    __binary_url="$__binary_base_url/$__binary_path"

    __archive_url="https://files.retropie.org.uk/archives"
}

function conf_build_vars() {
    __gcc_version=$(gcc -dumpversion)

    # calculate build concurrency based on cores and available memory
    __jobs=1
    if [[ "$(nproc)" -gt 1 ]]; then
        # if we have less than 1gb of ram free, then limit build jobs to 2
        if [[ "$__memory_avail" -lt 1024 ]]; then
           __jobs=2
        else
           __jobs=$(nproc)
        fi
    fi
    __default_makeflags="-j${__jobs}"

    # set our default gcc optimisation level
    if [[ -z "$__opt_flags" ]]; then
        __opt_flags="$__default_opt_flags"
        # -pipe is faster but will use more memory - so let's only add it if we have at least 512MB ram.
        [[ "$__memory_avail" -ge 512 ]] && __opt_flags+=" -pipe"
    fi

    # set default cpu flags
    [[ -z "$__cpu_flags" ]] && __cpu_flags="$__default_cpu_flags"

    # if default cxxflags is empty, use our default cflags
    [[ -z "$__default_cxxflags" ]] && __default_cxx_flags="$__default_cflags"

    # add our cpu and optimisation flags
    __default_cflags+=" $__cpu_flags $__opt_flags"
    __default_cxxflags+=" $__cpu_flags $__opt_flags"

    # if not overridden by user, configure our compiler flags
    [[ -z "$__cflags" ]] && __cflags="$__default_cflags"
    [[ -z "$__cxxflags" ]] && __cxxflags="$__default_cxxflags"
    [[ -z "$__asflags" ]] && __asflags="$__default_asflags"
    [[ -z "$__makeflags" ]] && __makeflags="$__default_makeflags"

    # workaround for GCC ABI incompatibility with threaded armv7+ C++ apps built
    # on Raspbian's armv6 userland https://github.com/raspberrypi/firmware/issues/491
    if [[ "$__os_id" == "Raspbian" ]] && compareVersions $__gcc_version lt 5.0.0; then
        __cxxflags+=" -U__GCC_HAVE_SYNC_COMPARE_AND_SWAP_2"
    fi

    # export our compiler flags so all child processes can see them
    export CFLAGS="$__cflags"
    export CXXFLAGS="$__cxxflags"
    export ASFLAGS="$__asflags"
    export MAKEFLAGS="$__makeflags"

    # if using distcc, add /usr/lib/distcc to PATH/MAKEFLAGS
    if [[ -n "$DISTCC_HOSTS" ]]; then
        PATH="/usr/lib/distcc:$PATH"
        MAKEFLAGS+=" PATH=$PATH"
    fi
}

function get_os_version() {
    # make sure lsb_release is installed
    getDepends lsb-release

    # get os distributor id, description, release number and codename
    local os
    # armbian uses a minimal shell script replacement for lsb_release with basic
    # parameter parsing that requires the arguments split rather than using -sidrc
    mapfile -t os < <(lsb_release -s -i -d -r -c)
    __os_id="${os[0]}"
    __os_desc="${os[1]}"
    __os_release="${os[2]}"
    __os_codename="${os[3]}"

    local error=""
    case "$__os_id" in
        Raspbian|Debian)
            # get major version (8 instead of 8.0 etc)
            __os_debian_ver="${__os_release%%.*}"

            # Debian unstable is not officially supported though
            if [[ "$__os_release" == "unstable" ]]; then
                __os_debian_ver=11
            fi

            # we still allow Raspbian 8 (jessie) to work (We show an popup in the setup module)
            if compareVersions "$__os_debian_ver" lt 8; then
                error="You need Raspbian/Debian Stretch or newer"
            fi

            # set a platform flag for osmc
            if grep -q "ID=osmc" /etc/os-release; then
                __platform_flags+=" osmc"
            fi

            # and for xbian
            if grep -q "NAME=XBian" /etc/os-release; then
                __platform_flags+=" xbian"
            fi

            # we provide binaries for RPI on Raspbian 9/10
            if isPlatform "rpi" && compareVersions "$__os_debian_ver" gt 8 && compareVersions "$__os_debian_ver" lt 11; then
               # only set __has_binaries if not already set
               [[ -z "$__has_binaries" ]] && __has_binaries=1
            fi
            ;;
        Devuan)
            if isPlatform "rpi"; then
                error="We do not support Devuan on the Raspberry Pi. We recommend you use Raspbian to run RetroPie."
            fi
            # devuan lsb-release version numbers don't match jessie
            case "$__os_codename" in
                jessie)
                    __os_debian_ver="8"
                    ;;
                ascii)
                    __os_debian_ver="9"
                    ;;
                beowolf)
                    __os_debian_ver="10"
                    ;;
                ceres)
                    __os_debian_ver="11"
                    ;;
            esac
            ;;
        LinuxMint)
            if [[ "$__os_desc" != LMDE* ]]; then
                if compareVersions "$__os_release" lt 18; then
                    error="You need Linux Mint 18 or newer"
                elif compareVersions "$__os_release" lt 19; then
                    __os_ubuntu_ver="16.04"
                    __os_debian_ver="9"
                else
                    __os_ubuntu_ver="18.04"
                    __os_debian_ver="10"
                fi
            fi
            ;;
        Ubuntu|neon)
            if compareVersions "$__os_release" lt 16.04; then
                error="You need Ubuntu 16.04 or newer"
            # although ubuntu 16.10 reports as being based on stretch it is before some
            # packages were changed - we map to version 8 to avoid issues (eg libpng-dev name)
            elif compareVersions "$__os_release" eq 16.10; then
                __os_debian_ver="8"
            elif compareVersions "$__os_release" lt 18.04; then
                __os_debian_ver="9"
            else
                __os_debian_ver="10"
            fi
            __os_ubuntu_ver="$__os_release"
            ;;
        Zorin)
            if compareVersions "$__os_release" lt 14; then
                error="You need Zorin OS 14 or newer"
            elif compareVersions "$__os_release" lt 14; then
                __os_debian_ver="8"
            else
                __os_debian_ver="9"
            fi
            __os_ubuntu_ver="$__os_release"
            ;;
        Deepin)
            if compareVersions "$__os_release" lt 15.5; then
                error="You need Deepin OS 15.5 or newer"
            fi
            __os_debian_ver="9"
            ;;
        elementary)
            if compareVersions "$__os_release" lt 0.4; then
                error="You need Elementary OS 0.4 or newer"
            elif compareVersions "$__os_release" eq 0.4; then
                __os_ubuntu_ver="16.04"
                __os_debian_ver="8"
            else
                __os_ubuntu_ver="18.04"
                __os_debian_ver="10"
            fi
            ;;
        *)
            error="Unsupported OS"
            ;;
    esac

    [[ -n "$error" ]] && fatalError "$error\n\n$(lsb_release -idrc)"

    # add 32bit/64bit to platform flags
    __platform_flags+=" $(getconf LONG_BIT)bit"

    # configure Raspberry Pi graphics stack
    isPlatform "rpi" && get_rpi_video
}

function get_retropie_depends() {
    local depends=(git dialog wget gcc g++ build-essential unzip xmlstarlet ca-certificates)

    if [[ "$__os_debian_ver" = "11" ]]; then
        depends+=(python3-pyudev)
    else
        depends+=(python-pyudev)
    fi

    [[ -n "$DISTCC_HOSTS" ]] && depends+=(distcc)

    if ! getDepends "${depends[@]}"; then
        fatalError "Unable to install packages required by $0 - ${md_ret_errors[@]}"
    fi

    # make sure we don't have xserver-xorg-legacy installed as it breaks launching x11 apps from ES
    if ! isPlatform "x11" && hasPackage "xserver-xorg-legacy"; then
        aptRemove xserver-xorg-legacy
    fi
}

function install_local_debs() {
    if [[ -d "debs/$__platform/$__os_vendor/$__os_id/$__os_release" ]]; then
        echo "Detected local package directory for $__platform/$__os_vendor/$__os_id/$__os_release - installing"
        dpkg -i "debs/$__platform/$__os_vendor/$__os_id/$__os_release"/*.deb
        apt --fix-broken install
    fi
}

function get_rpi_video() {
    local pkgconfig="/opt/vc/lib/pkgconfig"

    if [[ -z "$__has_kms" ]]; then
        # in chroot, use kms by default for rpi4 target
        [[ "$__chroot" -eq 1 ]] && isPlatform "rpi4" && __has_kms=1
        # detect driver via inserted module / platform driver setup
        [[ -d "/sys/module/vc4" ]] && __has_kms=1
    fi

    if [[ "$__has_kms" -eq 1 ]]; then
        __platform_flags+=" mesa kms"
        [[ "$(ls -A /sys/bus/platform/drivers/vc4_firmware_kms/*.firmwarekms 2>/dev/null)" ]] && __platform_flags+=" dispmanx"
    else
        __platform_flags+=" videocore dispmanx"
    fi

    # delete legacy pkgconfig that conflicts with Mesa (may be installed via rpi-update)
    # see: https://github.com/raspberrypi/userland/pull/585
    rm -rf $pkgconfig/{egl.pc,glesv2.pc,vg.pc}

    # set pkgconfig path for vendor libraries
    export PKG_CONFIG_PATH="$pkgconfig"
}

function get_platform() {
    local architecture="$(uname --machine)"

    if [[ -r "/etc/armbian-release" ]]; then
        __os_vendor="armbian"
        case "$(grep 'BOARD=' /etc/armbian-release | cut -d'=' -f2)" in
            odroidc2)
                __platform="odroid-c2"
                ;;
            lepotato)
                __platform="odroid-c2"
                ;;
            tritium-h5)
                __platform="odroid-c2"
                ;;
            renegade)
                __platform="renegade"
                ;;
            tritium-h3)
                __platform="armv7-kms"
                ;;
            rockpi-4b)
                __platform="rockpi4"
                ;;
        esac
    fi

    if $(uname --release | grep -q tegra); then
        __os_vendor="nvidia"
        case "$(cat /sys/firmware/devicetree/base/model)" in
            Jetson-TX1)
                __platform="jetson-tx1"
                ;;
            Jetson-TX2)
                __platform="jetson-tx2"
                ;;
            "NVIDIA Jetson Nano Developer Kit")
                __platform="jetson-nano"
                ;;
            "NVIDIA Jetson Nano 2GB Developer Kit")
                __platform="jetson-nano"
                ;;
            Jetson-AGX)
                __platform="jetson-agx"
                ;;
        esac
    fi

    if [[ -z "$__platform" ]]; then
        case "$(sed -n '/^Hardware/s/^.*: \(.*\)/\1/p' < /proc/cpuinfo)" in
            BCM*)
                # calculated based on information from https://github.com/AndrewFromMelbourne/raspberry_pi_revision
                local rev="0x$(sed -n '/^Revision/s/^.*: \(.*\)/\1/p' < /proc/cpuinfo)"
                # if bit 23 is not set, we are on a rpi1 (bit 23 means the revision is a bitfield)
                if [[ $((($rev >> 23) & 1)) -eq 0 ]]; then
                    __platform="rpi1"
                else
                    # if bit 23 is set, get the cpu from bits 12-15
                    local cpu=$((($rev >> 12) & 15))
                    case $cpu in
                        0)
                            __platform="rpi1"
                            ;;
                        1)
                            __platform="rpi2"
                            ;;
                        2)
                            __platform="rpi3"
                            ;;
                        3)
                            __platform="rpi4"
                            ;;
                    esac
                fi
                ;;
            ODROIDC)
                __platform="odroid-c1"
                ;;
            ODROID-C2)
                __platform="odroid-c2"
                ;;
            "Freescale i.MX6 Quad/DualLite (Device Tree)")
                __platform="imx6"
                ;;
            ODROID-XU[34])
                __platform="odroid-xu"
                ;;
            "Rockchip (Device Tree)")
                __platform="tinker"
                ;;
            Vero4K|Vero4KPlus)
                __platform="vero4k"
                ;;
            "Allwinner sun8i Family")
                __platform="armv7-mali"
                ;;
            "Khadas VIM3")
                __platform="khadas-vim3"
                ;;
            *)
                case $architecture in
                    i686|x86_64|amd64)
                        __platform="x86"
                        ;;
                esac
                ;;
        esac
    fi

    if ! fnExists "platform_${__platform}"; then
        fatalError "Unknown platform - please manually set the __platform variable to one of the following: $(compgen -A function platform_ | cut -b10- | paste -s -d' ')"
    fi

    # check if we wish to target kms for platform
    if [[ -z "$__has_kms" ]]; then
        iniConfig " = " '"' "$configdir/all/retropie.cfg"
        iniGet "force_kms"
        [[ "$ini_value" == 1 ]] && __has_kms=1
        [[ "$ini_value" == 0 ]] && __has_kms=0
    fi

    set_platform_defaults
    platform_${__platform}
}

function set_platform_defaults() {
    __default_opt_flags="-O2"
}

function platform_rpi1() {
    __default_cpu_flags="-mcpu=arm1176jzf-s -mfpu=vfp -mfloat-abi=hard"
    __platform_flags="arm armv6 rpi gles"
    # if building in a chroot, what cpu should be set by qemu
    # make chroot identify as arm6l
    __qemu_cpu=arm1176
}

function platform_rpi2() {
    __default_cpu_flags="-mcpu=cortex-a7 -mfpu=neon-vfpv4 -mfloat-abi=hard"
    __platform_flags="arm armv7 neon rpi gles"
    __qemu_cpu=cortex-a7
}

# note the rpi3 currently uses the rpi2 binaries - for ease of maintenance - rebuilding from source
# could improve performance with the compiler options below but needs further testing
function platform_rpi3() {
    __default_cpu_flags="-march=armv8-a+crc -mtune=cortex-a53 -mfpu=neon-fp-armv8 -mfloat-abi=hard"
    __platform_flags="arm armv8 neon rpi gles"
    __qemu_cpu=cortex-a53
}

function platform_rpi4() {
    __default_cpu_flags="-march=armv8-a+crc -mtune=cortex-a72 -mfpu=neon-fp-armv8 -mfloat-abi=hard"
    __platform_flags="arm armv8 neon rpi gles gles3"
}

function platform_odroid-c1() {
    __default_cpu_flags="-mcpu=cortex-a5 -mfpu=neon-vfpv4 -mfloat-abi=hard"
    __platform_flags="arm armv7 neon mali gles"
    __qemu_cpu=cortex-a9
}

function platform_odroid-c2() {
    if [[ "$(getconf LONG_BIT)" -eq 32 ]]; then
        __default_cpu_flags="-march=armv8-a+crc -mtune=cortex-a53 -mfpu=neon-fp-armv8"
        __platform_flags="arm armv8 neon mali gles"
    else
        __default_cpu_flags="-mcpu=cortex-a53"
        __platform_flags="aarch64 kms gles"
    fi
}

function platform_odroid-xu() {
    __default_cpu_flags="-mcpu=cortex-a15 -mfpu=neon-vfpv4 -mfloat-abi=hard"
    __platform_flags="arm armv7 neon gles"
    if [[ -r "/etc/armbian-release" ]]; then
        __platform_flags+=" kms"
    else
        # required for mali-fbdev headers to define GL functions
        __default_cflags=" -DGL_GLEXT_PROTOTYPES"
        __platform_flags+=" mali"
    fi
}

function platform_renegade() {
    if [[ "$(getconf LONG_BIT)" -eq 32 ]]; then
        __default_cpu_flags="-march=armv8-a+crc -mtune=cortex-a53 -mfpu=neon-fp-armv8"
        __platform_flags="arm armv8 neon mali gles"
    else
        __default_cpu_flags="-mcpu=cortex-a53"
        __platform_flags="aarch64 kms gles"
    fi
}

function platform_tinker() {
    __default_cpu_flags="-mcpu=cortex-a17 -mfpu=neon-vfpv4 -mfloat-abi=hard"
    # required for mali headers to define GL functions
    #__default_cflags=" -DGL_GLEXT_PROTOTYPES"
    __platform_flags="arm armv7 neon kms gles gles3"
}

function platform_rockpi4() {
     __default_cpu_flags="-mcpu=cortex-a72"
    # required for mali headers to define GL functions
    #__default_cflags=" -DGL_GLEXT_PROTOTYPES"
    __platform_flags="aarch64 kms gles gles3"
}

function platform_jetson-tx1() {
    __default_cpu_flags="-march=armv8-a+crypto+simd -mcpu=cortex-a57+crypto+simd"
    __platform_flags="aarch64 x11 gl"
}

function platform_jetson-tx2() {
    __default_cpu_flags="-march=armv8-a+crypto+simd -mcpu=cortex-a57+crypto+simd"
    __platform_flags="aarch64 x11 gl"
}

function platform_jetson-nano() {
    __default_cpu_flags="-march=armv8-a+crypto+simd -mcpu=cortex-a57+crypto+simd"
    __platform_flags="aarch64 x11 gl"
}

function platform_jetson-agx() {
    __default_cpu_flags="-march=armv8-a+crypto+simd -mcpu=cortex-a57+crypto+simd"
    __platform_flags="aarch64 x11 gl"
}

function platform_khadas-vim3() {
    __default_cpu_flags="-march=armv8-a+crypto+simd -mcpu=cortex-a72+crypto+simd"
    __platform_flags="aarch64 mali gles gles3"
}

function platform_x86() {
    __default_cpu_flags="-march=native"
    __platform_flags="gl"
    if [[ "$__has_kms" -eq 1 ]]; then
        __platform_flags+=" kms"
    else
        __platform_flags+=" x11"
    fi
}

function platform_generic-x11() {
    __platform_flags="x11 gl"
}

function platform_armv7-mali() {
    __default_cpu_flags="-march=armv7-a -mfpu=neon-vfpv4 -mfloat-abi=hard"
    __platform_flags="arm armv7 neon mali gles"
}

function platform_armv7-kms() {
    __default_cpu_flags="-march=armv7-a -mfpu=neon-vfpv4 -mfloat-abi=hard"
    __platform_flags="arm armv7 neon kms gles"
}

function platform_imx6() {
    __default_cpu_flags="-march=armv7-a -mfpu=neon -mtune=cortex-a9 -mfloat-abi=hard"
    __platform_flags="arm armv7 neon"
}

function platform_vero4k() {
    __default_cpu_flags="-mcpu=cortex-a7 -mfpu=neon-vfpv4"
    __default_cflags="-I/opt/vero3/include -L/opt/vero3/lib"
    __platform_flags="arm armv7 neon mali gles"
}
