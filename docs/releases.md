# Publishing Headroom

Headroom ships as a universal (Apple Silicon + Intel) app for macOS 13 or later, with Sparkle 2.10.0 embedded (pinned in Package.swift and Package.resolved). Releases and updates are public: anyone can download the DMG, and the app updates itself without a GitHub account or login.

## Where the values live

| File | Holds |
| --- | --- |
| `VERSION` | `MARKETING_VERSION` (CFBundleShortVersionString, tag `v<version>`) and `BUILD_NUMBER` (CFBundleVersion). Sparkle compares the build number, so it must increase with every published build. |
| `packaging/app.env` | App name, executable, bundle ID, minimum macOS, GitHub repo slug, feed URL, Sparkle public key and Keychain account, cask token, tap repo. |
| `Resources/Info.plist.in` | Info.plist template, rendered by `scripts/appconfig.py` during `scripts/build.sh`. |
| `Sources/HeadroomCore/UpdatePolicy.swift` | The feed URL and download allowlist compiled into the app. A Swift Testing check fails if they drift from `packaging/app.env`. |
| `packaging/homebrew/headroom.rb` | Homebrew cask template. |

To reuse this pipeline for another app, copy `VERSION`, `packaging/`, `Resources/Info.plist.in`, the `scripts/` release tools and `.github/workflows/`, then edit `packaging/app.env` and the `UpdatePolicy` constants.

## How updates reach users

- **Feed:** `SUFeedURL` is `https://raw.githubusercontent.com/il-figlio/headroom/main/appcast.xml`, the `appcast.xml` committed on `main`. Committing a new feed to `main` is what ships an update.
- **Archive:** each feed item encloses the public release asset `https://github.com/il-figlio/headroom/releases/download/v<version>/Headroom-<version>-universal.zip`. GitHub answers with a 302 redirect to a short-lived signed URL on `release-assets.githubusercontent.com` (older assets use `objects.githubusercontent.com`). Sparkle follows that redirect itself.
- **Trust:** `SURequireSignedFeed` requires the feed to carry Headroom's EdDSA signature, and Sparkle verifies the archive's EdDSA signature (`SUVerifyUpdateBeforeExtraction`) against `SUPublicEDKey` before it extracts anything. On top of that, `UpdatePolicy.allowsArchive` only accepts `https://github.com/il-figlio/headroom/releases/download/v<x.y.z>/<name>.zip`: no other host, repository, path, port, credentials, query or fragment. Sparkle has no delegate hook for redirects, so the storage host is listed in `UpdatePolicy.downloadRedirectHosts` for documentation and tests, not enforced. The signature is what makes the download safe.
- No token, cookie or Authorization header is ever sent. Remote release notes are not fetched: the notes are embedded in the signed feed.

**Why raw.githubusercontent.com and not GitHub Pages:** the installed pre-public builds have this exact URL compiled in (`SUFeedURL` and `feedURLString`). Moving the feed would strand them, as described in the transition section below. Raw files need no Pages site, deploy workflow or extra branch, and the feed is signed, so the CDN never has to be trusted. The cost is about 5 minutes of CDN caching after a push, and the feed is tied to the `main` branch name. Pages becomes worth it only with a custom domain. To switch, ship a build with the new `FEED_URL`, keep publishing to both URLs until older builds have updated, then stop updating the raw file.

## Cutting a release with CI (recommended)

1. Bump `VERSION` (for example `0.9.0` / `14`). Write `docs/releases/v<version>.md`: short paragraphs and `- ` bullet lists, which become the update notes shown in Sparkle. Open a PR and wait for CI to pass, then merge.
2. Tag the merged commit and push the tag: `git tag v0.9.0 && git push origin v0.9.0`.
3. `release.yml` runs:
   - **build** (no secrets, `contents: read`): checks the tag matches `VERSION` and that the notes exist, builds the universal app ad-hoc signed, runs `check.sh` and `test.sh`, then uploads the app as `app.zip`. Its SHA-256 goes to the next job as a job output.
   - **release** (environment `release`, the only job with secrets, `contents: write`):
     - Verifies the artifact's SHA-256 against the build job's output.
     - Imports the Developer ID certificate into a throwaway keychain.
     - Signs inside-out with hardened runtime through `scripts/sign.sh`.
     - Notarizes and staples the app.
     - Builds the ZIP and the DMG, then signs, notarizes and staples the DMG.
     - Signs the appcast, runs `release.py verify --distribution`, and creates a **draft** release with the ZIP, DMG, `SHA256SUMS` and `appcast.xml`.
     - Saves the rendered cask as a workflow artifact.
4. Review the draft (notes, assets, target tag), then publish it: `gh release edit v0.9.0 --draft=false --latest --repo il-figlio/headroom`.
5. Ship the update: `./scripts/release.py promote --from-release`. It downloads the release's `appcast.xml` and verifies the feed signature against the shipped public key. It checks that the item is for `VERSION`, and that the enclosure is publicly downloadable with the right length. Then it writes `appcast.xml`. Commit it byte-for-byte and push to `main`, directly or through a PR. Clients see the update once it lands, after the CDN cache expires.
6. Homebrew: copy `headroom.rb` from the workflow artifact (or run `./scripts/render-cask.py --sha256 <dmg sha>`) to `Casks/headroom.rb` in `il-figlio/homebrew-tap`.

