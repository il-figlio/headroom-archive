## What and why

<!-- What does this change, and why? Link the issue if there is one. -->

## How it was tested

<!-- Commands you ran, and what you checked by hand (notch, menu bar, light/dark). -->

## Checklist

- [ ] `./scripts/verify.sh` passes (or `--quick` for docs-only changes)
- [ ] `./scripts/test-quit.sh` passes (if Quit or process handling changed)
- [ ] `./scripts/build.sh` produces a working `dist/Headroom.app`
- [ ] `--diagnose` and `--capture` still work on a real, populated history database (migrations included)
- [ ] Panel and notch sizing still fit (`PanelMetrics`) if the UI changed
- [ ] CHANGELOG.md has a line under **Unreleased** for user-visible changes
- [ ] PRIVACY.md is updated if this changes what Headroom reads, stores, or sends

## Invariants

This change keeps all of these (see CONTRIBUTING.md):

- [ ] Never deletes user files
- [ ] Never quits apps automatically; Force Quit still asks first
- [ ] No folder scans on a timer
- [ ] No telemetry, no new network destinations, no new dependencies
- [ ] Provider credentials stay read-only, no tokens persisted, no Keychain prompts
- [ ] Agents and Limits do nothing while they're turned off
- [ ] No privileged helper or extra permission requirements
- [ ] Readings stay honest: pressure from the kernel, partial readings labeled
- [ ] Process targeting revalidates PID, bundle path, and launch date
