# Native app development

The Swift package targets macOS 14 and iOS 17. Use the paired space and its device token from the Keychain for live checks. Use a test space and disposable plans for mutations.

On macOS, run `swift test`, build with `scripts/build-app.sh`, and exercise the installed bundle. The CI workflow renders previews and runs `scripts/e2e.mjs` against a Cora checkout. Check the signing identity and bundle version before distributing the signed zip.

On iOS, generate the project with XcodeGen in `ios/`. Build and test the Cora scheme on an iPhone simulator. The iOS workflow captures localized screenshots, runs UI tests and packages signed development builds for registered devices. Verify pairing, session restoration and the changed screens on the distributed build. Record the tested build, server version and screenshots with release evidence.
