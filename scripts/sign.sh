#!/bin/zsh
# Sign Headroom with a stable self-signed identity ("Headroom Local").
# Ad-hoc signatures change every build, so Keychain can never match a
# rebuilt binary to a previous "Always Allow" consent — every rebuild and
# every keychain read re-prompts. A persistent certificate makes consent
# stick across rebuilds. The cert lives in a dedicated keychain under the
# app's own support dir so no login-keychain password is ever needed.
set -eu

#
# HEADROOM_SIGN_IDENTITY selects another path:
#   -                                   ad-hoc, for CI builds and release dry runs
#   Developer ID Application: … (TEAM)  hardened runtime + secure timestamps
# HEADROOM_SIGN_KEYCHAIN optionally names the keychain holding that identity
# (CI imports the certificate into a throwaway keychain).
# Sparkle's nested code is signed inside-out, then the host app; it must use
# the same team as the app for library validation.
if [[ -n "${HEADROOM_SIGN_IDENTITY:-}" ]]; then
    APP="$1"
    FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
    if [[ "$HEADROOM_SIGN_IDENTITY" == "-" ]]; then
        flags=(--sign -)  # no hardened runtime: ad-hoc code has no team for library validation
    else
        flags=(--options runtime --timestamp --sign "$HEADROOM_SIGN_IDENTITY")
        [[ -n "${HEADROOM_SIGN_KEYCHAIN:-}" ]] && flags+=(--keychain "$HEADROOM_SIGN_KEYCHAIN")
    fi
    for NESTED in "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc" \
                  "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc" \
                  "$FRAMEWORK/Versions/B/Autoupdate" \
                  "$FRAMEWORK/Versions/B/Updater.app" "$FRAMEWORK"; do
        codesign --force --preserve-metadata=entitlements "${flags[@]}" "$NESTED"
    done
    codesign --force "${flags[@]}" "$APP"
    codesign --verify --deep --strict "$APP"
    exit 0
fi

IDENTITY="Headroom Local"
SIGNING_DIR="$HOME/Library/Application Support/Headroom/signing"
KC="$SIGNING_DIR/headroom-signing.keychain-db"
PW_FILE="$SIGNING_DIR/password"
APP="$1"

# A locked keychain reports no usable identities. Unlock an existing store
# before checking it so rebuilds keep the certificate and its keychain consent.
if [[ -f "$KC" && -f "$PW_FILE" ]]; then
    PW=$(cat "$PW_FILE")
    security unlock-keychain -p "$PW" "$KC"
fi

# Self-signed local identities aren't system-trusted, so `-v` would omit
# them and accidentally recreate the certificate on every build.
if ! security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "$IDENTITY"; then
    mkdir -p "$SIGNING_DIR"
    PW=$(openssl rand -hex 16)
    printf '%s' "$PW" > "$PW_FILE" && chmod 600 "$PW_FILE"
    rm -f "$KC"
    security create-keychain -p "$PW" "$KC"
    security unlock-keychain -p "$PW" "$KC"
    cat > "$SIGNING_DIR/cert.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = Headroom Local
[v3]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = codeSigning
CNF
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$SIGNING_DIR/key.pem" -out "$SIGNING_DIR/cert.pem" \
        -config "$SIGNING_DIR/cert.cnf" 2>/dev/null
    security import "$SIGNING_DIR/cert.pem" -k "$KC" -T /usr/bin/codesign
    security import "$SIGNING_DIR/key.pem" -k "$KC" -P '' -T /usr/bin/codesign
    security set-key-partition-list -S apple-tool:,apple: -s -k "$PW" "$KC" >/dev/null
    rm -f "$SIGNING_DIR/key.pem" "$SIGNING_DIR/cert.pem" "$SIGNING_DIR/cert.cnf"
    security lock-keychain "$KC" 2>/dev/null || true
fi

PW=$(cat "$PW_FILE")
security unlock-keychain -p "$PW" "$KC"
# Put our keychain first on the user search list while signing, then restore.
ORIGINAL=$(security list-keychains -d user | tr -d '"' | tr -d ' ')
security list-keychains -d user -s "$KC" $ORIGINAL
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
security list-keychains -d user -s $ORIGINAL
security lock-keychain "$KC" 2>/dev/null || true
