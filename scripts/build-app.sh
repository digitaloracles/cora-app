#!/bin/zsh
# Builds build/Cora.app, signed with CORA_DEVELOPER_ID_IDENTITY (Developer ID Application, hardened runtime, ready for notarization), else CORA_SIGN_IDENTITY (the self-signed Cora certificate), else ad-hoc. Both pinned requirements keep Keychain access across updates. --install copies it to ~/Applications and registers the cora:// links.
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

# Universal: the app runs on Apple silicon and on Intel Macs.
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

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

  # The agents' computers: Colima starts one Linux VM (Lima, Apple Virtualization) where each agent's cora-box container
  # runs, driven by the Docker client. Pinned versions, checked against their published SHA-256, made universal.
  COLIMA_VERSION="${CORA_COLIMA_VERSION:-v0.10.3}"
  LIMA_VERSION="${CORA_LIMA_VERSION:-2.3.0}"
  DOCKER_VERSION="${CORA_DOCKER_VERSION:-29.10.1}"
  VM_CACHE="$ROOT/build/vm-$COLIMA_VERSION-$LIMA_VERSION-$DOCKER_VERSION"
  VM="$APP/Contents/Resources/cora-vm"
  mkdir -p "$VM_CACHE" "$VM/bin" "$VM/share/lima"
  for arch in arm64 x86_64; do
    docker_arch=$([[ $arch == arm64 ]] && echo aarch64 || echo x86_64)
    mkdir -p "$VM_CACHE/$arch"
    (
      cd "$VM_CACHE/$arch"
      [[ -f colima ]] || {
        curl -fsSL -o colima "https://github.com/abiosoft/colima/releases/download/$COLIMA_VERSION/colima-Darwin-$arch"
        curl -fsSL "https://github.com/abiosoft/colima/releases/download/$COLIMA_VERSION/colima-Darwin-$arch.sha256sum" | awk '{print $1"  colima"}' | shasum -a 256 -c -
      }
      [[ -d lima ]] || {
        TARBALL="lima-$LIMA_VERSION-Darwin-$arch.tar.gz"
        curl -fsSL -o "$TARBALL" "https://github.com/lima-vm/lima/releases/download/v$LIMA_VERSION/$TARBALL"
        curl -fsSL "https://github.com/lima-vm/lima/releases/download/v$LIMA_VERSION/SHA256SUMS" | grep " $TARBALL\$" | shasum -a 256 -c -
        mkdir lima && tar -xzf "$TARBALL" -C lima
      }
      [[ -d docker ]] || curl -fsSL "https://download.docker.com/mac/static/stable/$docker_arch/docker-$DOCKER_VERSION.tgz" | tar -xz
    )
  done
  lipo -create "$VM_CACHE/arm64/colima" "$VM_CACHE/x86_64/colima" -output "$VM/bin/colima"
  lipo -create "$VM_CACHE/arm64/lima/bin/limactl" "$VM_CACHE/x86_64/lima/bin/limactl" -output "$VM/bin/limactl"
  # Colima checks for Lima by its `lima` script, which only calls limactl.
  cp "$VM_CACHE/arm64/lima/bin/lima" "$VM/bin/lima"
  lipo -create "$VM_CACHE/arm64/docker/docker" "$VM_CACHE/x86_64/docker/docker" -output "$VM/bin/docker"
  chmod 755 "$VM/bin/"*
  # Linux guests only: each architecture's guest agent and Lima's templates.
  ditto "$VM_CACHE/arm64/lima/share/lima/templates" "$VM/share/lima/templates"
  cp "$VM_CACHE"/arm64/lima/share/lima/lima-guestagent.Linux-*.gz "$VM_CACHE"/x86_64/lima/share/lima/lima-guestagent.Linux-*.gz "$VM/share/lima/"
  "$VM/bin/colima" version | head -1
  "$VM/bin/limactl" --version
  "$VM/bin/docker" --version
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
  local vm="$APP/Contents/Resources/cora-vm/bin"
  [[ -d "$vm" ]] || return 0
  codesign --force "$@" "$vm/colima"
  codesign --force "$@" "$vm/docker"
  codesign --force "$@" --entitlements "$ROOT/Resources/vm.entitlements" "$vm/limactl"
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
