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

To reuse this pipeline for another app, copy `VERSION`, `packaging/`, `Resources/Info.plist.in` and the `scripts/` release tools, then edit `packaging/app.env` and the `UpdatePolicy` constants.

## How updates reach users

- **Feed:** `SUFeedURL` is `https://raw.githubusercontent.com/il-figlio/headroom/main/appcast.xml`, the `appcast.xml` committed on `main`. Committing a new feed to `main` is what ships an update.
- **Archive:** each feed item encloses the public release asset `https://github.com/il-figlio/headroom/releases/download/v<version>/Headroom-<version>-universal.zip`. GitHub answers with a 302 redirect to a short-lived signed URL on `release-assets.githubusercontent.com` (older assets use `objects.githubusercontent.com`). Sparkle follows that redirect itself.
- **Trust:** `SURequireSignedFeed` requires the feed to carry Headroom's EdDSA signature, and Sparkle verifies the archive's EdDSA signature (`SUVerifyUpdateBeforeExtraction`) against `SUPublicEDKey` before it extracts anything. On top of that, `UpdatePolicy.allowsArchive` only accepts `https://github.com/il-figlio/headroom/releases/download/v<x.y.z>/<name>.zip`: no other host, repository, path, port, credentials, query or fragment. Sparkle has no delegate hook for redirects, so the storage host is listed in `UpdatePolicy.downloadRedirectHosts` for documentation and tests, not enforced. The signature is what makes the download safe.
- No token, cookie or Authorization header is ever sent. Remote release notes are not fetched: the notes are embedded in the signed feed.

**Why raw.githubusercontent.com and not GitHub Pages:** the installed pre-public builds have this exact URL compiled in (`SUFeedURL` and `feedURLString`). Moving the feed would strand them, as described in the transition section below. Raw files need no Pages site, deploy workflow or extra branch, and the feed is signed, so the CDN never has to be trusted. The cost is about 5 minutes of CDN caching after a push, and the feed is tied to the `main` branch name. Pages becomes worth it only with a custom domain. To switch, ship a build with the new `FEED_URL`, keep publishing to both URLs until older builds have updated, then stop updating the raw file.

## Checks before anything lands

There is no hosted CI. Before pushing to `main` or tagging, run:

```sh
./scripts/verify.sh          # Swift Testing checks, XCTest when Xcode is installed, universal build, release dry run (~1 min)
./scripts/verify.sh --quick  # checks only (~5 s)
```

Every test runs every time, with no skips or retries; fix a flaky test instead of retrying it. Each step prints its wall time.

## Credentials (one-time owner setup)

Everything a release needs stays on the release Mac. Nothing is stored on GitHub.

| What | Where | How |
| --- | --- | --- |
| Developer ID Application certificate and private key | login Keychain | Create it at developer.apple.com (Certificates, +, Developer ID Application) from a certificate signing request, then import it. Back up the `.p12` in a password manager. |
| Notarization credentials | login Keychain, profile `NOTARY_PROFILE` from `packaging/app.env` (`headroom-notary`) | Generate an App Store Connect API key (Users and Access, Integrations, Team Keys, Developer role), then run `xcrun notarytool store-credentials headroom-notary --key AuthKey_<KEYID>.p8 --key-id <KEYID> --issuer <ISSUER-UUID>`. Delete the `.p8` afterwards or keep it in a password manager. |
| Sparkle EdDSA private key | login Keychain, account `org.headroom.app` | Generated 2026-11-24; the public half is `SPARKLE_PUBLIC_ED_KEY` in `packaging/app.env`. Back it up with `generate_keys --account org.headroom.app -x <file>` into a password manager. Losing it means installed copies can't verify updates. Never generate another one for this release stream. |
| Signing identity name | shell | `export HEADROOM_SIGN_IDENTITY='Developer ID Application: <Name> (<TEAMID>)'` (`security find-identity -v -p codesigning`). |

## Cutting a release

```sh
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk   # Command Line Tools-only Macs
# 1. Bump VERSION and write docs/releases/v<version>.md, then:
./scripts/verify.sh
HEADROOM_SIGN_IDENTITY='Developer ID Application: <Name> (<TEAMID>)' ./scripts/build.sh
./scripts/sparkle-tools.sh
```

