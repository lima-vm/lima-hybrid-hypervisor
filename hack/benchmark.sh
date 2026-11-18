#!/bin/bash
# SPDX-FileCopyrightText: Copyright The Lima Authors
# SPDX-License-Identifier: Apache-2.0
#
# Compares Lima's default Ubuntu template (x86_64 on Apple silicon) with and without Hybrid Hypervisor.
# For each mode it boots a fresh instance ROUNDS times and records the boot time. In the last instance it runs
# each benchmark ROUNDS times. Both modes go through qemu-system-x86_64.hybrid, so they use the same QEMU binary
# and CPU model, and differ only in -accel tcg,hybrid=on (mode "hybrid") or not (mode "tcg").
#
# Usage: hack/benchmark.sh [-n ROUNDS] [-o OUTDIR] [-m "hybrid tcg"]
# Environment: PREFIX (default /opt/lima-hybrid-hypervisor), LIMACTL (default limactl), REQUIRE_ENGINE (default 1;
# with 0, a "hybrid" boot where the engine did not engage is a warning, not an error), and Lima's own
# variables such as LIMA_HOME. Instances are named lhh-bench-<mode>-<round> and are deleted afterwards.
# Results: OUTDIR/results.csv (mode,round,metric,value,unit) and OUTDIR/summary.md (median, min and max).

set -euo pipefail
rounds=3
outdir=bench-out
modes="hybrid tcg"
while getopts n:o:m: opt; do
	case $opt in
	n) rounds=$OPTARG ;;
	o) outdir=$OPTARG ;;
	m) modes=$OPTARG ;;
	*) sed -n '/^# Usage:/s/^# //p' "$0" >&2; exit 64 ;;
	esac
done
prefix=${PREFIX:-/opt/lima-hybrid-hypervisor}
limactl=${LIMACTL:-limactl}
wrapper=$prefix/bin/qemu-system-x86_64.hybrid
[ -x "$wrapper" ] || { echo "not installed: $wrapper (run install.sh, or set PREFIX)" >&2; exit 1; }
export QEMU_SYSTEM_X86_64=$wrapper
lima_home=${LIMA_HOME:-$HOME/.lima}
mkdir -p "$outdir"
csv=$outdir/results.csv
[ -f "$csv" ] || echo "mode,round,metric,value,unit" >"$csv"
record() { echo "$1,$2,$3,$4,$5" >>"$csv"; echo "  $1 #$2 $3 = $4 $5"; }

# Seconds between Lima's "Starting QEMU" and "READY" log lines (timestamps are RFC 3339).
boot_seconds() {
	python3 - "$1" <<'EOF'
import re, sys, datetime
t = {}
for line in open(sys.argv[1], errors="replace"):
    m = re.search(r'time="([^"]+)".*msg="(.*)"', line)
    if m and ("Starting QEMU" in m.group(2) or m.group(2).startswith("READY")):
        t.setdefault("start" if "Starting QEMU" in m.group(2) else "ready", datetime.datetime.fromisoformat(m.group(1)))
print((t["ready"] - t["start"]).total_seconds())
EOF
}

# Runs in the guest. Prints "metric value unit" lines.
guest_setup='
set -e
sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sysbench build-essential >/dev/null
cd /tmp && curl -fsSL -o sqlite.tar.gz https://www.sqlite.org/2026/sqlite-autoconf-3540100.tar.gz
echo "926ef8d3eab93fbf6e06011901273eec076b25594a4e1cdadd50c987f4f6d64e  sqlite.tar.gz" | sha256sum -c --quiet -
tar -xzf sqlite.tar.gz
'
guest_round='
set -e
now() { date +%s.%N; }
since() { awk -v a="$(now)" -v b="$1" "BEGIN {printf \"%.3f\", a - b}"; }
sysbench cpu --threads=1 --time=10 run | awk "/events per second/ {print \"sysbench_cpu_1thread\", \$4, \"events/s\"}"
sysbench cpu --threads=$(nproc) --time=10 run | awk -v n=$(nproc) "/events per second/ {print \"sysbench_cpu_\" n \"threads\", \$4, \"events/s\"}"
sysbench memory --threads=1 --memory-block-size=1M --memory-total-size=8G --time=10 run |
	awk "/MiB\/sec/ {gsub(/[(]/, \"\"); print \"sysbench_memory_1thread\", \$4, \"MiB/s\"}"
