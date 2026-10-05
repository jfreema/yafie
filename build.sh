#!/bin/zsh
# Usage: ./build.sh [--install|--pkg]
set -euo pipefail
cd "$(dirname "$0")"

NAME="Yafie"
APP="build/$NAME.app"
MODE="${1:-}"

# Release also covers Intel
ARCHS=()
[[ "$MODE" == "--pkg" ]] && ARCHS=(--arch arm64 --arch x86_64)

swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/$NAME"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/MenuIcon.tiff Resources/MenuIconOutline.tiff "$APP/Contents/Resources/"

# One identity for every build, so macOS keeps Yafie's permissions across updates. See docs/buildfromsource.md.
# YAFIE_SIGNING_IDENTITY names another, for testing.
IDENTITY="${YAFIE_SIGNING_IDENTITY:-Yafie Code Signing}"
if security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
    codesign --force --strip-disallowed-xattrs --sign "$IDENTITY" "$APP"
    SIGNED_BY="$IDENTITY"
elif security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
    # Here but not trusted, as on GitHub's Macs, so codesign won't use it
    xattr -cr "$APP"
    ./Resources/sign-untrusted.swift "$IDENTITY" "$APP"
    SIGNED_BY="$IDENTITY, through the signing API"
elif [[ "$MODE" == "--pkg" ]]; then
    echo "No \"$IDENTITY\" identity. A release signed ad hoc would reset everyone's permissions." >&2
    echo "Run Resources/make-signing-identity.sh, or import the backup, first." >&2
    exit 1
else
    codesign --force --strip-disallowed-xattrs --sign - "$APP"  # ad hoc is enough for a build from source
    SIGNED_BY="ad hoc"
fi
echo "Built $APP (signed by $SIGNED_BY)"

if [[ "$MODE" == "--install" ]]; then
    # SIGTERM lets it restore sleep
    if pkill -x "$NAME"; then
        for _ in {1..25}; do
            pgrep -x "$NAME" >/dev/null || break
            sleep 0.2
        done
    fi
    rm -rf "/Applications/$NAME.app"
    ditto "$APP" "/Applications/$NAME.app"
    open "/Applications/$NAME.app"
    echo "Installed /Applications/$NAME.app"
fi

if [[ "$MODE" == "--pkg" ]]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
    ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' Resources/Info.plist)"
    MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' Resources/Info.plist)"
    # Fixed name keeps the README download link stable
    PKG="downloads/$NAME.pkg"
    WORK="build/pkg"
    rm -rf "$WORK"
    mkdir -p "$WORK/root" downloads
    ditto "$APP" "$WORK/root/$NAME.app"

    # Always /Applications, never "relocated" onto another copy macOS knows about
    pkgbuild --analyze --root "$WORK/root" "$WORK/component.plist" >/dev/null
    /usr/libexec/PlistBuddy -c 'Set :0:BundleIsRelocatable false' "$WORK/component.plist"
    pkgbuild --root "$WORK/root" --component-plist "$WORK/component.plist" --scripts Resources/pkg/scripts \
        --identifier "$ID" --version "$VERSION" --install-location /Applications "$WORK/$NAME-app.pkg" >/dev/null

    # Installer's title, checks, and closing page
    cat > "$WORK/distribution.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>$NAME</title>
    <conclusion file="conclusion.txt" mime-type="text/plain"/>
    <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
    <domains enable_localSystem="true"/>
    <volume-check>
        <allowed-os-versions>
            <os-version min="$MIN_OS"/>
        </allowed-os-versions>
    </volume-check>
    <choices-outline>
        <line choice="$ID"/>
    </choices-outline>
    <choice id="$ID" visible="false">
        <pkg-ref id="$ID"/>
    </choice>
    <pkg-ref id="$ID" version="$VERSION" onConclusion="none">$NAME-app.pkg</pkg-ref>
</installer-gui-script>
EOF
    rm -f "$PKG"
    productbuild --distribution "$WORK/distribution.xml" --resources Resources/pkg/resources \
        --package-path "$WORK" "$PKG" >/dev/null
    rm -rf "$WORK"

    # What Check for Updates reads. The hash lets it reject a stale or broken download.
    cat > downloads/latest.json <<EOF
{
  "version": "$VERSION",
  "url": "https://github.com/jfreema/yafie/raw/main/downloads/$NAME.pkg",
  "sha256": "$(shasum -a 256 "$PKG" | cut -d' ' -f1)"
}
EOF
    # README shows the version next to the download link
    sed -i '' -E "s/Version [0-9.]+ ·/Version $VERSION ·/" README.md
    echo "Built $PKG ($VERSION) and downloads/latest.json"
fi
