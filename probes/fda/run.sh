#!/bin/bash
# Full Disk Access experiments. Runs as root. Each experiment installs probe
# binaries under $DIR, runs them as root LaunchDaemons and logs what they could
# read. Grants are rows inserted into the system TCC.db.
set -u
BUILD=${BUILD:?} OUT=${OUT:?}
DIR=/usr/local/libexec/fdaprobe
DB="/Library/Application Support/com.apple.TCC/TCC.db"
LOGDIR=/var/log/fdaprobe
SVC=kTCCServiceSystemPolicyAllFiles
mkdir -p "$DIR" "$LOGDIR" "$OUT"
exec > >(tee -a "$OUT/run.log") 2>&1
START=$(date '+%Y-%m-%d %H:%M:%S')

say() { echo; echo "##### $*"; }
dr() { codesign -d -r- "$1" 2>&1 | sed -n 's/^#* *designated => //p'; }
cdhash() { codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p'; }

# Replace a binary the way an updater would: write a new file, then rename.
put() {
  cp "$1" "$2.new" && chmod 755 "$2.new" && mv -f "$2.new" "$2"
  echo "put $(basename "$1") -> $2 cdhash=$(cdhash "$2") dr=[$(dr "$2")]"
}

# grant <path> dr|null [binary whose DR to store]
grant() {
  local p=$1 cs=NULL
  if [ "$2" = dr ]; then
    csreq -r="$(dr "${3:-$1}")" -b /tmp/fdaprobe-csreq.bin
    cs="X'$(xxd -p /tmp/fdaprobe-csreq.bin | tr -d '\n')'"
  fi
  sqlite3 "$DB" "DELETE FROM access WHERE service='$SVC' AND client='$p';
    INSERT INTO access (service,client,client_type,auth_value,auth_reason,auth_version,csreq,policy_id,
      indirect_object_identifier_type,indirect_object_identifier,indirect_object_code_identity,flags,last_modified)
    VALUES ('$SVC','$p',1,2,4,1,$cs,NULL,NULL,'UNUSED',NULL,0,CAST(strftime('%s','now') AS INTEGER));"
  echo "grant $p csreq=$2 $( [ "$2" = dr ] && echo "[$(dr "${3:-$1}")]")"
}
revoke_all() { sqlite3 "$DB" "DELETE FROM access WHERE client LIKE '$DIR/%'"; echo "revoked all probe rows"; }
rows() {
  echo "TCC rows for $DIR:"
  sqlite3 -header "$DB" "SELECT service,client,client_type,auth_value,auth_reason,length(csreq) AS csreq_len,last_modified FROM access WHERE client LIKE '$DIR/%'"
  sqlite3 "$DB" "SELECT client, hex(csreq) FROM access WHERE client LIKE '$DIR/%' AND csreq IS NOT NULL" |
    while IFS='|' read -r c h; do echo "$h" | xxd -r -p > /tmp/fdaprobe-row.bin; echo "  $c csreq => $(csreq -r /tmp/fdaprobe-row.bin -t 2>&1)"; done
}
restart_tccd() { killall tccd 2>/dev/null; sleep 2; echo "tccd restarted (killall tccd)"; }

# daemon <name> <program> [args...]: (re)install a root LaunchDaemon.
daemon() {
  local name=$1; shift
  local label=com.example.fdaprobe.$name plist=/Library/LaunchDaemons/com.example.fdaprobe.$name.plist
  launchctl bootout "system/$label" 2>/dev/null
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0"><dict>'
    echo "<key>Label</key><string>$label</string>"
    echo '<key>ProgramArguments</key><array>'
    for a in "$@"; do echo "<string>$a</string>"; done
    echo '</array>'
    echo '<key>EnvironmentVariables</key><dict>'
    echo '<key>PROBE_KC</key><string>fdaprobe-test</string>'
    echo '<key>RESTIC_PASSWORD</key><string>pw</string>'
    echo '<key>RESTIC_REPOSITORY</key><string>/var/tmp/fdaprobe-repo</string>'
    echo '</dict>'
    echo "<key>StandardOutPath</key><string>$LOGDIR/$name.log</string>"
    echo "<key>StandardErrorPath</key><string>$LOGDIR/$name.log</string>"
    echo '</dict></plist>'
  } > "$plist"
  chown root:wheel "$plist"; chmod 644 "$plist"
  launchctl bootstrap system "$plist" && echo "daemon $label: $*"
}

# run <name> <label for this run>: start the daemon once and print its output.
run() {
  local name=$1 label=com.example.fdaprobe.$1 log=$LOGDIR/$1.log
  echo "--- RUN $name: $2"
  local before; before=$(wc -l < "$log" 2>/dev/null || echo 0)
  launchctl kickstart "system/$label"
  for _ in $(seq 1 120); do
    sleep 1
    launchctl print "system/$label" | grep -q 'state = running' || break
  done
  tail -n +"$((before + 1))" "$log" | sed 's/^/    /'
}

say "environment"
sw_vers; csrutil status; id
sqlite3 "$DB" ".schema access"
echo "existing $SVC rows:"; sqlite3 "$DB" "SELECT client,client_type,auth_value,length(csreq) FROM access WHERE service='$SVC'"

say "setup: protected files, keychain item, restic repo"
for d in Safari Mail; do
  sudo -u runner mkdir -p "/Users/runner/Library/$d" && sudo -u runner sh -c "echo probe > /Users/runner/Library/$d/probe.txt"
