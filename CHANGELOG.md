# Changelog

All notable changes to Headroom are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Headroom uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Versions before
the first public release were private builds and were never published for
download.

## [Unreleased]

### Added
- A short welcome on first launch explaining what Headroom measures, where
  it lives, and the optional features, plus a Settings window (⌘,) and an
  About panel.
- Public updates: Headroom checks a public, signed update feed and no longer
  needs a GitHub login. Downloads come as a notarized DMG or ZIP.
- Hover details across the panel: rest on any row, meter, or tile to see
  exactly what it measures.
- Named Claude accounts from Ante: each signed-in account gets its own row
  in Limits, read through the `ante usage` command.
- Codex sessions stored in dated folders are now picked up by Agents.

### Changed
- Disks of 1 TB or more show sizes in TB (for example "1.26 TB free of
  2.00 TB") in the panel, menu bar, Trends, and log.md.
- Limits is opt-in on new installs. While it's off, Headroom reads no
  sign-ins, runs no provider CLI, and makes no usage requests. Existing
  installs keep their current setting.
- New app icon: a white gauge on a black tile with its needle near the low
  end.
- Limits is clearer: the most constrained window is shown first, values are
  labeled "% used", and a reading that couldn't be refreshed is dimmed and
  labeled with when it was fetched.
- Agents is off by default. Turn it on from the panel's widget menu. While
  it's off, Headroom does no agent scanning.
- The Agents card is built around what's running now: project, agent, and
  the live memory of each agent's processes, then today's tokens and
  estimated spend.
- Limits never refreshes or writes provider credentials and never asks for
  Keychain permission. When a sign-in expires, the provider's own app or CLI
  renews it.
- Faster and lighter: memory and disk readings appear before slower history
  and agent work, quiet agent rescans and history writes are several times
  faster, and the `log.md` report is rewritten at most every 15 minutes (or
  when you open it) instead of every minute.

### Fixed
- Token counts from agent transcripts are accurate when a line is still
  being written, a read fails, or the file grows during a read. Previously
  such lines could be skipped or counted twice.
- A replaced or restored transcript is no longer counted twice.
- A failed Ante usage read no longer blanks the account, a hung Ante process
  is stopped after its timeout, and the last good reading survives a failed
  fetch at launch.

## [0.8.0] - 2026-10-15

### Added
- In-app updates with [Sparkle](https://sparkle-project.org): check,
  download, verify, install, and relaunch. Automatic checks and automatic
  installation can each be turned off.
- Universal app for Apple Silicon and Intel, Developer ID signed and
  notarized by Apple.

## [0.7.2] - 2026-10-15

### Added
- The app icon now appears in the menu bar, the collapsed notch, and the
  panel header; the installed version is shown under the panel title.
- **Check for Updates** command.

## [0.7.1] - 2026-10-15

### Added
- First app icon.
- Repository screenshots rendered from the real app views with clearly
  labeled demo data.

## [0.7.0] - 2026-10-14

### Added
- **Limits** card: your Codex and Claude plan usage windows, credit
  balance, plan name, and reset times, read with your existing sign-ins.
  Polled about every 15 minutes, with rate limits respected and the last
  good reading kept on failure.

### Fixed
- Limits rows no longer truncate; the collapsed notch title no longer clips.

## [0.6.1] - 2026-10-14

### Changed
- Gauges replaced by compact bars with a highlighted warning zone. Memory
  and Disk sit side by side.
- The Agents card shows an honest idle state instead of "0 active".

## [0.6.0] - 2026-10-14

### Added
- Customizable panel: show or hide any card from **··· → Widgets** or by
  right-clicking it. The app list always keeps a minimum height.

## [0.5.0] - 2026-10-14

### Added
- Sparklines for memory and disk, an hourly token chart on the Agents card,
  and a proportional memory bar on each app row.

## [0.4.0] - 2026-10-14

### Added
- **Agents**: tracks coding-agent sessions (Claude Code, Codex, OpenClaw,
  and a generic reader for other JSONL transcripts) with tokens, estimated
  cost, and live/stuck/ended health.
- **Favorites dock**: pin apps for one-click switching or launching.

## [0.3.0] - 2026-10-14

### Added
- Disk tracking: free, purgeable, and total space, a 24-hour chart, fill rate,
  and an estimate of days until full.
- On-demand, throttled scan of the largest disk consumers, with Reveal in
  Finder and Copy Path. Headroom never deletes anything.
- History stops writing when less than about 512 MB is free.

### Fixed
- History recording no longer uses a stale memory-pressure reading.

## [0.2.0] - 2026-10-14

### Added
- Local history (30 days), a Trends window with 24-hour charts and
  rules-based recommendations, recording controls, and archiving.
- A generated `log.md` report of daily readings and recent actions.

## [0.1.0] - 2026-10-14

First prototype.

### Added
- Memory pressure in the notch on laptops and the menu bar on other Macs.
- Per-app memory with helper processes grouped under their app.
- Guarded **Quit** and confirmed **Force Quit**.
