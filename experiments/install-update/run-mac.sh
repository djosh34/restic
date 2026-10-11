#!/bin/bash
# Issue 15 probe: Gatekeeper, quarantine, signing, writing restic out,
# replacing a running binary under launchd, restic self-update.
# Runs on a GitHub-hosted macOS runner. Never stops on a failing step.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
W=$RUNNER_TEMP/w; mkdir -p "$W"; cd "$W"
V=0.19.1
OLDV=0.18.1
REL=https://github.com/restic/restic/releases/download
CROSS=${CROSS:-}   # probe built on Linux, passed in by the workflow

h() { echo; echo "######## $*"; }
run() { echo "\$ $*"; "$@" 2>&1; echo "[rc=$?]"; }
# run a binary with a time limit, report exit code and wall time
try_exec() {
  local s=$(date +%s)
  echo "\$ $*"
  perl -e 'alarm shift; exec @ARGV or exit 127' 30 "$@" 2>&1
  local rc=$?
  echo "[exec rc=$rc after $(( $(date +%s) - s ))s]"
}
sig() { codesign -dvvv "$1" 2>&1 | grep -E 'Executable|Identifier=|Format|CodeDirectory|Signature|Authority|TeamIdentifier|flags' ; }
gklog() {
  log show --last "${1:-2m}" --style compact --predicate \
    'process == "syspolicyd" OR sender == "AppleSystemPolicy" OR (process == "kernel" AND eventMessage CONTAINS[c] "code sign") OR eventMessage CONTAINS[c] "CODE SIGNING"' \
    2>/dev/null | grep -v -E 'Filtering the log data|^Timestamp' | tail -n "${2:-25}"
}

h "S0 environment"
sw_vers; uname -m
run spctl --status
run csrutil status
run go version
run brew --version
echo "Developer Tool rows in TCC.db (these let a terminal skip Gatekeeper for its children):"
sudo sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" "select service,client,auth_value from access where service like '%Developer%'" 2>&1
sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" "select service,client,auth_value from access where service like '%Developer%'" 2>&1
run spctl developer-mode enable-terminal --help

h "S1 download with curl, checksums, PGP signature, attestations"
for f in restic_${V}_darwin_arm64.bz2 SHA256SUMS SHA256SUMS.asc; do curl -fsSLO "$REL/v$V/$f"; done
curl -fsSLO "$REL/v$OLDV/restic_${OLDV}_darwin_arm64.bz2"
echo "xattrs on curl downloads (empty means no quarantine):"
xattr -l restic_${V}_darwin_arm64.bz2 SHA256SUMS
run shasum -a 256 --ignore-missing -c SHA256SUMS
curl -fsSL https://raw.githubusercontent.com/restic/restic/v$V/internal/selfupdate/verify.go \
  | sed -n '/BEGIN PGP PUBLIC KEY BLOCK/,/END PGP PUBLIC KEY BLOCK/p' > restic-key.asc
export GNUPGHOME=$W/gnupg; mkdir -m 700 -p "$GNUPGHOME"
command -v gpg >/dev/null || brew install -q gnupg >/dev/null 2>&1
run gpg --batch --import restic-key.asc
run gpg --batch --verify SHA256SUMS.asc SHA256SUMS
echo "GitHub artifact attestations for the official restic asset:"
run gh attestation verify restic_${V}_darwin_arm64.bz2 --repo restic/restic
run gh attestation verify restic_${V}_darwin_arm64.bz2 --owner restic
bunzip2 -kf restic_${V}_darwin_arm64.bz2
bunzip2 -kf restic_${OLDV}_darwin_arm64.bz2
chmod 755 restic_${V}_darwin_arm64 restic_${OLDV}_darwin_arm64

h "S2 signatures"
echo "--- official restic $V darwin_arm64"
run file restic_${V}_darwin_arm64
sig restic_${V}_darwin_arm64
run ./restic_${V}_darwin_arm64 version
run codesign -v --strict restic_${V}_darwin_arm64
echo "--- official restic $OLDV darwin_arm64"
sig restic_${OLDV}_darwin_arm64

