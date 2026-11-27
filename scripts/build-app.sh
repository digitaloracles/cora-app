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

# The space on this Mac: with CORA_SERVER_SRC (a digitaloracles/cora checkout) the app carries Node (universal),
# npm and the Cora server with its production dependencies. CORA_NODE_VERSION picks Node (default the latest 22).
if [[ -n "${CORA_SERVER_SRC:-}" ]]; then
  NODE_VERSION="${CORA_NODE_VERSION:-}"
  if [[ -z "$NODE_VERSION" ]]; then
    NODE_VERSION="$(curl -fsSL https://nodejs.org/dist/latest-v22.x/SHASUMS256.txt | sed -nE 's/.*node-(v22\.[0-9]+\.[0-9]+)-darwin-arm64\.tar\.gz$/\1/p' | head -1)"
  fi
  NODE_CACHE="$ROOT/build/node-$NODE_VERSION"
  mkdir -p "$NODE_CACHE"
  curl -fsSL "https://nodejs.org/dist/$NODE_VERSION/SHASUMS256.txt" -o "$NODE_CACHE/SHASUMS256.txt"
  for arch in arm64 x64; do
    TARBALL="node-$NODE_VERSION-darwin-$arch.tar.gz"
    [[ -f "$NODE_CACHE/$TARBALL" ]] || curl -fsSL "https://nodejs.org/dist/$NODE_VERSION/$TARBALL" -o "$NODE_CACHE/$TARBALL"
    (cd "$NODE_CACHE" && grep " $TARBALL\$" SHASUMS256.txt | shasum -a 256 -c -)
    [[ -d "$NODE_CACHE/$arch" ]] || { mkdir -p "$NODE_CACHE/$arch" && tar -xzf "$NODE_CACHE/$TARBALL" -C "$NODE_CACHE/$arch" --strip-components 1; }
  done
  lipo -create "$NODE_CACHE/arm64/bin/node" "$NODE_CACHE/x64/bin/node" -output "$APP/Contents/MacOS/cora-node"
  chmod 755 "$APP/Contents/MacOS/cora-node"
  ditto "$NODE_CACHE/arm64/lib/node_modules/npm" "$APP/Contents/Resources/cora-npm"

  SERVER="$APP/Contents/Resources/cora-server"
  mkdir -p "$SERVER"
  for part in src web box package.json package-lock.json LICENSE; do ditto "$CORA_SERVER_SRC/$part" "$SERVER/$part"; done
  PATH="$NODE_CACHE/arm64/bin:$PATH" npm ci --prefix "$SERVER" --omit=dev --no-audit --no-fund --ignore-scripts --loglevel error
  "$APP/Contents/MacOS/cora-node" -e 'console.log("bundled node", process.version, process.arch)'
  echo "Bundled Node $NODE_VERSION and Cora $(cd "$CORA_SERVER_SRC" && git rev-parse --short HEAD 2>/dev/null || echo '?')"
fi

KEYCHAIN=()
[[ -n "${CORA_SIGN_KEYCHAIN:-}" ]] && KEYCHAIN=(--keychain "$CORA_SIGN_KEYCHAIN")
# Everything that runs inside the app is signed first: Node with the entitlements a JIT and the agents' native
# modules need, then every other Mach-O file the server or npm brings.
nested() {
  local entitlements="$ROOT/Resources/node.entitlements"
  [[ -x "$APP/Contents/MacOS/cora-node" ]] || return 0
  find "$APP/Contents/Resources/cora-server" "$APP/Contents/Resources/cora-npm" -type f \( -name '*.node' -o -name '*.dylib' -o -perm -u+x \) -print0 |
    while IFS= read -r -d '' file; do
      file -b "$file" | grep -q 'Mach-O' && codesign --force "$@" "$file"
    done
  codesign --force "$@" --entitlements "$entitlements" "$APP/Contents/MacOS/cora-node"
}

if [[ -n "${CORA_DEVELOPER_ID_IDENTITY:-}" ]]; then
  nested --timestamp --options runtime --sign "$CORA_DEVELOPER_ID_IDENTITY" "${KEYCHAIN[@]}"
  codesign --force --timestamp --options runtime --sign "$CORA_DEVELOPER_ID_IDENTITY" "${KEYCHAIN[@]}" \
    -r="designated => identifier \"space.usecora.app\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"89J2AG5K92\"" "$APP"
elif [[ -n "${CORA_SIGN_IDENTITY:-}" ]]; then
  nested --timestamp=none --options runtime --sign "$CORA_SIGN_IDENTITY" "${KEYCHAIN[@]}"
  codesign --force --timestamp=none --sign "$CORA_SIGN_IDENTITY" "${KEYCHAIN[@]}" \
    -r="designated => identifier \"space.usecora.app\" and certificate leaf = H\"2e8eb3a66aba555b215bc2e43efcec16bc0f7298\"" "$APP"
else
  nested --sign -
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
