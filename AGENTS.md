# AGENTS.md

Notes for coding agents working in this repository. Humans: see [README.md](README.md).

## Signing the macOS companion (Developer ID and notarisation)

The developer has a paid Apple Developer Program membership (team `A2WT9CD8P3`). This Mac's login
keychain holds what's needed, set up once on 2026-10-26 for Nowhere in Particular and shared by every app:

- **The certificate:** `Developer ID Application: Michal Jaskolski (A2WT9CD8P3)`, for apps distributed
  outside the App Store. Check with `security find-identity -v -p codesigning`. Don't use the
  `Apple Development` identity: it only signs builds for the developer's own devices.
- **The notary credentials:** the notarytool keychain profile **`nip`** (Apple ID, team id and an
  app-specific password). It belongs to the team, not to an app, so use it for this repository's apps too.
  Check with `xcrun notarytool history --keychain-profile nip`.
  **If it says "No Keychain password item found"** (the profile vanished from the login keychain on
  2026-10-27, when the keychain file was rewritten at 20:18 with its other items kept; the cause wasn't
  found): the developer stores it again, interactively (it asks for an app-specific password, made at
  account.apple.com › Sign-In and Security › App-Specific Passwords if the old one is lost):
  `xcrun notarytool store-credentials nip --apple-id <Apple ID> --team-id A2WT9CD8P3`. In the login
  keychain, as before: no keychain of its own.

`companion/mac/build.sh` signs ad hoc; `sign.sh` then signs with the Developer ID and notarises the
app, and `package.sh` signs and notarises the DMG when the app inside is Developer ID signed (settings
in `signing.sh`: the `nip` profile locally, an App Store Connect API key in CI). A signed and notarised
build opens with a double-click, with no "damaged" message and no `xattr -dr com.apple.quarantine`.
What the scripts do, step by step:

1. **Sign inside out:** first any nested code (dylibs, frameworks, helpers), then the bundle. Use the
   hardened runtime and a secure timestamp, which notarisation requires. Never sign with `--deep`;
   Apple advises against it.
   ```sh
   ID="Developer ID Application: Michal Jaskolski (A2WT9CD8P3)"
   codesign --force --timestamp --options runtime -s "$ID" build/AirlockCompanion.app
   codesign --verify --strict --deep build/AirlockCompanion.app
   ```
   - **Entitlements:** add `--entitlements file.plist` only for what the app needs under the hardened
     runtime. Bonjour and the network need none outside the App Sandbox.
   - **Bundle contents:** only Mach-O code may sit in `Contents/MacOS` and `Contents/Frameworks`. A text
     or config file there fails the strict check with "code object is not signed at all". Put such files
     in `Contents/Resources`.
   - **Extended attributes:** run `xattr -cr` on the bundle first. Finder info or quarantine
     attributes make codesign refuse it.
2. **Build the DMG** (`package.sh`), then sign the DMG itself:
   `codesign --force --timestamp -s "$ID" build/AirlockCompanion-<v>.dmg`.
3. **Notarise and staple.** Apple's service takes 1-3 minutes. Submitting the DMG covers the app inside
   it.
   ```sh
   xcrun notarytool submit build/AirlockCompanion-<v>.dmg --keychain-profile nip --wait
   xcrun stapler staple build/AirlockCompanion-<v>.dmg
   spctl --assess --type open --context context:primary-signature -vv build/AirlockCompanion-<v>.dmg
   ```
   - **The checks:** `spctl` should say `source=Notarized Developer ID`. For the app:
     `spctl --assess --type execute -vv <app>`.
   - **If it's rejected:** `xcrun notarytool log <submission id> --keychain-profile nip` says why.
   - **A copy dragged out of the DMG:** to have that copy carry its ticket offline too, notarise and
     staple the .app before building the DMG. Zip it (`ditto -c -k --keepParent`), submit the zip,
     staple the .app, then build the DMG.
4. **Sign last:** anything changed inside the bundle after signing (Info.plist, a resource) breaks the
   signature.

A working reference for both steps is in Nowhere in Particular:
- `../nowhereinparticular/scripts/sign-macos.sh` signs the nested code and the app, then notarises
  and staples;
- `../nowhereinparticular/scripts/make-dmg.sh` builds the DMG with the Applications link, then signs,
  notarises and staples it.

**CI can't use this keychain.** The release workflow's `companion-mac` job runs on GitHub's `macos-14`
runner, which can't reach it. Signing there needs:
- the certificate exported as a `.p12`, imported into a temporary keychain on the runner;
- notarytool with an App Store Connect API key (`--key`, `--key-id`, `--issuer`) instead of the
  profile.

Both would go in as repository secrets. The simpler way is to build the release DMG on this Mac and
upload it to the release.
