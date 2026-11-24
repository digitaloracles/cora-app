#!/bin/bash
set -euo pipefail
mkdir -p "$2"
node qa/server.mjs > build/fixture.log 2>&1 &
pid=$!
trap 'kill "$pid" || true' EXIT
for i in {1..60}; do if curl -fsS localhost:19428/state 2>/dev/null | grep -q active/1/2; then break; fi; sleep 1; done
case "$1" in
macOS)
  # The menu-bar app starts without a window. Open its usual Plans window on launch for UI testing.
  python3 - <<'PY'
from pathlib import Path
p=Path('Sources/Cora/AppDelegate.swift')
s=p.read_text().replace('        spaces.start()', """        spaces.start()
        Task { @MainActor in
            do {
                let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:19428/pair")!)
                let url = URL(string: String(decoding: data, as: UTF8.self))!
                await spaces.current.connect(try ConnectLink.parse(url))
                showWindow(agent: LiveSelection.plans)
            } catch { fatalError("Fixture pairing failed") }
        }""")
p.write_text(s)
PY
  (cd qa && xcodegen generate -s mac.yml)
  args=(-project qa/PlanMac.xcodeproj -scheme PlanMac -destination 'platform=macOS' -derivedDataPath build/ui CODE_SIGN_IDENTITY=-)
  xcodebuild build "${args[@]}" > "$2/build.log" 2>&1 || { tail -70 "$2/build.log"; exit 1; }
  filter=CloseUI/ClosePlanTests
  ;;
iOS)
  python3 - <<'PYIOS'
from pathlib import Path
p=Path("ios/Cora/CoraApp.swift")
s=p.read_text().replace(".onAppear { notices.scheduleDemoNotice() }", """.onAppear { notices.scheduleDemoNotice() }
                .task {
                    guard spaces.stores.isEmpty else { return }
                    do {
                        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:19428/pair")!)
                        let url = URL(string: String(decoding: data, as: UTF8.self))!
                        await spaces.connect(try ConnectLink.parse(url))
                    } catch { fatalError("Fixture pairing failed") }
                }""")
p.write_text(s)
PYIOS
  cp qa/UITests/ClosePlanTests.swift ios/CoraUITests/
  (cd ios && xcodegen generate)
  device=$(xcrun simctl list devices available -j | python3 -c 'import json,re,sys; d=json.load(sys.stdin)["devices"]; print(next(v["udid"] for k in sorted(d,key=lambda x: list(map(int,re.findall(r"[0-9]+",x))),reverse=True) if "iOS" in k for v in d[k] if re.match(r"iPhone [0-9]+ Pro$",v["name"])))')
  xcrun simctl boot "$device" || true
  xcrun simctl bootstatus "$device" -b
  args=(-project ios/CoraiOS.xcodeproj -scheme Cora -destination "id=$device" -derivedDataPath build/ui CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=)
  filter=CoraUITests/ClosePlanTests
  ;;
esac
status=0
xcodebuild test "${args[@]}" -only-testing:"$filter" -parallel-testing-enabled NO -resultBundlePath "build/Close-$1.xcresult" > "$2/test.log" 2>&1 || status=$?
tail -75 "$2/test.log"
if [ -d "build/Close-$1.xcresult" ]; then
 xcrun xcresulttool export attachments --path "build/Close-$1.xcresult" --output-path "$2/screens" || true
fi
exit "$status"
