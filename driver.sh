#!/usr/bin/env bash

echo "MACHINE: $MACHINE"
echo "   REPO: $REPO"
echo " CONFIG: $CONFIG"

set -eu

setup_variables() {
    while [[ ${#} -ge 1 ]]; do
        case ${1} in
            "AR="* | "ARCH="* | "CC="* | "LD="* | "LLVM_IAS="* | "NM"=* | "OBJCOPY"=* | "OBJDUMP"=* | "OBJSIZE"=* | "REPO="* | "STRIP"=*) export "${1?}" ;;
            "-c" | "--clean") cleanup=true ;;
            "-j" | "--jobs")
                shift
                jobs=$1
                ;;
            "-j"*) jobs=${1/-j/} ;;
            "--lto") disable_lto=false ;;
            "-h" | "--help")
                cat usage.txt
                exit 0
                ;;
        esac

        shift
    done

    # Turn on debug mode after parameters in case -h was specified
    set -x

    # torvalds/linux is the default repo if nothing is specified
    case ${REPO:=linux} in
        "dev-"*)
            branch=${REPO}
            tree=openbmc-${REPO}
            url=https://github.com/openbmc/linux
            ;;
        "android"*)
            tree=common
            branch=${REPO}
            url=https://android.googlesource.com/kernel/${tree}
            ;;
        "linux")
            owner=torvalds
            tree=linux
            ;;
        "linux-next")
            owner=next
            tree=linux-next
            ;;
        "4.4" | "4.9" | "4.14" | "4.19" | "5.4")
            owner=stable
            branch=linux-${REPO}.y
            tree=linux
            ;;
    esac
    [[ -z "${url:-}" ]] && url=git://git.kernel.org/pub/scm/linux/kernel/git/${owner}/${tree}.git

    case ${MACHINE} in
        "ast2400")
            make_target=zImage
            qemu="qemu-system-arm"
            qemu_cmdline=(-machine palmetto-bmc
                -no-reboot
                -net "nic,model=ftgmac100,netdev=netdev1" -netdev "user,id=netdev1"
                -dtb "${tree}/arch/arm/boot/dts/aspeed-bmc-opp-palmetto.dtb"
                -initrd "images/arm/rootfs.cpio")
            export SUBARCH=arm32_v5
            export ARCH=arm
            export CROSS_COMPILE=arm-linux-gnueabi-
            ;;

        "ast2500")
            make_target=zImage
            qemu="qemu-system-arm"
            qemu_cmdline=(-machine romulus-bmc
                -no-reboot
                -net "nic,model=ftgmac100,netdev=netdev1" -netdev "user,id=netdev1"
                -dtb "${tree}/arch/arm/boot/dts/aspeed-bmc-opp-romulus.dtb"
                -initrd "images/arm/rootfs.cpio")
            export SUBARCH=arm32_v6
            export ARCH=arm
            export CROSS_COMPILE=arm-linux-gnueabi-
            ;;

        "ast2600")
            make_target=zImage
            qemu="qemu-system-arm"
            qemu_cmdline=(-machine ast2600-evb
                -no-reboot
                -smp 2
                -net "nic,model=ftgmac100,netdev=netdev1" -netdev "user,id=netdev1"
                -dtb "${tree}/arch/arm/boot/dts/aspeed-ast2600-evb.dtb"
                -drive "file=images/arm/rootfs.ext4.qcow2,if=sd,index=2"
                -append "console=ttyS4 rootwait root=/dev/mmcblk0")
            export SUBARCH=arm32_v7
            export ARCH=arm
            export CROSS_COMPILE=arm-linux-gnueabi-
            ;;

        # Unknown arch, error out
        *)
            echo "Unknown ARCH specified!"
            exit 1
            ;;
    esac
    export ARCH=${ARCH}

    kernel_image=${tree}/arch/arm/boot/${make_target}
    config=${CONFIG}
}

# Clone/update the boot-utils
# It would be nice to use submodules for this but those don't always play well with Travis
# https://github.com/ClangBuiltLinux/continuous-integration/commit/e9054499bb1cb1a51cd1cdc73dc3c1dfa45b4199
function update_boot_utils() {
    images_url=https://github.com/ClangBuiltLinux/boot-utils
    if [[ -d boot-utils ]]; then
        cd boot-utils
        git fetch --depth=1 ${images_url} master
        git reset --hard FETCH_HEAD
        cd ..
    else
        git clone --depth=1 ${images_url}
    fi
}

