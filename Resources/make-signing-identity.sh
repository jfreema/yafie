#!/bin/zsh
# Creates "Yafie Code Signing", the self-signed identity build.sh signs with. One identity for every build
# means macOS keeps Yafie's permissions (Accessibility, Microphone) across updates. Run once, then back it up.
set -euo pipefail

NAME="Yafie Code Signing"
if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
    echo "\"$NAME\" already exists"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASSWORD="$(uuidgen)"  # only protects the file in transit to the keychain

openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -subj "/CN=$NAME" \
    -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
# Keychain Access names the key after the file
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
    -passout "pass:$PASSWORD" -out "$WORK/$NAME.p12"
security import "$WORK/$NAME.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASSWORD" -T /usr/bin/codesign

# codesign only uses certificates trusted for code signing. macOS asks for your password.
security add-trusted-cert -r trustRoot -p codeSign "$WORK/cert.pem"

echo "Created \"$NAME\". Back it up: in Keychain Access, select it under login → My Certificates,"
echo "then File → Export Items… as a .p12 with a password, and keep both somewhere safe."
