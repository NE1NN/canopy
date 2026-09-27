#!/usr/bin/env bash
# Creates a self-signed code signing certificate named "Canopy Dev" in the login keychain.
# A stable identity keeps macOS privacy permissions across rebuilds. macOS asks for your
# password once to trust the certificate for code signing.
set -euo pipefail

name="Canopy Dev"
keychain="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$name\""; then
    echo "\"$name\" already exists."
    exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat > "$work/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$work/cert.cnf" -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" \
    -name "$name" -out "$work/cert.p12" -passout pass:canopy
security import "$work/cert.p12" -k "$keychain" -P canopy -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$work/cert.pem"

security find-identity -v -p codesigning | grep "\"$name\""