**Why CI does not commit the appcast:** with `SUAutomaticallyUpdate` on, the feed commit installs the build on every user's Mac. Keeping that step manual gives a human gate after the release is public and before anyone is updated. It also means CI never holds a token that can push to `main`. Branch protection on `main` (required PR reviews or status checks) is therefore fully compatible. With required PRs, the appcast PR's merge is the ship button. If you later want CI to do it, use a separate `workflow_dispatch` job that opens a PR (needs "Allow GitHub Actions to create pull requests") rather than pushing to `main`. Never re-upload a published ZIP: its signature and length are in the feed. Bump the version instead.

## Cutting a release locally

```sh
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk   # Command Line Tools-only Macs
./scripts/check.sh && ./scripts/test.sh                                  # test.sh needs full Xcode
HEADROOM_SIGN_IDENTITY='Developer ID Application: <Name> (<TEAMID>)' ./scripts/build.sh
./scripts/sparkle-tools.sh
```

Notarization uses one of three paths, in this order:

- **API key:** export `HEADROOM_NOTARY_KEY=/path/AuthKey_XXXX.p8`, `HEADROOM_NOTARY_KEY_ID`, `HEADROOM_NOTARY_ISSUER`. `release.py package` notarizes and staples both the app and the DMG.
- **Keychain profile:** `release.py package --notary-profile NAME` does the same with a `notarytool store-credentials` profile.
- **Xcode account (no key needed):** `./scripts/notarize-xcode.py upload --team-id <TEAMID>`, then `export` once Apple is done, then `ditto dist/notarized/Headroom.app dist/Headroom.app`. `package` sees the stapled app. The DMG is signed but not notarized on this path, while the app inside it is stapled.

```sh
./scripts/release.py package
./scripts/release.py appcast            # signs with the Keychain key (account org.headroom.app)
./scripts/release.py verify --distribution
./scripts/release.py publish            # draft release via gh; add --legacy-bridge for 0.9.0 (below)
gh release edit v0.9.0 --draft=false --latest --repo il-figlio/headroom
./scripts/release.py promote            # then commit appcast.xml to main
./scripts/render-cask.py                # dist/releases/v0.9.0/headroom.rb for the tap
```

Outputs go to `dist/releases/v<version>/`: `Headroom-<version>-universal.zip` (Sparkle), `Headroom-<version>.dmg` (people; APFS/ULFO with an Applications link), `appcast.xml`, `SHA256SUMS`, `headroom.rb`.

`appcast` and `publish` refuse a signing key whose public half is not `SPARKLE_PUBLIC_ED_KEY`. Every feed and archive signature is re-checked with an independent Ed25519 verifier (`scripts/ed25519.py`). `promote` refuses a feed that does not verify, so a dry-run feed can never be promoted.

### Dry run (no secrets, no network)

```sh
HEADROOM_SIGN_IDENTITY=- ./scripts/build.sh     # ad-hoc; never touches Keychain or Application Support
./scripts/sparkle-tools.sh                       # one-time download of the pinned Sparkle tools
./scripts/release.py dry-run
```

This builds the ZIP and DMG and signs an appcast and the ZIP with a throwaway EdDSA key, then runs every check. It confirms the binary is universal, and that Info.plist matches `VERSION` and `app.env` in the app, the extracted ZIP and the DMG. It mounts the DMG read-only to check for `Headroom.app` and the `Applications → /Applications` link. It confirms the feed is well-formed and both signatures verify with the right enclosure URL and length, that `SHA256SUMS` matches, and that the rendered cask passes `ruby -c`. CI runs it on every push.

## Transition from the private builds (installed 0.8.0, build 13)

Builds up to 0.8.0 (13) used private updates. Their behavior:

- They poll the **same** feed URL, sending `Authorization: Bearer <gh token>`, which still works once the repository is public.
- They require a working `gh auth login` before the updater even starts.
- They accept **only** enclosures of the form `https://api.github.com/repos/il-figlio/headroom/releases/assets/<numeric id>`, downloaded with the gh token and `Accept: application/octet-stream`.
- They require a feed signed with the same EdDSA key, which is unchanged.

A feed that encloses the new public `github.com/.../releases/download/...` URL is **rejected** by these builds: "The update does not point to a Headroom release asset." So the first public release is a bridge release:

1. For **0.9.0 only**, set the repository variable `HEADROOM_LEGACY_BRIDGE=true` before pushing the tag. Locally, use `release.py publish --legacy-bridge`. After uploading the ZIP to the draft, `publish` looks up the asset's numeric ID and re-signs the feed so its enclosure is `https://api.github.com/repos/il-figlio/headroom/releases/assets/<id>`.
2. Publish the release and promote the feed as usual. Installed 0.8.0 builds with a gh login see build 14 and download it through the API URL they trust. The archive is still verified with the EdDSA key. They then relaunch as 0.9.0, which uses the public path from then on. New 0.9.0 installs see an item with their own build number and ignore it.
   - Make the repository public before promoting, so the anonymous download check in `promote` passes.
   - If the feed must ship while the repository is still private, run `promote --no-download-check`. The old builds download with their token either way.
