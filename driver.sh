#!/usr/bin/env bash

set -u

setup_variables() {
  while [[ ${#} -ge 1 ]]; do
    case ${1} in
      "-c"|"--clean") cleanup=true ;;
      "-j"|"--jobs") shift; jobs=$1 ;;
      "-j"*) jobs=${1/-j} ;;
      "-h"|"--help")
        cat usage.txt
        exit 0 ;;
    esac

    shift
  done

  # Turn on debug mode after parameters in case -h was specified
  set -x

  # arm64 is the current default if nothing is specified
  case ${ARCH:=arm64} in
    "arm")
      config=multi_v7_defconfig
      image_name=zImage
      qemu="qemu-system-arm"
      qemu_ram=512m
      qemu_cmdline=( -machine virt
                     -drive "file=images/arm/rootfs.ext4,format=raw,id=rootfs,if=none"
                     -device "virtio-blk-device,drive=rootfs"
                     -append "console=ttyAMA0 root=/dev/vda" )
      export CROSS_COMPILE=arm-linux-gnueabi- ;;

    "arm64")
      config=defconfig
      image_name=Image.gz
      qemu="qemu-system-aarch64"
      qemu_ram=512m
      qemu_cmdline=( -machine virt
                     -cpu cortex-a57
                     -drive "file=images/arm64/rootfs.ext4,format=raw"
                     -append "console=ttyAMA0 root=/dev/vda" )
      export CROSS_COMPILE=aarch64-linux-gnu- ;;

    "x86_64")
      config=defconfig
      image_name=bzImage
      qemu="qemu-system-x86_64"
      qemu_ram=512m
      qemu_cmdline=( -drive "file=images/x86_64/rootfs.ext4,format=raw,if=ide"
                     -append "console=ttyS0 root=/dev/sda" ) ;;

    # Unknown arch, error out
    *)
      echo "Unknown ARCH specified!"
      exit 1 ;;
  esac

  # torvalds/linux is the default repo if nothing is specified
  case ${REPO:=linux} in
    "linux") owner=torvalds ;;
    "linux-next") owner=next ;;
  esac
}

check_dependencies() {
  set -e

  command -v nproc
  command -v gcc
  command -v "${CROSS_COMPILE:-}"as
  command -v "${CROSS_COMPILE:-}"ld
  command -v ${qemu}
  command -v timeout
  command -v unbuffer
  command -v clang-8
  command -v "${LD:="${CROSS_COMPILE:-}"ld}"

  set +e
}

mako_reactor() {
  # https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/Documentation/kbuild/kbuild.txt
  time \
  KBUILD_BUILD_TIMESTAMP="Thu Jan  1 00:00:00 UTC 1970" \
  KBUILD_BUILD_USER=driver \
  KBUILD_BUILD_HOST=clangbuiltlinux \
  make -j"${jobs:-$(nproc)}" CC="${CC}" HOSTCC="${CC}" LD="${LD}" "${@}"
}

build_linux() {
  CC="$(command -v ccache) $(command -v clang-8)"

  if [[ ! -d ${REPO} ]]; then
    git clone --depth=1 git://git.kernel.org/pub/scm/linux/kernel/git/${owner}/${REPO}.git
    cd ${REPO}
  else
    cd ${REPO}
    git fetch --depth=1 origin master
    git reset --hard origin/master
  fi

  git show -s | cat

  patches_folder=../patches/${ARCH}
  [[ -d ${patches_folder} ]] && git apply -3 "${patches_folder}"/*.patch

  # Only clean up old artifacts if requested, the Linux build system
  # is good about figuring out what needs to be rebuilt
  [[ -n "${cleanup:-}" ]] && mako_reactor mrproper
  mako_reactor ${config}
  # If we're using a defconfig, enable some more common config options
  # like debugging, selftests, and common drivers
  if [[ ${config} =~ defconfig ]]; then
    cat ../configs/common.config >> .config
    # Some torture test configs cause issues on x86_64
    [[ $ARCH != "x86_64" ]] && cat ../configs/tt.config >> .config
    mako_reactor olddefconfig &>/dev/null
  fi
  mako_reactor ${image_name}

  cd "${OLDPWD}"
}

boot_qemu() {
  local kernel_image=${REPO}/arch/${ARCH}/boot/${image_name}
  # for the rest of the script, particularly qemu
  set -e
  test -e ${kernel_image}
  timeout 1m unbuffer ${qemu} \
    -m ${qemu_ram} \
    "${qemu_cmdline[@]}" \
    -nographic \
    -kernel ${kernel_image}
}

setup_variables "${@}"
check_dependencies
build_linux
boot_qemu
