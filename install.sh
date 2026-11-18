#!/bin/bash
# SPDX-FileCopyrightText: Copyright The Lima Authors
# SPDX-License-Identifier: Apache-2.0
#
# Installs Hybrid Hypervisor and the patched QEMU, built by build.sh, to PREFIX (default: /opt/lima-hybrid-hypervisor),
# with the wrapper for Lima as PREFIX/bin/qemu-system-x86_64.hybrid.
#
# Run ./build.sh first, as the current user and with the same --prefix. This script only copies its output
# (default _output) to PREFIX, with sudo only when PREFIX is not writable by the current user.
#
# Usage: ./install.sh [--prefix=PREFIX (default /opt/lima-hybrid-hypervisor)] [--output=DIR (default _output)]

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
prefix=/opt/lima-hybrid-hypervisor
output=$script_dir/_output
usage() { sed -n '/^# Usage:/s/^# //p' "$0"; }
while [ $# -gt 0 ]; do
	case $1 in
	--prefix=*) prefix=${1#*=} ;;
	--prefix) prefix=${2:?--prefix needs a value}; shift ;;
	--output=*) output=${1#*=} ;;
	-h | --help) usage; exit 0 ;;
	*) echo "unknown option: $1" >&2; usage >&2; exit 64 ;;
	esac
	shift
done
case $prefix in /*) ;; *) echo "--prefix must be an absolute path" >&2; exit 64 ;; esac

log() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

sources=$output/share/doc/lima-hybrid-hypervisor/SOURCES
[ -f "$sources" ] || die "no build output in $output: run ./build.sh${prefix:+ --prefix=$prefix} first"
grep -qxF "Prefix:            $prefix" "$sources" || die "$output was built for another prefix ($(grep '^Prefix:' "$sources")): run ./build.sh --prefix=$prefix"

# Writes to the prefix go through sudo only when the prefix is not writable by the current user.
sudo=
probe=$prefix
while [ ! -e "$probe" ]; do probe=$(dirname "$probe"); done
[ -w "$probe" ] || sudo=sudo

log "Installing to $prefix${sudo:+ (with sudo)}"
$sudo mkdir -p "$prefix"
# ditto keeps the code signature and the entitlement of qemu-system-x86_64.
$sudo ditto "$output" "$prefix"

qemu_bin=$prefix/bin/qemu-system-x86_64
codesign -d --entitlements - "$qemu_bin" 2>/dev/null | grep -q com.apple.security.hypervisor || die "the installed QEMU lacks the hypervisor entitlement"
[ -f "$prefix/share/qemu/edk2-x86_64-code.fd" ] || die "UEFI firmware missing: $prefix/share/qemu/edk2-x86_64-code.fd"

log "Done"
cat <<EOF
Installed to $prefix. To start an x86_64 Lima VM with Hybrid Hypervisor:

  export QEMU_SYSTEM_X86_64="$prefix/bin/qemu-system-x86_64.hybrid"
  limactl start --arch=x86_64 --vm-type=qemu template:ubuntu
EOF