3. Once every Mac you care about reports 0.9.0, delete `HEADROOM_LEGACY_BRIDGE`. From 0.9.1 on, the feed uses public download URLs.

**Manual fallback (one time per Mac):** a Mac that is still on 0.8.0 after 0.9.1 ships, or that lacks a gh login, cannot update itself. Quit Headroom, download `Headroom-<version>.dmg` from https://github.com/il-figlio/headroom/releases/latest, and drag Headroom to Applications, replacing the old copy. Settings and history in `~/Library/Application Support/Headroom` are kept. Every later update is automatic and needs no login.

## Secrets and variables (owner setup)

Create an environment named **`release`** under Settings → Environments. Add yourself as a required reviewer and restrict deployments to tags matching `v*`. Put the secrets there, not at repository level, so only the release job can read them. `gh secret set NAME --env release < file` reads a value from a file without echoing it.

| Name | Kind | What it is and how to export it |
| --- | --- | --- |
| `HEADROOM_DEVELOPER_ID_P12_BASE64` | env secret | The "Developer ID Application" certificate **with its private key**. In Keychain Access, open My Certificates, right-click the certificate, choose Export, and save a `.p12` with a strong password. Then run `base64 -i DeveloperID.p12 -o p12.txt && gh secret set HEADROOM_DEVELOPER_ID_P12_BASE64 --env release < p12.txt`. Delete both files afterwards. |
| `HEADROOM_DEVELOPER_ID_P12_PASSWORD` | env secret | The password chosen for that export. |
| `HEADROOM_NOTARY_KEY_P8` | env secret | Contents of an App Store Connect API key file. In App Store Connect, open Users and Access → Integrations → App Store Connect API → Team Keys and generate a key with the Developer role. `AuthKey_<KEYID>.p8` can be downloaded only once. Run `gh secret set HEADROOM_NOTARY_KEY_P8 --env release < AuthKey_<KEYID>.p8`. |
| `HEADROOM_NOTARY_KEY_ID` | env secret | That key's Key ID. |
| `HEADROOM_NOTARY_ISSUER` | env secret | The Issuer ID (UUID) shown above the key list. |
| `HEADROOM_SPARKLE_ED_KEY` | env secret | The existing Sparkle private key. Never generate a new one for this release stream. Run `.build-headroom/sparkle-tools/bin/generate_keys --account org.headroom.app -x sparkle-key.txt && gh secret set HEADROOM_SPARKLE_ED_KEY --env release < sparkle-key.txt && rm sparkle-key.txt`. The Keychain copy stays as the backup. CI pipes it to `sign_update --ed-key-file -`, so it is never written to disk. |
| `HEADROOM_SIGN_IDENTITY` | env or repo variable | The full identity name, for example `Developer ID Application: <Name> (<TEAMID>)` (`security find-identity -v -p codesigning`). |
| `HEADROOM_LEGACY_BRIDGE` | repo variable | `true` for the 0.9.0 bridge release only. Delete it afterwards. |

`GITHUB_TOKEN` creates the draft release. No personal token is needed. Leave the default workflow permissions read-only; the release job asks for `contents: write` itself. Locally, the same `HEADROOM_NOTARY_*` and `HEADROOM_SPARKLE_ED_KEY` (or `--ed-key-file`) variables work, and without them the scripts use the Keychain.

## CI details

- `ci.yml` runs on pull requests and on pushes to `main`. It builds the universal app ad-hoc signed and runs `check.sh` (Swift Testing), `test.sh` (XCTest) and the packaging dry run.
- The runner image (`macos-26`) and Xcode (`/Applications/Xcode_26.5.app`, chosen with `sudo xcode-select -s`) are pinned. Xcode 26.5 matches the local `MacOSX26.5.sdk`. Bump both together, and check the image's Xcode list in actions/runner-images first.
- Third-party actions are pinned by commit SHA: checkout v6.1.0, upload-artifact v7.0.2, download-artifact v8.0.2.
- Build and secret-holding steps run in separate jobs. Only the `release` job, gated by the `release` environment, sees secrets. It works on the exact bytes the secret-free job built and tested, verified by SHA-256. It deletes the throwaway keychain and key files when it finishes.

## Signing notes

- `scripts/sign.sh` signs Sparkle's nested code inside-out (Downloader.xpc, Installer.xpc, Autoupdate, Updater.app, the framework), then the app.
- With a Developer ID identity it signs with hardened runtime and secure timestamps. `HEADROOM_SIGN_KEYCHAIN` selects a specific keychain. `HEADROOM_SIGN_IDENTITY=-` signs ad-hoc.
- With no identity, it keeps the persistent self-signed "Headroom Local" identity for development builds.
- The Sparkle key is in the publisher's login Keychain under account `org.headroom.app`. Its public half is `SPARKLE_PUBLIC_ED_KEY` in `packaging/app.env`. Back it up outside the repository.
- No private key, certificate or GitHub credential is in the app or the repository.