check_dependencies() {
    # Check for existence of needed binaries
    command -v nproc
    command -v timeout
    command -v unbuffer
    command -v zstd

    update_boot_utils

    oldest_llvm_version=7
    latest_llvm_version=$(curl -LSs https://raw.githubusercontent.com/llvm/llvm-project/master/llvm/CMakeLists.txt | grep -s -F "set(LLVM_VERSION_MAJOR" | cut -d ' ' -f 4 | sed 's/)//')

    for llvm_version in $(seq "${latest_llvm_version}" -1 "${oldest_llvm_version}"); do
        debian_llvm_bin=/usr/lib/llvm-${llvm_version}/bin
        if [[ -d ${debian_llvm_bin} ]]; then
            export PATH=${debian_llvm_bin}:${PATH}
            break
        fi
    done

    READELF=llvm-readelf
    command -v "${READELF}"

    # Check for LD, CC, and AR environmental variables
    # and print the version string of each. If CC and AR
    # don't exist, try to find them.
    # clang's integrated assembler and lld aren't ready for all architectures so
    # it's just simpler to fall back to GNU as/ld when AS/LD isn't specified to
    # avoid architecture specific selection logic.

    "${LD:="${CROSS_COMPILE:-}"ld}" --version
    if [[ -z "${LLVM_IAS:-}" ]]; then
        LLVM_IAS=0
        command -v "${CROSS_COMPILE:-}"as
    fi

    if [[ -z "${CC:-}" ]]; then
        CC=clang
        command -v "${CC}"
    fi
    ${CC} --version 2>/dev/null || {
        set +x
        echo
        echo "Looks like ${CC} could not be found in PATH!"
        echo
        echo "Please install as recent a version of clang as you can from your distro or"
        echo "properly specify the CC variable to point to the correct clang binary."
        echo
        echo "If you don't want to install clang, you can either download AOSP's prebuilt"
        echo "clang [1] or build it from source [2] then add the bin folder to your PATH."
        echo
        echo "[1]: https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/"
        echo "[2]: https://github.com/ClangBuiltLinux/linux/wiki/Building-Clang-from-source"
        echo
        exit
    }

    if [[ -z "${AR:-}" ]]; then
        for AR in llvm-ar "${CROSS_COMPILE:-}"ar; do
            command -v "${AR}" 2>/dev/null && break
        done
    fi
    check_ar_version
    "${AR}" --version

    if [[ -z "${NM:-}" ]]; then
        for NM in llvm-nm "${CROSS_COMPILE:-}"nm; do
            command -v "${NM}" 2>/dev/null && break
        done
    fi

    if [[ -z "${OBJCOPY:-}" ]]; then
        for OBJCOPY in llvm-objcopy "${CROSS_COMPILE:-}"objcopy; do
            command -v "${OBJCOPY}" 2>/dev/null && break
        done
    fi

    if [[ -z "${OBJDUMP:-}" ]]; then
        for OBJDUMP in llvm-objdump "${CROSS_COMPILE:-}"objdump; do
            command -v "${OBJDUMP}" 2>/dev/null && break
        done
    fi

    if [[ -z "${OBJSIZE:-}" ]]; then
        for OBJSIZE in llvm-size "${CROSS_COMPILE:-}"size; do
            command -v "${OBJSIZE}" 2>/dev/null && break
        done
    fi

    if [[ -z "${STRIP:-}" ]]; then
        for STRIP in llvm-strip "${CROSS_COMPILE:-}"strip; do
            command -v "${STRIP}" 2>/dev/null && break
        done
    fi

    check_objcopy_strip_version
    "${OBJCOPY}" --version
    "${STRIP}" --version
}

# Optimistically check to see that the user has a llvm-ar
# with https://reviews.llvm.org/rL354044. If they don't,
# fall back to GNU ar and let them know.
check_ar_version() {
    if ${AR} --version | grep -q "LLVM" &&
        [[ $(${AR} --version | grep version | sed -e 's/.*LLVM version //g' -e 's/[[:blank:]]*$//' -e 's/\.//g' -e 's/svn//' -e 's/git//') -lt 900 ]]; then
        set +x
        echo
        echo "${AR} found but appears to be too old to build the kernel (needs to be at least 9.0.0)."
        echo
        echo "Please either update llvm-ar from your distro or build it from source!"
        echo
        echo "See https://github.com/ClangBuiltLinux/linux/issues/33 for more info."
        echo
        echo "Falling back to GNU ar..."
        echo
        AR=${CROSS_COMPILE:-}ar
        set -x
    fi
}

# Optimistically check to see that the user has an llvm-{objcopy,strip}
# with https://reviews.llvm.org/rGedeebad7715774b8481103733dc5d52dac43bdf3.
# If they don't, fall back to GNU objcopy and let them know.
check_objcopy_strip_version() {
    for TOOL in ${OBJCOPY} ${STRIP}; do
        if ${TOOL} --version | grep -q "LLVM" &&
            [[ $(${TOOL} --version | grep version | sed -e 's/.*LLVM version //g' -e 's/[[:blank:]]*$//' -e 's/\.//g' -e 's/svn//' -e 's/git//') -lt 1000 ]]; then
            set +x
            echo
            echo "${TOOL} found but appears to be too old to build the kernel (needs to be at least 10.0.0)."
            echo
            echo "Please either update ${TOOL} from your distro or build it from source!"
            echo
            echo "See https://github.com/ClangBuiltLinux/linux/issues/478 for more info."
            echo
            echo "Falling back to GNU ${TOOL//llvm-/}..."
            echo
            case ${TOOL} in
                *objcopy*) OBJCOPY=${CROSS_COMPILE:-}objcopy ;;
                *strip*) STRIP=${CROSS_COMPILE:-}strip ;;
            esac
            set -x
        fi
    done
}
mako_reactor() {
    # https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/Documentation/kbuild/kbuild.txt
    time \
        KBUILD_BUILD_TIMESTAMP="Thu Jan  1 00:00:00 UTC 1970" \
        KBUILD_BUILD_USER=driver \
        KBUILD_BUILD_HOST=clangbuiltlinux \
        make -j"${jobs:-$(nproc)}" \
        AR="${AR}" \
        CC="${CC}" \
        HOSTCC="${CC}" \
        HOSTLD="${HOSTLD:-ld}" \
        KCFLAGS="-Wno-implicit-fallthrough" \
        LD="${LD}" \
        LLVM_IAS="${LLVM_IAS}" \
        NM="${NM}" \
        OBJCOPY="${OBJCOPY}" \
        OBJDUMP="${OBJDUMP}" \
        OBJSIZE="${OBJSIZE}" \
        READELF="${READELF}" \
        STRIP="${STRIP}" \
        "${@}"
}