cp restic_${V}_darwin_arm64 "$HERE/probe/restic.bin"
shasum -a 256 restic_${V}_darwin_arm64 | cut -d' ' -f1 > "$HERE/probe/restic.sha256"
build() { (cd "$HERE/probe" && CGO_ENABLED=$2 go build -trimpath -ldflags "-X main.version=$3" -o "$W/$1" .) ; }
build probe-cgo0 0 cgo0
build probe-cgo1 1 cgo1
for v in v1 v2 v3 v4; do build probe-$v 0 $v; done
for b in probe-cgo0 probe-cgo1; do echo "--- $b (built on the Mac)"; sig $b; run ./$b version; done
if [ -n "$CROSS" ] && [ -f "$CROSS" ]; then
  cp "$CROSS" probe-linux; chmod 755 probe-linux
  echo "--- probe-linux (cross-built on ubuntu-latest, CGO_ENABLED=0)"; sig probe-linux; run ./probe-linux version
fi
echo "--- unsigned: signature removed"
cp probe-cgo0 probe-unsigned; run codesign --remove-signature probe-unsigned; sig probe-unsigned
try_exec ./probe-unsigned version
echo "--- re-signed ad hoc with codesign -s -"
cp probe-unsigned probe-adhoc; run codesign -s - probe-adhoc; sig probe-adhoc; try_exec ./probe-adhoc version
echo "--- self-signed certificate"
/usr/bin/openssl req -x509 -newkey rsa:2048 -keyout k.pem -out c.pem -days 30 -nodes \
  -subj "/CN=Probe Self Signed" -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" 2>&1 | tail -2
/usr/bin/openssl pkcs12 -export -inkey k.pem -in c.pem -out c.p12 -passout pass:pw 2>&1 | tail -2
KC=$W/probe.keychain-db
security create-keychain -p pw "$KC"; security unlock-keychain -p pw "$KC"
run security import c.p12 -k "$KC" -P pw -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k pw "$KC" >/dev/null 2>&1
security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
run security find-identity -v -p codesigning "$KC"
HASH=$(security find-certificate -c "Probe Self Signed" -Z "$KC" | awk '/SHA-1/{print $3}')
cp probe-cgo0 probe-selfsigned
run codesign -f -s "$HASH" --keychain "$KC" probe-selfsigned
sig probe-selfsigned
try_exec ./probe-selfsigned version

h "S3 our binary writes the embedded restic out"
sudo mkdir -p /usr/local/libexec/probe
run sudo ./probe-cgo0 write-restic /usr/local/libexec/probe/restic
ls -l@ /usr/local/libexec/probe/restic; xattr -l /usr/local/libexec/probe/restic
sig /usr/local/libexec/probe/restic
run codesign -v --strict /usr/local/libexec/probe/restic
run /usr/local/libexec/probe/restic version
run sudo /usr/local/libexec/probe/restic version

h "S4 where quarantine comes from"
cat > setq.swift <<'EOF'
// Sets quarantine the way a browser does, through the public NSURL API.
import Foundation
import CoreServices
let url = URL(fileURLWithPath: CommandLine.arguments[1]) as NSURL
let props: [String: Any] = [
  kLSQuarantineAgentNameKey as String: "Safari",
  kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
  kLSQuarantineDataURLKey as String: URL(string: "https://github.com/restic/restic/releases")!,
]
do { try url.setResourceValue(props, forKey: .quarantinePropertiesKey); print("quarantine set") } catch { print("error: \(error)") }
EOF
run swiftc -O -o setq setq.swift
cp probe-cgo0 probe-q; run ./setq probe-q; xattr -p com.apple.quarantine probe-q
echo "--- cp keeps xattrs, a Go write does not"
cp probe-q probe-q-cp; echo "cp copy:"; xattr -l probe-q-cp
echo "--- Homebrew formula and cask from a local tap (restic $V release asset over https)"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_ANALYTICS=1
SUM=$(shasum -a 256 restic_${V}_darwin_arm64.bz2 | cut -d' ' -f1)
run brew tap-new --no-git probe/local
TAP=$(brew --repository)/Library/Taps/probe/homebrew-local
mkdir -p "$TAP/Formula" "$TAP/Casks"
cat > "$TAP/Formula/probe-restic.rb" <<EOF
class ProbeRestic < Formula
  desc "Probe: restic release binary installed as a formula"
  homepage "https://restic.net"
  url "$REL/v$V/restic_${V}_darwin_arm64.bz2"
  version "$V"
  sha256 "$SUM"
  def install
    bin.install Dir["restic*"].first => "probe-restic"
  end
