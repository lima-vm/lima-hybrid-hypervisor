#!/bin/bash
# SPDX-FileCopyrightText: Copyright The Lima Authors
# SPDX-License-Identifier: Apache-2.0
#
# Builds Hybrid Hypervisor and a QEMU patched to use it, without root privileges, and stages the result in an
# output directory laid out like the install prefix (default prefix: /opt/lima-hybrid-hypervisor):
#
#   OUTPUT/bin/qemu-system-x86_64          QEMU with the engine built in (off unless -accel tcg,hybrid=on), signed
#                                          with the Hypervisor.framework entitlement
#   OUTPUT/bin/qemu-system-x86_64.hybrid   wrapper for Lima: QEMU_SYSTEM_X86_64=PREFIX/bin/qemu-system-x86_64.hybrid
#   OUTPUT/bin/qemu-img, OUTPUT/share/qemu firmware (EDK2) and the rest of a QEMU install
#   OUTPUT/share/doc/lima-hybrid-hypervisor licenses, patches and the pinned source versions
#
# Then ./install.sh (with the same --prefix) copies OUTPUT to PREFIX. The sources are pinned by git commit hash (see
# "Pinned sources" below).
# Requirements: Apple silicon, macOS 15 or later, Xcode (or its command line tools with Swift), and from
# Homebrew: glib pixman libslirp ninja pkgconf.
#
# Usage: ./build.sh [--prefix=PREFIX (default /opt/lima-hybrid-hypervisor)] [--output=DIR (default _output)] [--jobs=N] [--build-dir=DIR] [--keep-build-dir]

set -euo pipefail

# ---- Pinned sources --------------------------------------------------------------------------------------------
# Hybrid Hypervisor, from Virtual Intel Mac (MIT). Only Source/HybridHypervisor and LICENSE are checked out.
ENGINE_REPO=https://github.com/nfzerox/VirtualIntelMacOnAppleSilicon.git
ENGINE_COMMIT=0c29f1f0fcaff59fdb6721f7ffa8b4a8c8decb65 # 2026-11-17
# QEMU master, at the commit the patches in qemu-patches/ apply to.
QEMU_REPO=https://github.com/qemu/qemu.git
QEMU_COMMIT=6883fb508cb7a93e2e7b44c0582bfd9fc2196d4d # 2026-11-17

# ---- Options -----------------------------------------------------------------------------------------------------
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
prefix=/opt/lima-hybrid-hypervisor
output=$script_dir/_output
jobs=$(sysctl -n hw.ncpu)
build_dir=
keep_build_dir=
usage() { sed -n '/^# Usage:/s/^# //p' "$0"; }
while [ $# -gt 0 ]; do
	case $1 in
	--prefix=*) prefix=${1#*=} ;;
	--prefix) prefix=${2:?--prefix needs a value}; shift ;;
	--output=*) output=${1#*=} ;;
	--jobs=*) jobs=${1#*=} ;;
	--build-dir=*) build_dir=${1#*=} ;;
	--keep-build-dir) keep_build_dir=1 ;;
	-h | --help) usage; exit 0 ;;
	*) echo "unknown option: $1" >&2; usage >&2; exit 64 ;;
	esac
	shift
