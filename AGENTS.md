# Cora for macOS: agent instructions

Native macOS app (Swift 6 toolchain, Swift 5 language mode, AppKit + SwiftUI, SwiftPM): a menu bar that reads Cora spaces with device tokens, a window that shows a space's panel, and a space that runs on the Mac itself (the Cora server plus a Colima VM where each agent's `cora-box` container runs). The iPhone app lives in `ios/`.

## Layout

- `Sources/CoraKit`: models of the app API (`Snapshot`, `Agent`, `Account`, `QuotaWindow`, `Step`, `TraceDetail`, `Plan`, `PlanBoard`), the `cora://connect` link and space addresses (`Pairing.swift`), the HTTP and SSE client (`Client.swift`), Keychain and connection storage (`Storage.swift`), formatting. No UI. Decoding is lenient: unknown kinds and broken list items are skipped, never fatal, because the server may be newer than the app.
- `Sources/CoraKit/LocalSpace.swift`: the space on this Mac as data: its folder (`~/Library/Application Support/Cora/Local`), the runtime folder for Colima, Lima and Docker (`~/.cora-local`, short because their sockets live there), the VM size and `colima start` arguments, the server's environment and `PATH`, and the two LaunchAgents (`space.usecora.local` for the server on `127.0.0.1:4370`, `space.usecora.vm` for the VM).
- `Sources/Cora`: the app. `Spaces` (every connected space, one on screen), `SpaceStore` (connection, snapshot, live steps, older plans, plan reasoning), `StatusItemController` (menu bar + popover), `PopoverView`, `PanelWindow` (the Cora window: welcome, local wizard, remote connection, the panel in a web view, the space menu at the top left), `LocalSpaceController` (the wizard's steps: folder, engines, machine, computer, server, sign-in, menu bar; which engines this Mac has, from `CoraKit/AgentEngines`; and bringing the space back at launch), `LiveWindow`, `PlansView` (plans in progress and history), `Components`, `CLI` (command line and rendering), `Samples` (preview data).
- `Tests/CoraKitTests`: Swift Testing suites with a JSON fixture of the snapshot.
- `scripts/e2e.mjs`: end-to-end check against a real Cora server started from a `digitaloracles/cora` checkout (its `test/knowledge-fixtures.js`).
- `scripts/e2e-video/`: the notarized DMG on a clean Mac, driven through accessibility (`drive.swift`) and recorded: install, create the space on this Mac, create an agent, set its model and key in the Brain tab, use its shell, browser and desktop; `closed.mjs` checks the space with the app quit. `dmg-run` names the CI run whose DMG a push to `buzz/not120-video` replays.
- `DESIGN.md`: read before any UI change; update it when adding patterns.

## Commands

- Test: `swift test`.
- Build the bundle: `scripts/build-app.sh` (`--install` copies to `~/Applications` and registers `cora://`). With `CORA_SERVER_SRC=<cora checkout>` it also bundles universal Node, npm, the server (with the other architecture's native modules) and its `box/`, and pinned Colima, Lima and Docker client binaries checked against their SHA-256 and merged with `lipo`.
- Previews: `build/Cora.app/Contents/MacOS/Cora --render-preview <dir>`; with real data: `--render-live <dir>` after `--connect`.
- End-to-end: `node scripts/e2e.mjs build/Cora.app <cora checkout> <out dir>` (needs `npm ci` in the checkout). CI runs it on `macos-15` against `CORA_REF`.
- CI (`.github/workflows/ci.yml`), outside pull requests: `build` signs, notarizes and packages; `box` builds `cora-box` from `CORA_REF`'s `box/` on native Linux runners (`ubuntu-24.04` for x86_64, `ubuntu-24.04-arm` for arm64) and uploads `cora-box-<arch>.tar.gz` to the public pre-release `cora-box-<hash>`, skipped when already there; `video` runs `e2e-video.yml` on `macos-15-intel`, because GitHub's Apple silicon runners cannot start a VM inside. A `v*` tag publishes `Cora.dmg` and `Cora.zip`.

## Rules

- Device writes cover session and push registration, answering or dismissing questions, and closing a manageable plan at its displayed revision.
- The token lives only in the Keychain, never in files, logs, previews or CLI output. `connection.json` holds server, names and device id.
- A `cora://connect` link the app did not request (state missing or different) is confirmed by the person before connecting. Only `https` servers, or loopback `http` for local tests.
- A 401 from any call or `access-revoked` on the stream forgets the connection and asks to connect again.
- Keep the API backward compatible with older apps, and the app tolerant of newer servers.
- With the macOS 27 SDK `@State` needs a macro plugin missing from the Command Line Tools: keep view state in `ObservableObject`s.
- The space on this Mac: the wizard only installs and prepares. It asks for nothing and sets up no model, key or agent; it ends on the panel's **New agent**, and each agent's model and key are set in its Brain tab.
- Agents' computers stay Linux (`cora-box`, Debian) containers in the Colima VM: no macOS desktops.
- Spaces are added only from the Cora window's space menu (top left), never from the menu bar. A local space and remote spaces coexist.
- Colima, Lima and Docker run with their own homes under `~/.cora-local`: never touch the person's `~/.colima`, `~/.docker` or Docker contexts (`--activate=false`).
- The box hash is the first 16 hex digits of the SHA-256 of the files in `box/`, concatenated in name order; the app (`LocalSpaceController.boxHash`), the `box` job and Cora's `deploy/macos.sh` must compute it the same way. Building the image on the person's Mac is only the fallback.
- The server's `PATH` must include the person's login shell `PATH` (`LocalSpaceController.loginPath`), or installed CLIs show as not installed.
- Docs and code in English; UI copy English with an Italian localization in `Resources/it.lproj`.
