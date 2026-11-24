# Privacy

Headroom is a local utility. It has no account, no analytics, no crash
reporting, and no telemetry. It doesn't send your readings, app list, file
names, or history anywhere. Network access is limited to the two features
described below: **Limits**, if you turn it on, and **update checks**.

This page lists everything Headroom reads, stores, and sends.

## What stays on your Mac

**Memory, apps, and disk.** Headroom reads kernel memory counters, the list
of running apps with each app's memory footprint, and your startup volume's
free, purgeable, and total space. These readings come from standard macOS
system calls and need no special permission.

**History.** While recording is on (the default), Headroom saves about one
snapshot a minute to a SQLite database in
`~/Library/Application Support/Headroom/`. A snapshot contains memory and
disk figures and the names and memory footprints of running apps. Events
such as pressure changes and the results of Quit requests you made are
stored too. Samples and events older than **30 days** are deleted
automatically. Headroom also writes a readable report, `log.md`, to the same
folder. Archives you create from the Trends window stay until you delete
them. You can pause recording from the Trends window.

**Disk consumer scan.** When you open Trends and the cached results are more
than a day old, or when you press **Rescan**, Headroom measures the size of a
fixed set of folders: the items in your home folder, the items in
`~/Library`, and `/Applications`. It stores each folder's path and size in
the history database. It runs at the lowest disk priority, can be
cancelled, and never runs on a timer. Headroom doesn't open or read your
files' contents.

**Preferences.** Settings such as placement, launch at login, pinned
favorites, visible widgets, and update preferences are stored in the
`org.headroom.app` preferences domain.

## Agents (off by default)

When you turn on the Agents widget, Headroom looks for coding-agent session
transcripts in the folders those tools use, such as `~/.claude`, `~/.codex`,
`~/.openclaw`, `~/.devin`, `~/.gemini`, `~/.cursor`, `~/.codeium`, and
folders under `~/.config` for Goose, opencode, Amp, and Continue.

- Transcripts are opened **read-only**. Headroom never modifies them and
  writes nothing into agent folders.
- Each new line is parsed in memory. Headroom keeps only **metadata**: the
  session ID, the project folder the agent ran in, timestamps, model names,
  token counts, and how many times each tool was used. Message text, prompts,
  code, and tool output are not stored.
- To tell which sessions are still running, Headroom reads the process list
  with `/usr/bin/ps`, which includes each process's command line. It is used
  in memory to match agents to their transcripts and isn't stored.
- Session metadata, the transcript file paths, and hourly token totals are
  stored in the local history database. Hourly totals are kept for 30 days.

While Agents is off, none of this happens.

## Limits (off until you turn it on)

On new installs, Limits is off until you turn it on. When it is on, Headroom
shows your coding-plan usage by reusing sign-ins that are already on your
Mac. It never asks for a password and never creates a sign-in of its own.

| Provider | What Headroom reads | Where it connects |
| --- | --- | --- |
| Codex (ChatGPT plan) | `~/.codex/auth.json`, written by the Codex CLI: the access token and account ID | `https://chatgpt.com/backend-api/wham/usage` |
| Claude | `~/.claude/.credentials.json` (Claude Code) or `~/.ante/auth/credentials/oauth/anthropic.json` (Ante). If neither has a usable sign-in, the `Claude Code-credentials` item in your login Keychain | `https://api.anthropic.com/api/oauth/usage` |
| Claude accounts in Ante | Only the **file names** in `~/.ante/auth/credentials/oauth/anthropic/`, which are the account names. The files themselves aren't opened | No direct connection. Headroom runs `~/.ante/bin/ante usage anthropic/<account> --json` and Ante fetches the usage itself |

Details:

- Each request sends only your sign-in token (and, for Codex, your account
  ID) to the provider that issued it, to ask for your own usage. Nothing
  about your Mac or your other readings is included.
- To match what the Claude endpoint expects, Headroom runs
  `claude --version` from a standard install location, if one exists, and
  sends that version in the request's user agent.
- The Keychain read is non-interactive: if macOS would need to ask you for
  permission, the read fails and Limits shows that usage is unavailable.
  Headroom never shows a Keychain prompt for Limits.
- Tokens are held in memory only. They are never written to disk, logged,
  or cached by the network layer. Headroom never refreshes, rotates, or
  writes provider credentials.
- The latest readings (plan name, usage percentages, reset times, account
  names, and credit balance) are saved to `quota-cache.json` in Headroom's
  data folder so they show instantly after relaunch. No tokens are saved.
- Polling happens about every 15 minutes and when you open the panel, and
  stops while a provider asks Headroom to back off.
- If no sign-in files exist, Headroom makes no Limits requests.

**These endpoints are unofficial.** They are the private endpoints the
providers' own apps use. They are not documented public APIs, they can
change or stop working at any time, and using them is subject to each
provider's terms. If one changes, Limits shows an error for that provider;
nothing else is affected.

## Update checks

Headroom uses [Sparkle](https://sparkle-project.org) for updates. By
default it checks once a day. You can turn off automatic checks and
automatic installation in Headroom's settings, and still check manually.

- An update check downloads Headroom's update feed (`appcast.xml`) from
  GitHub. If a newer version is listed, Headroom downloads the update
  archive from the project's GitHub Releases.
- These are ordinary HTTPS requests. GitHub can see your IP address and a
  user agent that names Headroom and its version, as with any download.
- Sparkle's optional system profile is disabled, so no hardware, macOS
  version, or usage details are sent.
- The feed and the update archive are both signed. Headroom refuses an
  update whose signature doesn't match the key built into the app, and
  checks the signature before unpacking.
- Release notes are embedded in the signed feed; Headroom doesn't load them
  from another site.

## Permissions

Headroom needs no Accessibility, Screen Recording, Full Disk Access, or
administrator permission. It doesn't install a helper and doesn't run as
root.

## Removing your data

Quit Headroom, then delete `~/Library/Application Support/Headroom/` and run
`defaults delete org.headroom.app`. See
[Uninstall](README.md#uninstall) for the full steps.

## Questions

Open an issue on GitHub. To report a security problem, follow
[SECURITY.md](SECURITY.md).
