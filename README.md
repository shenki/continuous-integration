# ASPEED continuous-integration

A repo for daily continuous compilation and boot testing of ASPEED Linux kernels.

Uses [daily snapshots](https://apt.llvm.org/) of
[Clang](https://clang.llvm.org/), top of tree
[torvalds/linux](torvalds/linux.git), [Buildroot](https://buildroot.org/) root
filesystems, and [QEMU](https://www.qemu.org/) to boot. The infrastrucutre is
adapted from the [ClangBuiltLinux](https://travis-ci.com/ClangBuiltLinux/) project.

[![Build Status](https://travis-ci.com/shenki/continuous-integration.svg?branch=master)](https://travis-ci.com/shenki/continuous-integration)


## TODO

Things that require scripting

 - Check that time progresses
 - Check hires timers are enabled
 - Set and get aspeed rtc
 - Set and get i2c attached rtc
 - Read and write SPI NOR flash
 - Read and write emmc
 - Benchmark reads and writes of SPI NOR flash
 - Benchmark reads and writes of emmc
 - Send network traffic
 - Benchmark network throughput
 - Test USB host functionality