done
ls -la /Users/runner/Library/Safari/probe.txt /Users/runner/Library/Mail/probe.txt
security add-generic-password -a fdaprobe -s fdaprobe-test -w secret-ok /Library/Keychains/System.keychain && echo "keychain item added"
security dump-keychain -a /Library/Keychains/System.keychain 2>/dev/null | grep -B12 -A60 '"fdaprobe-test"' | head -90
RESTIC_PASSWORD=pw "$BUILD/restic" -r /var/tmp/fdaprobe-repo init
revoke_all

say "A. ad-hoc (Go linker signature), grant bound to the DR of v1"
put "$BUILD/probe-v1" "$DIR/probe"
daemon probe "$DIR/probe"
run probe "A0 v1, no grant (baseline)"
grant "$DIR/probe" dr
run probe "A1 v1, granted, tccd not restarted"
restart_tccd
run probe "A1 v1, granted, after tccd restart"
put "$BUILD/probe-v2" "$DIR/probe"
run probe "A2 replaced with v2 (new cdhash), same path"
restart_tccd
run probe "A2 v2 after tccd restart"
rows
put "$BUILD/probe-v1" "$DIR/probe"
run probe "A3 v1 put back"
rows

say "B. ad-hoc, grant with csreq NULL (path only)"
revoke_all
put "$BUILD/probe-v1" "$DIR/probe"
grant "$DIR/probe" null
restart_tccd
run probe "B1 v1, path-only grant"
rows
put "$BUILD/probe-v2" "$DIR/probe"
run probe "B2 replaced with v2, path-only grant"
restart_tccd
run probe "B2 v2 after tccd restart"
rows

say "C. self-signed certificate, grant bound to the DR of signed v1"
revoke_all
put "$BUILD/signed-v1-cert1" "$DIR/probe"
grant "$DIR/probe" dr
restart_tccd
run probe "C1 signed v1 (cert 1), granted"
put "$BUILD/signed-v2-cert1" "$DIR/probe"
run probe "C2 replaced with signed v2 (same cert 1)"
restart_tccd
run probe "C2 signed v2 (cert 1) after tccd restart"
put "$BUILD/signed-v2-cert2" "$DIR/probe"
run probe "C3 replaced with v2 signed by another cert (cert 2), same identifier"
put "$BUILD/probe-v2" "$DIR/probe"
run probe "C4 replaced with ad-hoc v2"
rows

say "D. launcher that never changes, granted; worker is its child and not granted"
revoke_all
launchctl bootout system/com.example.fdaprobe.probe 2>/dev/null
put "$BUILD/probe-launcher" "$DIR/launcher"
put "$BUILD/probe-worker1" "$DIR/worker"
grant "$DIR/launcher" dr
restart_tccd
daemon worker "$DIR/worker"
run worker "D0 worker alone as a LaunchDaemon (control)"
daemon launcher "$DIR/launcher" spawn "$DIR/worker"
run launcher "D1 launcher spawns worker1"
put "$BUILD/probe-worker2" "$DIR/worker"
run launcher "D2 worker replaced with worker2, launcher spawns it"
daemon launcher "$DIR/launcher" exec "$DIR/worker"
run launcher "E1 launcher execve()s worker2 (same process)"

say "F. restic as a child"
revoke_all
put "$BUILD/restic" "$DIR/restic"
put "$BUILD/probe-v1" "$DIR/probe"
put "$BUILD/probe-launcher" "$DIR/launcher"
put "$BUILD/probe-worker1" "$DIR/worker"
grant "$DIR/probe" dr
grant "$DIR/launcher" dr
restart_tccd
daemon restic "$DIR/restic" backup --no-cache --host fdaprobe /Users/runner/Library/Safari/probe.txt /Users/runner/Library/Mail/probe.txt
run restic "F0 restic alone as a LaunchDaemon, not granted (control)"
daemon probe "$DIR/probe" spawn "$DIR/restic" backup --no-cache --host fdaprobe /Users/runner/Library/Safari/probe.txt /Users/runner/Library/Mail/probe.txt
run probe "F1 granted daemon spawns restic"
daemon launcher "$DIR/launcher" spawn "$DIR/worker" spawn "$DIR/restic" backup --no-cache --host fdaprobe /Users/runner/Library/Safari/probe.txt /Users/runner/Library/Mail/probe.txt
run launcher "F2 granted launcher -> worker -> restic (grandchild)"
revoke_all
grant "$DIR/restic" dr
restart_tccd
run restic "F3 restic alone as a LaunchDaemon, restic itself granted"
daemon worker "$DIR/worker" spawn "$DIR/restic" backup --no-cache --host fdaprobe /Users/runner/Library/Safari/probe.txt /Users/runner/Library/Mail/probe.txt
run worker "F4 ungranted daemon spawns granted restic"
rows
RESTIC_PASSWORD=pw "$BUILD/restic" -r /var/tmp/fdaprobe-repo snapshots

say "cleanup"
for n in probe worker launcher restic; do launchctl bootout "system/com.example.fdaprobe.$n" 2>/dev/null; done
revoke_all
security delete-generic-password -s fdaprobe-test /Library/Keychains/System.keychain >/dev/null && echo "keychain item deleted"

say "TCC log lines mentioning the probe"
log show --start "$START" --info --style compact \
  --predicate 'subsystem == "com.apple.TCC" AND eventMessage CONTAINS "fdaprobe"' > "$OUT/tcc-log.txt" 2>&1
wc -l "$OUT/tcc-log.txt"
grep -E 'AUTHREQ_RESULT|csreq|requirement|Failed|failed|valid' "$OUT/tcc-log.txt" | head -60
