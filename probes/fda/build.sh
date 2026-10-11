#!/bin/bash
# Builds the probe binaries, makes two self-signed code-signing identities and
# downloads restic. Runs as the runner user. Output goes to $BUILD and $OUT.
set -euo pipefail
BUILD=${BUILD:?} OUT=${OUT:?}
mkdir -p "$BUILD" "$OUT"
exec > >(tee -a "$OUT/build.log") 2>&1
cd "$(dirname "$0")"

echo "##### environment"
sw_vers; uname -m; csrutil status || true; go version
echo "ImageVersion=${ImageVersion:-?} ImageOS=${ImageOS:-?}"

echo "##### go builds (default linker signature)"
for v in v1 v2 launcher worker1 worker2; do
  go build -trimpath -ldflags "-X main.version=$v" -o "$BUILD/probe-$v" .
  echo "--- probe-$v"
  codesign -dvvv "$BUILD/probe-$v" 2>&1 | grep -E '^(Identifier|Format|CodeDirectory|Signature|CDHash|Authority|TeamIdentifier)=|flags' || true
  codesign -d -r- "$BUILD/probe-$v" 2>&1 | grep designated || true
done

echo "##### self-signed code-signing identities"
KC="$HOME/Library/Keychains/fdaprobe-signing.keychain-db"
security create-keychain -p pw "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p pw "$KC"
security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
cat > "$BUILD/cert.cnf.in" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = @CN@
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
for n in 1 2; do
  sed "s/@CN@/FDA Probe Signer $n/" "$BUILD/cert.cnf.in" > "$BUILD/cert$n.cnf"
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$BUILD/cert$n.cnf" -keyout "$BUILD/key$n.pem" -out "$BUILD/cert$n.pem"
  /usr/bin/openssl pkcs12 -export -inkey "$BUILD/key$n.pem" -in "$BUILD/cert$n.pem" -out "$BUILD/id$n.p12" -passout pass:pw
  security import "$BUILD/id$n.p12" -k "$KC" -P pw -T /usr/bin/codesign
done
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k pw "$KC" >/dev/null
echo "--- find-identity (all, then valid only)"
security find-identity -p codesigning "$KC" || true
security find-identity -v -p codesigning "$KC" || true

sign() { # src dest cert-number
  cp "$1" "$2"
  local h; h=$(/usr/bin/openssl x509 -in "$BUILD/cert$3.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')
  codesign -f -s "$h" --keychain "$KC" -i com.example.fdaprobe "$2"
  echo "--- $(basename "$2") (cert $3)"
  codesign -dvvv "$2" 2>&1 | grep -E '^(Identifier|CDHash|Authority|TeamIdentifier)=|flags' || true
  codesign -d -r- "$2" 2>&1 | grep designated || true
}
sign "$BUILD/probe-v1" "$BUILD/signed-v1-cert1" 1
sign "$BUILD/probe-v2" "$BUILD/signed-v2-cert1" 1
sign "$BUILD/probe-v2" "$BUILD/signed-v2-cert2" 2

echo "##### restic"
curl -fsSL -o "$BUILD/restic.bz2" https://github.com/restic/restic/releases/download/v0.19.1/restic_0.19.1_darwin_arm64.bz2
bunzip2 -f "$BUILD/restic.bz2"; chmod 755 "$BUILD/restic"
"$BUILD/restic" version
codesign -dvvv "$BUILD/restic" 2>&1 | grep -E '^(Identifier|CDHash)=|flags' || true