end
EOF
cat > "$TAP/Casks/probe-restic-cask.rb" <<EOF
cask "probe-restic-cask" do
  version "$V"
  sha256 "$SUM"
  url "$REL/v#{version}/restic_#{version}_darwin_arm64.bz2"
  name "probe restic cask"
  desc "Probe: restic release binary installed as a cask"
  homepage "https://restic.net"
  binary "restic_#{version}_darwin_arm64", target: "probe-restic-cask"
end
EOF
run brew install probe/local/probe-restic
F=$(brew --prefix)/bin/probe-restic
ls -l@ "$(readlink -f "$F")"; echo "formula xattrs:"; xattr -l "$(readlink -f "$F")"
echo "formula download in cache:"; xattr -l "$(brew --cache probe/local/probe-restic)" 2>&1
sig "$(readlink -f "$F")"
run brew install --cask probe/local/probe-restic-cask
C=$(brew --prefix)/bin/probe-restic-cask
ls -l@ "$C"; R=$(readlink -f "$C"); echo "cask target $R"; echo "cask xattrs:"; xattr -l "$R"
echo "cask download in cache:"; xattr -l "$(brew --cache --cask probe/local/probe-restic-cask)" 2>&1
echo "--- brew install --cask with --no-quarantine"
run brew uninstall --cask probe-restic-cask
run brew install --cask --no-quarantine probe/local/probe-restic-cask
xattr -l "$(readlink -f "$C")"

h "S5 Gatekeeper on quarantined CLI binaries"
cp restic_${V}_darwin_arm64 restic-q; ./setq restic-q >/dev/null
cp probe-selfsigned probe-selfsigned-q; ./setq probe-selfsigned-q >/dev/null
cp probe-adhoc probe-adhoc-q; ./setq probe-adhoc-q >/dev/null
gk_round() {
  echo "== Gatekeeper round: $1 ($(spctl --status 2>&1))"
  for f in probe-cgo0 probe-q restic-q probe-selfsigned-q probe-adhoc-q; do
    echo "--- $f quarantine=[$(xattr -p com.apple.quarantine $f 2>/dev/null)]"
    run spctl --assess --type execute -vvv ./$f
    run syspolicy_check distribution ./$f
    try_exec ./$f version
  done
  echo "--- quarantined probe run by a root LaunchDaemon"
  sudo cp -X probe-q /usr/local/libexec/probe/probe-q-$2 2>/dev/null || sudo cp probe-q /usr/local/libexec/probe/probe-q-$2
  sudo xattr -w com.apple.quarantine "$(xattr -p com.apple.quarantine probe-q)" /usr/local/libexec/probe/probe-q-$2
  xattr -l /usr/local/libexec/probe/probe-q-$2
  cat > gk.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>dev.probe.gk$2</string>
<key>ProgramArguments</key><array><string>/usr/local/libexec/probe/probe-q-$2</string><string>version</string></array>
<key>RunAtLoad</key><true/>
<key>StandardOutPath</key><string>/var/log/probe-gk$2.log</string>
<key>StandardErrorPath</key><string>/var/log/probe-gk$2.log</string>
</dict></plist>
EOF
  sudo cp gk.plist /Library/LaunchDaemons/dev.probe.gk$2.plist
  run sudo launchctl bootstrap system /Library/LaunchDaemons/dev.probe.gk$2.plist
  sleep 8
  sudo launchctl print system/dev.probe.gk$2 2>&1 | grep -E 'state|last exit|runs|pid'
  echo "daemon output:"; sudo cat /var/log/probe-gk$2.log
  sudo launchctl bootout system/dev.probe.gk$2 2>/dev/null
  echo "syspolicyd and AppleSystemPolicy log:"; gklog 3m 40
}
gk_round "as found" 1
if ! spctl --status 2>&1 | grep -q enabled; then
  run sudo spctl --global-enable || run sudo spctl --master-enable
  gk_round "after enabling" 2