Notarization uses one of three paths, in this order:

- **API key:** export `HEADROOM_NOTARY_KEY=/path/AuthKey_XXXX.p8`, `HEADROOM_NOTARY_KEY_ID`, `HEADROOM_NOTARY_ISSUER`. `release.py package` notarizes and staples both the app and the DMG.
- **Keychain profile (default):** `release.py package` uses the profile named by `NOTARY_PROFILE` in `packaging/app.env`; `--notary-profile NAME` picks another.
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

This builds the ZIP and DMG and signs an appcast and the ZIP with a throwaway EdDSA key, then runs every check. It confirms the binary is universal, and that Info.plist matches `VERSION` and `app.env` in the app, the extracted ZIP and the DMG. It mounts the DMG read-only to check for `Headroom.app` and the `Applications → /Applications` link. It confirms the feed is well-formed and both signatures verify with the right enclosure URL and length, that `SHA256SUMS` matches, and that the rendered cask passes `ruby -c`. `verify.sh` runs it.

## Transition from the private builds (installed 0.8.0, build 13)

Builds up to 0.8.0 (13) used private updates. Their behavior:

- They poll the **same** feed URL, sending `Authorization: Bearer <gh token>`, which still works once the repository is public.
- They require a working `gh auth login` before the updater even starts.
- They accept **only** enclosures of the form `https://api.github.com/repos/il-figlio/headroom/releases/assets/<numeric id>`, downloaded with the gh token and `Accept: application/octet-stream`.
- They require a feed signed with the EdDSA key they shipped with. **That key was rotated on 2026-11-24** (the original private key wasn't available), so these builds can't verify any public release. The bridge below is kept for reference only.

**Current guidance:** Macs running 0.8.0 or earlier install 0.9.0 once by hand from the DMG. Don't set `HEADROOM_LEGACY_BRIDGE`.

A feed that encloses the new public `github.com/.../releases/download/...` URL is **rejected** by these builds: "The update does not point to a Headroom release asset." So the first public release is a bridge release:

1. For **0.9.0 only**, set the repository variable `HEADROOM_LEGACY_BRIDGE=true` before pushing the tag. Locally, use `release.py publish --legacy-bridge`. After uploading the ZIP to the draft, `publish` looks up the asset's numeric ID and re-signs the feed so its enclosure is `https://api.github.com/repos/il-figlio/headroom/releases/assets/<id>`.
2. Publish the release and promote the feed as usual. Installed 0.8.0 builds with a gh login see build 14 and download it through the API URL they trust. The archive is still verified with the EdDSA key. They then relaunch as 0.9.0, which uses the public path from then on. New 0.9.0 installs see an item with their own build number and ignore it.
   - Make the repository public before promoting, so the anonymous download check in `promote` passes.
   - If the feed must ship while the repository is still private, run `promote --no-download-check`. The old builds download with their token either way.
3. Once every Mac you care about reports 0.9.0, delete `HEADROOM_LEGACY_BRIDGE`. From 0.9.1 on, the feed uses public download URLs.

**Manual fallback (one time per Mac):** a Mac that is still on 0.8.0 after 0.9.1 ships, or that lacks a gh login, cannot update itself. Quit Headroom, download `Headroom-<version>.dmg` from https://github.com/il-figlio/headroom/releases/latest, and drag Headroom to Applications, replacing the old copy. Settings and history in `~/Library/Application Support/Headroom` are kept. Every later update is automatic and needs no login.

## Signing notes

- `scripts/sign.sh` signs Sparkle's nested code inside-out (Downloader.xpc, Installer.xpc, Autoupdate, Updater.app, the framework), then the app.
- With a Developer ID identity it signs with hardened runtime and secure timestamps. `HEADROOM_SIGN_KEYCHAIN` selects a specific keychain. `HEADROOM_SIGN_IDENTITY=-` signs ad-hoc.
- With no identity, it keeps the persistent self-signed "Headroom Local" identity for development builds.
- The Sparkle key is in the publisher's login Keychain under account `org.headroom.app`. Its public half is `SPARKLE_PUBLIC_ED_KEY` in `packaging/app.env`. Back it up outside the repository.
- No private key, certificate or GitHub credential is in the app or the repository.
