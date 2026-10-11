#!/bin/bash
# Runs one benchmark job on a macOS runner. Env: VARIANT (default, no-cache,
# no-scan), FILES (number of files), RESTIC_VERSION.
set -euo pipefail
OUT=$GITHUB_WORKSPACE/results/$VARIANT-$FILES
B=$HOME/bench
mkdir -p "$OUT" "$B"
export RESTIC_PASSWORD=bench RESTIC_REPOSITORY=$B/repo RESTIC_CACHE_DIR=$B/cache
export RESTIC_PROGRESS_FPS=0.0166 # one JSON status line per minute

case $VARIANT in
default) FLAGS=() ;;
no-cache) FLAGS=(--no-cache) ;;
no-scan) FLAGS=(--no-scan) ;;
*) echo "bad VARIANT" >&2; exit 1 ;;
esac

printf 'step\trc\treal_s\tuser_s\tsys_s\tmax_rss_bytes\tpeak_footprint_bytes\n' >"$OUT/summary.tsv"

# measure NAME CMD...: runs CMD under /usr/bin/time -l and appends a summary row.
measure() {
	local name=$1 rc=0
	shift
	echo "::group::$name: $*"
	/usr/bin/time -l -o "$OUT/$name.time" "$@" >"$OUT/$name.stdout" 2>"$OUT/$name.stderr" || rc=$?
	awk -v n="$name" -v rc=$rc '/ real /{r=$1;u=$3;s=$5} /maximum resident set size/{m=$1} /peak memory footprint/{p=$1}
		END{printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", n, rc, r, u, s, m, p}' "$OUT/$name.time" | tee -a "$OUT/summary.tsv"
	grep -v '"message_type":"status"' "$OUT/$name.stdout" | tail -5 || true
	tail -5 "$OUT/$name.stderr"
	echo "::endgroup::"
}

# state NAME: records disk use, vnode counts and repo/cache sizes.
state() {
	{
		echo "== $1"
		df -k "$B"
		sysctl kern.maxvnodes kern.num_vnodes vm.page_free_count
		du -sk "$B/repo" "$B/cache" 2>/dev/null || true
		ls "$B/repo/index" 2>/dev/null | wc -l | sed 's/^ */index files: /'
	} >>"$OUT/state.txt" 2>&1
}

drop_caches() { sync; sudo purge; }

{
	sw_vers
	uname -a
	sysctl -n machdep.cpu.brand_string hw.ncpu hw.memsize
	go version
	echo "variant=$VARIANT files=$FILES flags=${FLAGS[*]:-} commit=$GITHUB_SHA run=$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
} >"$OUT/env.txt"

curl -fsSL "https://github.com/restic/restic/releases/download/v$RESTIC_VERSION/restic_${RESTIC_VERSION}_darwin_arm64.bz2" | bunzip2 >"$B/restic"
chmod +x "$B/restic"
"$B/restic" version >>"$OUT/env.txt"
(cd "$GITHUB_WORKSPACE/bench/walk" && go build -o "$B/walkbench" .)
cat "$OUT/env.txt"

state start
measure gen "$B/walkbench" gen -root "$B/tree" -files "$FILES"
state after-gen

for mode in walkdir-lstat bulk walkdir; do
	drop_caches
	measure "scan-$mode-cold" "$B/walkbench" scan -root "$B/tree" -mode "$mode"
	measure "scan-$mode-warm" "$B/walkbench" scan -root "$B/tree" -mode "$mode"
done

"$B/restic" init >"$OUT/init.stdout"
drop_caches
measure backup1 "$B/restic" backup --json --host bench "${FLAGS[@]}" "$B/tree"
state after-backup1
drop_caches
measure backup2-cold "$B/restic" backup --json --host bench "${FLAGS[@]}" "$B/tree"
measure backup2-warm "$B/restic" backup --json --host bench "${FLAGS[@]}" "$B/tree"
state after-backup2
"$B/restic" snapshots --json >"$OUT/snapshots.json"

# Keep logs small: one status line per minute is already set above.
cat "$OUT/summary.tsv"