fi
echo "--- removing Developer Tool grants from TCC, then again"
sudo sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" "delete from access where service='kTCCServiceDeveloperTool'" 2>&1
sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" "delete from access where service='kTCCServiceDeveloperTool'" 2>&1
sudo killall tccd 2>/dev/null; killall tccd 2>/dev/null; sleep 2
gk_round "no Developer Tool grant" 3
echo "--- quarantine removed with xattr -d"
xattr -d com.apple.quarantine probe-q; try_exec ./probe-q version
echo "--- a quarantined binary writing restic: is the new file quarantined?"
cp probe-cgo0 probe-q2; ./setq probe-q2 >/dev/null
run ./probe-q2 write-restic "$W/restic-from-q"
xattr -l "$W/restic-from-q" 2>&1

h "S6 replacing a running binary under launchd"
D=/usr/local/libexec/probe
LBL=dev.probe.daemon
cat > daemon.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LBL</string>
<key>ProgramArguments</key><array><string>$D/probe</string><string>daemon</string><string>$D/staged</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>StandardOutPath</key><string>/var/log/probe-daemon.log</string>
<key>StandardErrorPath</key><string>/var/log/probe-daemon.log</string>
</dict></plist>
EOF
st() { sudo launchctl print system/$LBL 2>&1 | grep -E '^\s*(state|pid|runs|last exit code|last terminating signal|immediate reason|last exit reason)' ; ls -li $D/probe; }
dlog() { echo "daemon log (last lines):"; sudo tail -n "${1:-6}" /var/log/probe-daemon.log; }
sudo cp probe-v1 $D/.t && sudo mv -f $D/.t $D/probe
sudo cp daemon.plist /Library/LaunchDaemons/$LBL.plist
run sudo launchctl bootstrap system /Library/LaunchDaemons/$LBL.plist
sleep 12; st; dlog 3
echo "--- B: write v2 to a temp file in the same dir, rename over, then kickstart -k"
sudo cp probe-v2 $D/.t && sudo mv -f $D/.t $D/probe
sleep 4; echo "after rename, before restart:"; st; dlog 2
run sudo launchctl kickstart -k system/$LBL
sleep 4; st; dlog 4
echo "--- C: the daemon replaces itself with a staged v3 on SIGUSR1 and exits 0; KeepAlive restarts it"
sleep 8; sudo cp probe-v3 $D/staged
P=$(sudo launchctl print system/$LBL | awk '/^\tpid =/{print $3}')
T0=$(date +%s); run sudo kill -USR1 "$P"
for i in $(seq 1 30); do sudo tail -n1 /var/log/probe-daemon.log | grep -q 'version=v3' && break; sleep 1; done
echo "v3 seen after $(( $(date +%s) - T0 ))s"; st; dlog 5
echo "--- C2: same, but the job ran under 10s (ThrottleInterval)"
sudo cp probe-v2 $D/staged
P=$(sudo launchctl print system/$LBL | awk '/^\tpid =/{print $3}')
T0=$(date +%s); run sudo kill -USR1 "$P"
for i in $(seq 1 30); do sudo tail -n1 /var/log/probe-daemon.log | grep -q 'start version=v2' && break; sleep 1; done
echo "v2 seen after $(( $(date +%s) - T0 ))s"; st; dlog 4
echo "--- A: overwrite the running binary in place with cp (same inode), then kickstart -k"
sleep 12
ls -li $D/probe; run sudo cp probe-v4 $D/probe; ls -li $D/probe
sleep 4; echo "running copy after in-place overwrite:"; st; dlog 3
run sudo launchctl kickstart -k system/$LBL
sleep 15; st; dlog 6
echo "kernel and policy log:"; gklog 1m 20
echo "--- A recovery: temp file + rename, kickstart -k"
sudo cp probe-v4 $D/.t && sudo mv -f $D/.t $D/probe
run sudo launchctl kickstart -k system/$LBL
sleep 5; st; dlog 3
echo "--- A outside launchd: run once, overwrite in place with cp, run again"
cp probe-v1 inplace; run ./inplace version
cp probe-v2 inplace; try_exec ./inplace version
echo "--- same with rm before cp (new inode)"
rm -f inplace; cp probe-v2 inplace; try_exec ./inplace version
run sudo launchctl bootout system/$LBL

h "S7 restic self-update"
mkdir -p su; cp restic_${OLDV}_darwin_arm64 su/restic
run su/restic version; ls -li su/restic
run su/restic self-update
run su/restic version; ls -li su/restic; xattr -l su/restic; sig su/restic
run codesign -v --strict su/restic
cmp su/restic restic_${V}_darwin_arm64 && echo "self-updated binary is byte-identical to the $V release binary"
echo done
