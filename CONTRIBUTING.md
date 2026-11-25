# Contributing to Headroom

By taking part you agree to the [code of conduct](CODE_OF_CONDUCT.md).

Thanks for taking a look. Headroom aims to stay small, honest, and cheap to
run, so changes are welcome when they keep it that way. For a larger change,
please open an issue first so we can agree on the approach.

## Project layout

```
Sources/
├── Headroom/          App layer: AppDelegate, Monitor, PanelView, NotchController, HistoryView
├── HeadroomCore/      Testable logic: memory, disk, history, agents, quotas (no AppKit UI)
├── CMemory/           C shim over kernel counters (host_statistics64, proc_pid_rusage, IOPOL)
└── CSQLite/           Module map exposing the system libsqlite3

Tests/HeadroomCoreTests/   XCTest suite for the core target (needs full Xcode)
Tests/HeadroomCoreChecks/  Swift Testing checks (run without Xcode via scripts/check.sh)
scripts/                   Build, sign, test, screenshot, and release scripts
docs/                      Screenshots and longer documentation
```

Anything testable goes in `HeadroomCore`. AppKit and SwiftUI wiring stays
in `Headroom`.

## Build

Requirements: macOS 13 or later and Swift 5.9 or later, from Xcode or the
Command Line Tools.

```sh
./scripts/build.sh    # universal release build → dist/Headroom.app
open dist/Headroom.app
```

Quit any running copy of Headroom before launching a new build.

Source builds are signed with a persistent self-signed identity,
"Headroom Local", so macOS remembers Keychain permission across rebuilds.
`scripts/sign.sh` creates it on the first build in its own keychain under
`~/Library/Application Support/Headroom/signing/`. It never touches your
login keychain. Distribution builds use Developer ID signing instead; see
[docs/releases.md](docs/releases.md).

### Command Line Tools only

On a Mac with only the Command Line Tools, the newest default SDK can fail
to build SwiftUI macros. If the build fails with macro errors, point
`SDKROOT` at an older SDK that the Command Line Tools also install:

```sh
ls /Library/Developer/CommandLineTools/SDKs/
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ./scripts/check.sh
```

Use whichever older SDK version you have.

## Test

| Command | What it runs | Needs |
| --- | --- | --- |
| `./scripts/verify.sh` | Everything below plus a universal build and a release dry run, with timings. Run before every push. | Command Line Tools or Xcode |
| `./scripts/check.sh` | Swift Testing checks in `Tests/HeadroomCoreChecks` | Command Line Tools or Xcode |
| `./scripts/test.sh` | The full `swift test` suite, including the XCTest tests | Full Xcode |
| `./scripts/test-quit.sh` | Builds a disposable fixture app and checks Quit and Force Quit against it | Command Line Tools or Xcode |

Run `verify.sh` before every push (`--quick` runs only the checks). There's no hosted CI, so this is the gate.
`test-quit.sh` refuses to quit anything whose bundle ID isn't its dedicated
fixture. Keep it that way.

Helpful checks against a built app:

```sh
dist/Headroom.app/Contents/MacOS/Headroom --diagnose      # live readings to stdout
dist/Headroom.app/Contents/MacOS/Headroom --capture       # one sample + regenerate log.md
dist/Headroom.app/Contents/MacOS/Headroom --scan          # run the consumer scan in the terminal
dist/Headroom.app/Contents/MacOS/Headroom --show-panel    # open the panel at launch
dist/Headroom.app/Contents/MacOS/Headroom --show-trends   # open the Trends window at launch
```

`./scripts/screenshots.sh` rebuilds the app (signed ad hoc, so no keychain
is involved) and regenerates the README screenshots from the real views with
demo data. Add `--screenshot-variants` for review-only renders of the bare
panels, light mode, settings, and hover details.

## Invariants

These properties are what make Headroom trustworthy. Pull requests that
break them won't be merged.

1. **Never deletes user files.** No cleanup or "optimize" buttons. Sparkle
   may replace Headroom's own app bundle during an update.
2. **Never quits other apps automatically.** Quit is always user-initiated,
   and Force Quit always asks first. Sparkle may quit and relaunch Headroom
   to install an update.
3. **No full-tree scans on a timer.** Capacity comes from volume attributes
   only. Folder walks are on demand, cancellable, single-threaded, and run
   at `IOPOL_THROTTLE`.
4. **Local by default.** No telemetry, analytics, or external AI calls.
   Network access is limited to Limits requests that reuse the user's
   existing sign-ins and to Sparkle update checks and downloads. Don't add
   dependencies beyond the pinned Sparkle.
5. **Credentials are read-only.** Never refresh, rotate, or write a
   provider's credentials, never persist tokens, and never trigger an
   interactive Keychain prompt.
6. **Optional features stay off until enabled.** Agents does no scanning
   while it's off, and Limits makes no requests while it's off.
7. **No privileged helper.** No root, and no Accessibility, Screen
   Recording, or Full Disk Access requirement.
8. **Honest readings.** Never infer memory pressure from a RAM percentage.
   Label partial or incomplete readings. Don't add consumer sizes up into
   claims about physical disk usage.
9. **Process safety.** Anything that targets a process must revalidate the
   process ID, bundle path, and launch date. Never act on a stale row.

If a change affects what Headroom reads, stores, or sends, update
[PRIVACY.md](PRIVACY.md) in the same pull request.

## Style

- Swift 5.9+, macOS 13+. Match the surrounding style: compact code, with
  comments only where the reason isn't obvious.
- Do process and file enumeration on the utility queue. Use the main thread
  for view updates only.
- Schema changes need a migration. See `History.swift` (`user_version`,
  `ALTER TABLE`) and test against a real, populated database.
- App icons are cached and `NSWorkspace.runningApplications` is read off the
  main thread. Keep it that way.
- Add tests to `Tests/HeadroomCoreChecks` (Swift Testing) or
  `Tests/HeadroomCoreTests` for anything in the core target. Prefer fakes
  and in-memory stores over timing-dependent tests.
- Add a line under **Unreleased** in [CHANGELOG.md](CHANGELOG.md) for
  user-visible changes.

## Good first issues

- Normalize the per-sample `apps` JSON into its own table if history size
  becomes meaningful.
- Store only the top N apps per sample.
- More consumer-scan roots, such as `/opt` or `/private/var/folders`.
- Menu bar mode screenshots and checks on a Mac without a notch.

## License

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE).