apply_patches() {
    patches_folder=$1
    if [[ -d ${patches_folder} ]]; then
        git apply -v -3 "${patches_folder}"/*.patch
    else
        return 0
    fi
}

build_linux() {
    # Wrap CC in ccache if it is available (it's not strictly required)
    CC="$(command -v ccache) ${CC}"
    [[ ${LD} =~ lld ]] && HOSTLD=${LD}

    if [[ -d ${tree} ]]; then
        cd ${tree}
        git fetch --depth=1 ${url} ${branch:=master}
        git reset --hard FETCH_HEAD
    else
        git clone --depth=1 -b ${branch:=master} --single-branch ${url} ${tree}
        cd ${tree}
    fi

    git show -s | cat

    llvm_all_folder="../patches/llvm-all"
    apply_patches "${llvm_all_folder}/kernel-all"
    apply_patches "${llvm_all_folder}/${REPO}/arch-all"
    apply_patches "${llvm_all_folder}/${REPO}/${SUBARCH}"
    llvm_version_folder="../patches/llvm-$(echo __clang_major__ | ${CC} -E -x c - | tail -n 1)"
    apply_patches "${llvm_version_folder}/kernel-all"
    apply_patches "${llvm_version_folder}/${REPO}/arch-all"
    apply_patches "${llvm_version_folder}/${REPO}/${SUBARCH}"

    # Only clean up old artifacts if requested, the Linux build system
    # is good about figuring out what needs to be rebuilt
    [[ -n "${cleanup:-}" ]] && mako_reactor mrproper
    mako_reactor ${config}
    # If we're using a defconfig, enable some more common config options
    # like debugging, selftests, and common drivers
    if [[ ${config} =~ defconfig ]]; then
        cat ../configs/common.config >>.config
        # Some torture test configs cause issues on PowerPC and x86_64
        [[ $ARCH != "x86_64" && $ARCH != "powerpc" ]] && cat ../configs/tt.config >>.config
        # Disable LTO and CFI unless explicitly requested
        ${disable_lto:=true} && ./scripts/config -d CONFIG_LTO -d CONFIG_LTO_CLANG
    fi
    [[ $SUBARCH == "mips" ]] && ./scripts/config -e CPU_BIG_ENDIAN -d CPU_LITTLE_ENDIAN
    # Make sure we build with CONFIG_DEBUG_SECTION_MISMATCH so that the
    # full warning gets printed and we can file and fix it properly.
    ./scripts/config -e DEBUG_SECTION_MISMATCH
    # Upstream mutli_v7 lacks the ASPEED SDHCI driver which is used for booting
    [[ ${config} == "multi_v7_defconfig" ]] && ./scripts/config -e MMC_SDHCI_OF_ASPEED
    mako_reactor olddefconfig &>/dev/null
    mako_reactor ${make_target}
    [[ $ARCH =~ arm ]] && mako_reactor dtbs
    "${READELF}" --string-dump=.comment vmlinux

    cd "${OLDPWD}"
}

boot_qemu() {
    test -e "${kernel_image}"
    qemu=(timeout "${timeout:-2}"m
        unbuffer
        "${qemu}"
        "${qemu_cmdline[@]}"
        -display none
        -serial mon:stdio
        -kernel "${kernel_image}")
    "${qemu[@]}"
}

setup_variables "${@}"
check_dependencies
build_linux
boot_qemu