done
case $prefix in /*) ;; *) echo "--prefix must be an absolute path" >&2; exit 64 ;; esac
[ "$(id -u)" != 0 ] || { echo "build.sh does not need root; run it as a normal user" >&2; exit 1; }

log() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# ---- Requirements ------------------------------------------------------------------------------------------------
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || die "Hybrid Hypervisor needs macOS on Apple silicon"
macos_major=$(sw_vers -productVersion | cut -d. -f1)
[ "$macos_major" -ge 15 ] || die "Hybrid Hypervisor needs macOS 15 or later (hardware TSO); this is $(sw_vers -productVersion)"
for cmd in git ninja pkg-config python3 xcrun codesign xattr; do
	command -v "$cmd" >/dev/null || die "missing command: $cmd"
done
xcrun --find swiftc >/dev/null 2>&1 || die "the Swift compiler is missing: install Xcode or its command line tools"
for pc in glib-2.0 pixman-1 slirp; do
	pkg-config --exists "$pc" || die "missing library $pc (brew install glib pixman libslirp ninja pkgconf)"
done

patches_dir=$script_dir/qemu-patches
ls "$patches_dir"/*.patch >/dev/null 2>&1 || die "no patches in $patches_dir"

if [ -n "$build_dir" ]; then
	mkdir -p "$build_dir"
	build_dir=$(cd "$build_dir" && pwd)
else
	build_dir=$(mktemp -d "${TMPDIR:-/tmp}/lima-hybrid-hypervisor.XXXXXX")
fi
cleanup() { [ -n "$keep_build_dir" ] || rm -rf "${build_dir:?}"; }
trap cleanup EXIT

# Checks out COMMIT of REPO into DIR (shallow; sparse when paths are given) and verifies the commit hash.
git_checkout() { # dir repo commit [sparse paths...]
	local dir=$1 repo=$2 commit=$3
	shift 3
	rm -rf "$dir"
	git init -q "$dir"
	git -C "$dir" remote add origin "$repo"
	[ $# = 0 ] || git -C "$dir" sparse-checkout set --no-cone "$@"
	git -C "$dir" fetch -q --depth=1 --filter=blob:none origin "$commit"
	git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD
	local actual
	actual=$(git -C "$dir" rev-parse HEAD)
	[ "$actual" = "$commit" ] || die "commit mismatch for $repo: expected $commit, got $actual"
}

# ---- Hybrid Hypervisor -------------------------------------------------------------------------------------------
log "Fetching Hybrid Hypervisor at ${ENGINE_COMMIT}"
engine=$build_dir/engine
git_checkout "$engine" "$ENGINE_REPO" "$ENGINE_COMMIT" /Source/HybridHypervisor/ /LICENSE
engine_src=$engine/Source/HybridHypervisor

log "Building Hybrid Hypervisor"
(cd "$engine_src" && ./build.sh release --library-only)
[ -f "$engine_src/.build/release/libEngine.a" ] || die "the engine build did not produce libEngine.a"

# ---- QEMU --------------------------------------------------------------------------------------------------------
log "Fetching QEMU at ${QEMU_COMMIT}"
qemu_src=$build_dir/qemu
git_checkout "$qemu_src" "$QEMU_REPO" "$QEMU_COMMIT"

log "Applying qemu-patches/"
# The committer identity is only needed by git am; the patches' own From: header is a placeholder too.
git -C "$qemu_src" -c user.name=nobody -c user.email=nobody@localhost am -q --no-gpg-sign "$patches_dir"/*.patch ||
	die "the patches in qemu-patches/ did not apply"

log "Configuring QEMU (prefix: $prefix)"
mkdir -p "$qemu_src/build"
(cd "$qemu_src/build" && ../configure --prefix="$prefix" --target-list=x86_64-softmmu \
	--disable-docs --disable-werror --enable-slirp -Dhvdbt_engine="$engine_src")

log "Building QEMU"
ninja -C "$qemu_src/build" -j "$jobs"

# ---- Stage -------------------------------------------------------------------------------------------------------
log "Staging to $output"
# Replace the output directory only if it is empty or holds an earlier output of this script.
if [ -e "$output" ] && [ -n "$(ls -A "$output")" ] && [ ! -e "$output/bin/qemu-system-x86_64.hybrid" ]; then
	die "$output is not empty and is not an earlier output of build.sh"
fi
stage=$build_dir/stage
rm -rf "$stage"
DESTDIR=$stage ninja -C "$qemu_src/build" install >/dev/null
rm -rf "$output"
mkdir -p "$output"
output=$(cd "$output" && pwd)
cp -R "$stage$prefix"/. "$output"/

qemu_bin=$output/bin/qemu-system-x86_64
# The engine creates a Hypervisor.framework VM, so the binary needs the hypervisor entitlement.
xattr -cr "$qemu_bin"
codesign --force --sign - --entitlements "$engine_src/Engine.entitlements" "$qemu_bin"

install -m 755 "$script_dir/qemu-system-x86_64.hybrid" "$output/bin/qemu-system-x86_64.hybrid"

doc=$output/share/doc/lima-hybrid-hypervisor
mkdir -p "$doc/qemu-patches"
install -m 644 "$engine/LICENSE" "$doc/LICENSE.HybridHypervisor"
install -m 644 "$qemu_src/COPYING" "$doc/COPYING.QEMU"
install -m 644 "$script_dir/LICENSE" "$doc/LICENSE"
install -m 644 "$patches_dir"/*.patch "$doc/qemu-patches/"
cat >"$doc/SOURCES" <<EOF
Hybrid Hypervisor: $ENGINE_REPO $ENGINE_COMMIT
QEMU:              $QEMU_REPO $QEMU_COMMIT, with qemu-patches/
Prefix:            $prefix
EOF

# ---- Check -------------------------------------------------------------------------------------------------------
printf '{"execute":"qmp_capabilities"}\n{"execute":"quit"}\n' |
	"$qemu_bin" -accel tcg,hybrid=on -M none -nodefaults -display none -S -qmp stdio >/dev/null ||
	die "the built QEMU does not accept -accel tcg,hybrid=on"
codesign -d --entitlements - "$qemu_bin" 2>/dev/null | grep -q com.apple.security.hypervisor || die "the built QEMU lacks the hypervisor entitlement"
[ -f "$output/share/qemu/edk2-x86_64-code.fd" ] || die "UEFI firmware missing: $output/share/qemu/edk2-x86_64-code.fd"

log "Built for prefix $prefix, staged in $output"
