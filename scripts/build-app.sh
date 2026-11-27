#!/bin/zsh
# Builds build/Cora.app, signed with CORA_DEVELOPER_ID_IDENTITY (Developer ID Application, hardened runtime, ready for notarization), else CORA_SIGN_IDENTITY (the self-signed Cora certificate), else ad-hoc. Both pinned requirements keep Keychain access across updates. --install copies it to ~/Applications and registers the cora:// links.
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

swift build -c release
BIN="$(swift build -c release --show-bin-path)"

APP="$ROOT/build/Cora.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Cora" "$APP/Contents/MacOS/Cora"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/*.lproj Resources/ProviderIcons "$APP/Contents/Resources/"

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

KEYCHAIN=()
[[ -n "${CORA_SIGN_KEYCHAIN:-}" ]] && KEYCHAIN=(--keychain "$CORA_SIGN_KEYCHAIN")
if [[ -n "${CORA_DEVELOPER_ID_IDENTITY:-}" ]]; then
  codesign --force --timestamp --options runtime --sign "$CORA_DEVELOPER_ID_IDENTITY" "${KEYCHAIN[@]}" \
    -r="designated => identifier \"space.usecora.app\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"89J2AG5K92\"" "$APP"
elif [[ -n "${CORA_SIGN_IDENTITY:-}" ]]; then
  codesign --force --timestamp=none --sign "$CORA_SIGN_IDENTITY" "${KEYCHAIN[@]}" \
    -r="designated => identifier \"space.usecora.app\" and certificate leaf = H\"2e8eb3a66aba555b215bc2e43efcec16bc0f7298\"" "$APP"
else
  codesign --force --sign - "$APP"
fi
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  DEST="$HOME/Applications/Cora.app"
  pkill -x Cora 2>/dev/null || true
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
  echo "Installed $DEST"
fi