openssl speed -seconds 3 -evp sha256 2>/dev/null | awk "/^sha256/ {sub(/k\$/, \"\", \$NF); print \"openssl_sha256_16k\", \$NF/1000, \"MB/s\"}"
openssl speed -seconds 3 -evp aes-128-gcm 2>/dev/null | awk "/^AES-128-GCM/ {sub(/k\$/, \"\", \$NF); print \"openssl_aes128gcm_16k\", \$NF/1000, \"MB/s\"}"
t=$(now); for i in $(seq 1000); do /bin/true; done; echo "spawn_1000_processes $(since $t) s"
cd /tmp/sqlite-autoconf-3540100
t=$(now); gcc -O2 -o sqlite3 shell.c sqlite3.c -lpthread -ldl -lm; echo "build_sqlite $(since $t) s"
'

for mode in $modes; do
	case $mode in
	hybrid) export LIMA_HYBRID_HYPERVISOR=1 ;;
	tcg) export LIMA_HYBRID_HYPERVISOR=0 ;;
	*) echo "unknown mode: $mode" >&2; exit 64 ;;
	esac
	for round in $(seq "$rounds"); do
		name=lhh-bench-$mode-$round
		echo "== $mode: boot #$round ($name)"
		"$limactl" delete -f "$name" >/dev/null 2>&1 || true
		log=$outdir/$name.start.log
		"$limactl" start --tty=false --name="$name" --arch=x86_64 --vm-type=qemu template:ubuntu >"$log" 2>&1
		record "$mode" "$round" boot "$(boot_seconds "$log")" s
		engaged=$(grep -c 'the engine takes over' "$lima_home/$name/ha.stderr.log" || true)
		if [ "$mode" = hybrid ]; then
			record "$mode" "$round" engine_engaged "$engaged" ""
			if [ "$engaged" = 0 ]; then
				echo "Hybrid Hypervisor did not engage in $name (see $lima_home/$name/ha.stderr.log)" >&2
				[ "${REQUIRE_ENGINE:-1}" = 0 ] || exit 1
			fi
		fi
		if [ "$round" != "$rounds" ]; then
			"$limactl" delete -f "$name" >/dev/null 2>&1
		fi
	done
	echo "== $mode: benchmarks in $name"
	"$limactl" shell "$name" bash -c "$guest_setup"
	for round in $(seq "$rounds"); do
		"$limactl" shell "$name" bash -c "$guest_round" | while read -r metric value unit; do
			record "$mode" "$round" "$metric" "$value" "$unit"
		done
	done
	cp "$lima_home/$name/ha.stderr.log" "$outdir/$name.ha.stderr.log"
	"$limactl" delete -f "$name" >/dev/null 2>&1
done

python3 - "$csv" >"$outdir/summary.md" <<'EOF'
import csv, statistics, sys
rows = list(csv.DictReader(open(sys.argv[1])))
metrics = list(dict.fromkeys(r["metric"] for r in rows))
modes = list(dict.fromkeys(r["mode"] for r in rows))
print("| Metric | " + " | ".join(f"{m} (median, min-max, n)" for m in modes) + " |")
print("|---|" + "---|" * len(modes))
for metric in metrics:
    cells = []
    for mode in modes:
        vals = [float(r["value"]) for r in rows if r["metric"] == metric and r["mode"] == mode]
        unit = next((r["unit"] for r in rows if r["metric"] == metric), "")
        fmt = lambda v: f"{v:,.0f}" if abs(v) >= 100 else f"{v:.2f}"
        cells.append(f"{fmt(statistics.median(vals))} {unit} ({fmt(min(vals))}-{fmt(max(vals))}, n={len(vals)})" if vals else "-")
    print(f"| {metric} | " + " | ".join(cells) + " |")
EOF
cat "$outdir/summary.md"
