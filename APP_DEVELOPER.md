# Native app development

The Swift package targets macOS 14 and iOS 17. Use the paired space and its device token from the Keychain for live checks. Use a test space and disposable plans for mutations.

On macOS, run `swift test`, build with `scripts/build-app.sh`, and exercise the installed bundle. The CI workflow renders previews and runs `scripts/e2e.mjs` against a Cora checkout. Check the signing identity and bundle version before distributing the signed zip.

## The space on this Mac

Test it from the notarized DMG on a clean Mac, not from a development build on a Mac that already has a space: the VM, the image and the LaunchAgents persist across installs. The `video` CI job does this on `macos-15-intel` with an Italian system language, using the `E2E_DEEPSEEK_API_KEY` secret for the agent's key, and keeps the recording, the driver log and the tails of `cora.log` and the VM log as the `e2e-video` artifact. A run passes when:

- the space answers on `127.0.0.1:4370` and the window shows the panel on **New agent**;
- an agent created in the panel saves its model and key in the Brain tab (checked in the database);
- the agent writes a file with its shell inside its `cora-box` container, opens a page with its browser (`open_url` in its turn), and the panel's Desktop tab shows its desktop;
- with the app quit the space still answers, and the LaunchAgent restarts a killed server.

The panel's floating chat button («Chat con Lia» in the Italian run) can cover controls that fall in the window's bottom right corner: the driver presses those as accessibility actions.

For a release, check the downloaded zip: version and build in `Info.plist`, both native architectures of the server's native modules, and that the box hash of the bundled `box/` matches a published `cora-box-<hash>` release with both `cora-box-arm64.tar.gz` and `cora-box-x86_64.tar.gz`.

Not yet covered by an automated run: a Mac restart, an interrupted install, removing the space.

On iOS, generate the project with XcodeGen in `ios/`. Build and test the Cora scheme on an iPhone simulator. The iOS workflow captures localized screenshots, runs UI tests and packages signed development builds for registered devices. Verify pairing, session restoration and the changed screens on the distributed build. Record the tested build, server version and screenshots with release evidence.

## macOS signing and notarization

CI signs `Cora.app` on every non-pull-request run with the Developer ID Application certificate of team 89J2AG5K92 (SHA-1 `A838170BF5F33922C8545DD1461CD45AC0C30CFB`, valid until 2027-12-27), with hardened runtime and a secure timestamp. The designated requirement is pinned to the bundle identifier and the team, so Keychain access survives updates and certificate renewals. The workflow notarizes and staples the app, builds `Cora.dmg` (app plus an Applications link), signs, notarizes and staples the DMG, and fails unless `spctl` reports `source=Notarized Developer ID`. Tagged releases publish `Cora.dmg` and `Cora.zip`.

Secrets: `CORA_APP_DEVELOPER_ID_P12` (base64 PKCS#12 with the certificate, its private key and the Developer ID G2 intermediate) and `CORA_APP_DEVELOPER_ID_P12_PASSWORD`, also stored under the same names in hush on the Mac Pro. Notarization uses the team App Store Connect key in `ASC_KEY_P8`, `ASC_KEY_ID` and `ASC_ISSUER_ID`. A Developer ID certificate can only be created by the Account Holder on developer.apple.com: the API key cannot create it. `CORA_APP_SIGNING_P12` (the self-signed Cora certificate) is no longer used by CI.

