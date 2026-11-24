# Cora for macOS: agent instructions

Native macOS menu bar app (Swift 6 toolchain, Swift 5 language mode, AppKit + SwiftUI, SwiftPM) that reads one Cora space with a device token. macOS only for now; no iOS target.

## Layout

- `Sources/CoraKit`: models of the app API (`Snapshot`, `Agent`, `Account`, `QuotaWindow`, `Step`, `TraceDetail`, `Plan`, `PlanBoard`), the `cora://connect` link and space addresses (`Pairing.swift`), the HTTP and SSE client (`Client.swift`), Keychain and connection storage (`Storage.swift`), formatting. No UI. Decoding is lenient: unknown kinds and broken list items are skipped, never fatal, because the server may be newer than the app.
- `Sources/Cora`: the app. `SpaceStore` (connection, snapshot, live steps, older plans, plan reasoning), `StatusItemController` (menu bar + popover), `PopoverView`, `LiveWindow`, `PlansView` (plans in progress and history), `Components`, `CLI` (command line and rendering), `Samples` (preview data).
- `Tests/CoraKitTests`: Swift Testing suites with a JSON fixture of the snapshot.
- `scripts/e2e.mjs`: end-to-end check against a real Cora server started from a `digitaloracles/cora` checkout (its `test/knowledge-fixtures.js`).
- `DESIGN.md`: read before any UI change; update it when adding patterns.

## Commands

- Test: `swift test`.
- Build the bundle: `scripts/build-app.sh` (`--install` copies to `~/Applications` and registers `cora://`).
- Previews: `build/Cora.app/Contents/MacOS/Cora --render-preview <dir>`; with real data: `--render-live <dir>` after `--connect`.
- End-to-end: `node scripts/e2e.mjs build/Cora.app <cora checkout> <out dir>` (needs `npm ci` in the checkout). CI runs it on `macos-15` against `CORA_REF`.

## Rules

- Device writes cover session and push registration, answering or dismissing questions, and closing a manageable plan at its displayed revision.
- The token lives only in the Keychain, never in files, logs, previews or CLI output. `connection.json` holds server, names and device id.
- A `cora://connect` link the app did not request (state missing or different) is confirmed by the person before connecting. Only `https` servers, or loopback `http` for local tests.
- A 401 from any call or `access-revoked` on the stream forgets the connection and asks to connect again.
- Keep the API backward compatible with older apps, and the app tolerant of newer servers.
- With the macOS 27 SDK `@State` needs a macro plugin missing from the Command Line Tools: keep view state in `ObservableObject`s.
- Docs and code in English; UI copy English with an Italian localization in `Resources/it.lproj`.
