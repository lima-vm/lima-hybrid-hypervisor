# Lima + Hybrid Hypervisor

> [!WARNING]
> **Experimental.** This is an example of integrating Hybrid Hypervisor with [Lima](https://lima-vm.io).
> It runs on a QEMU patched outside upstream, and it is not part of a Lima release. Expect rough edges.

Run **x86_64 Linux VMs on Apple silicon several times faster than with QEMU's TCG emulator**, using
[Hybrid Hypervisor](https://github.com/nfzerox/VirtualIntelMacOnAppleSilicon/tree/0c29f1f0fcaff59fdb6721f7ffa8b4a8c8decb65/Source/HybridHypervisor)
as a drop-in accelerator for Lima's `qemu` driver.

## What is Hybrid Hypervisor?

Hybrid Hypervisor is an x86-64 to AArch64 binary translator, invented by Sam Henri Gold (developer of
[Light Touch](https://samhenri.gold/lighttouch/)) and developed in [Virtual Intel Mac](https://github.com/nfzerox/VirtualIntelMacOnAppleSilicon)
by nfzerox. Like TCG, it translates x86 code to AArch64 blocks, but it runs them inside a Hypervisor.framework VM.
A small monitor in that VM handles the guest's system calls, faults, page-table changes and `iret` without leaving
the VM, guest memory is mapped through shadow page tables, and Apple silicon's hardware TSO mode provides x86's
memory ordering.

It works as a hand-off from QEMU's TCG:

- TCG runs the firmware (UEFI) and the boot loader.
- When the guest kernel enters 64-bit long mode in its high half, the engine takes over the vCPU.
- Anything the engine does not handle (for example AVX, or a few privileged instructions) goes back to TCG one
  instruction at a time, and then returns to the engine.
- Devices, timers and the APIC stay in QEMU, so Lima's disks, network and everything else work as before.

This repository provides:

- [`qemu-patches/`](qemu-patches/): patches for upstream QEMU that add the hand-off to TCG and the engine glue,
  enabled with `-accel tcg,hybrid=on`.
- [`build.sh`](build.sh): builds Hybrid Hypervisor and the patched QEMU from sources pinned by git commit hash,
  as the current user, and stages them in `_output/` with a wrapper for Lima, `qemu-system-x86_64.hybrid`.
- [`install.sh`](install.sh): copies the output of `build.sh` to the prefix (default `/opt/lima-hybrid-hypervisor`),
  using `sudo` only when the prefix is not writable.
- [`qemu-system-x86_64.hybrid`](qemu-system-x86_64.hybrid): the wrapper for Lima (see [The wrapper](#the-wrapper)).
- [`hack/benchmark.sh`](hack/benchmark.sh): the benchmark below.

## Requirements

- A Mac with Apple silicon, macOS 15 or later
- Xcode, or the Xcode command line tools with Swift
- [Homebrew](https://brew.sh) packages: `glib pixman libslirp ninja pkgconf`
- Lima 2.x, with `lima-additional-guestagents` (needed for x86_64 guests on Apple silicon)

## Quick start

```sh
brew install glib pixman libslirp ninja pkgconf lima lima-additional-guestagents

git clone https://github.com/lima-vm/lima-hybrid-hypervisor.git
cd lima-hybrid-hypervisor
./build.sh     # about 10 minutes, as the current user; stages the result in _output/
./install.sh   # copies _output/ to /opt/lima-hybrid-hypervisor (asks for sudo only if that is not writable)

export QEMU_SYSTEM_X86_64=/opt/lima-hybrid-hypervisor/bin/qemu-system-x86_64.hybrid
limactl start --arch=x86_64 --vm-type=qemu template:ubuntu
limactl shell ubuntu uname -m   # x86_64
```

To check that the engine is in use, look for its message in the instance's log:

```console
$ grep -o 'hvdbt: the engine takes over.*' ~/.lima/ubuntu/ha.stderr.log
hvdbt: the engine takes over at rip 0xffffffff905a537f, cr3 0x...
```

`QEMU_SYSTEM_X86_64` is read when Lima starts an instance, so set it again for later `limactl start` runs.
To install elsewhere, pass the same `--prefix=DIR` to both scripts, `./build.sh --prefix=DIR` and
`./install.sh --prefix=DIR` (no `sudo` needed for a directory you own); QEMU is configured for that prefix.
`./build.sh --help` shows the other options (jobs, build directory). `rm -rf /opt/lima-hybrid-hypervisor` uninstalls.

### The wrapper

`qemu-system-x86_64.hybrid` runs the patched `qemu-system-x86_64` next to it, with that directory first in `PATH`,
and changes two arguments:

- It adds `hybrid=on` to Lima's `-accel tcg,...`.
- It replaces Lima's default CPU model for x86_64 on Apple silicon, `max` (with or without feature flags), by
  `Nehalem`. The engine does not accept AVX, SMAP, PKU, FSGSBASE, UMIP or LA57, and with `max` the guest enables them
  and the engine stays out. `Nehalem` meets x86-64-v2, so RHEL 9 family distributions boot too. A CPU model set in the
  instance's `vmOpts.qemu.cpuType` other than `max` is passed through unchanged.

| Environment variable | Effect |
|---|---|
| `LIMA_HYBRID_HYPERVISOR_CPU` | CPU model used in place of `max` (default `Nehalem`) |
| `LIMA_HYBRID_HYPERVISOR=0` | Do not enable the engine: plain TCG with the same QEMU and CPU model, for comparison |

## Benchmark

Lima's default Ubuntu template (Ubuntu 26.10, x86_64, 4 vCPUs, 4 GiB) on an Apple M4 Max (macOS 27.2.1), with
Lima 2.3.0. Both columns use the same patched QEMU binary and the same CPU model (`Nehalem`, through the wrapper).
They differ only in whether the engine is enabled (`LIMA_HYBRID_HYPERVISOR=0` for TCG). Each boot is a fresh
instance, timed from Lima's "Starting QEMU" to "READY" (this includes the template's first-boot work such as
installing containerd). Each benchmark ran 3 times in one VM. The table shows the median, with the range in parentheses.

| Benchmark | TCG | Hybrid Hypervisor | Speedup |
|---|---:|---:|---:|
| Boot to `READY` (s, lower is better) | 195 (192–197) | **93** (92–95) | **2.1×** |
| Build SQLite 3.54.1, `gcc -O2` (s, lower is better) | 227 (225–229) | **25.6** (25.5–25.7) | **8.9×** |
| `sysbench cpu`, 1 thread (events/s) | 1,401 (1,375–1,404) | **6,736** (6,632–6,788) | **4.8×** |
| `sysbench cpu`, 4 threads (events/s) | 5,427 (5,315–5,433) | **24,337** (24,139–24,403) | **4.5×** |
| `sysbench memory`, 1 thread, 1 MiB blocks (MiB/s) | 6,080 (6,078–6,082) | **26,616** (26,474–26,784) | **4.4×** |
| `openssl speed sha256`, 16 KiB blocks (MB/s) | 98.9 (98.0–99.1) | **368** (367–371) | **3.7×** |
| Spawn 1,000 processes (`/bin/true`) (s, lower is better) | 31.3 (31.2–31.5) | **16.1** (16.0–16.5) | **1.9×** |
| `openssl speed aes-128-gcm`, 16 KiB blocks (MB/s) | **60.7** (60.5–60.8) | 21.2 (21.1–21.2) | **0.35×** (slower) |

AES-128-GCM is almost 3 times slower with the engine. The cause is not known yet: the engine's statistics do not
show it falling back to TCG for this code, so it is likely in the translated code itself.

To reproduce, after `build.sh` and `install.sh`:

```sh
hack/benchmark.sh -n 3 -o bench-out   # boots 3 times per mode and runs each benchmark 3 times; about 1 hour
cat bench-out/summary.md
```

## Limitations

- **Experimental.** The engine was built for macOS guests. Linux guests boot and run, but this is far less tested.
- Apple silicon with macOS 15 or later only. Hypervisor.framework must be available, so it does not work inside a
  macOS VM without nested virtualization (`sysctl kern.hv_support` must print `1`). There, the hybrid wrapper falls
  back to plain TCG.
- At most 8 vCPUs, and guest physical memory below 32 GiB (about 30 GiB of RAM on Lima's `q35` machine).
- AVX and other VEX-encoded instructions are not translated: they fall back to TCG, so the CPU model must not offer
  them. The same goes for SMAP, PKU, FSGSBASE, UMIP and LA57.
- Linux's MDS mitigation (`verw` on every return to user space) falls back to TCG, which costs a few percent on
  system-call-heavy work.
- AES-128-GCM with OpenSSL is about 3 times slower than on TCG (see [Benchmark](#benchmark)).
- The patched QEMU is upstream QEMU master plus the patches here, not a QEMU release.

## License

- The files in this repository are under the [Apache License 2.0](LICENSE), **except `qemu-patches/`**.
- **`qemu-patches/`** modifies QEMU and carries code from Virtual Intel Mac's QEMU integration. It is under
  **GPL-2.0-or-later**, QEMU's license, as stated in the patches. See [`qemu-patches/README.md`](qemu-patches/README.md).
- **Hybrid Hypervisor** itself is not in this repository. `build.sh` downloads it from Virtual Intel Mac, which is
  under the MIT License, Copyright (c) 2026 nfzerox.
- **QEMU** is under GPL-2.0 (some parts under other licenses, see its `COPYING` and `LICENSE`). The installed QEMU
  binary, which links Hybrid Hypervisor, is distributed under those terms.
- `build.sh` and `install.sh` install these licenses, the patches and the pinned source versions to
  `PREFIX/share/doc/lima-hybrid-hypervisor/`.
