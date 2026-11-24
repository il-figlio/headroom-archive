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

On new installs, Limits is off until you turn it on. While it is off,
Headroom reads no sign-ins, runs no command-line tools, and makes no usage
requests. When it is on, Headroom shows your Codex and Claude plan usage by
reusing sign-ins that are already on your Mac. It never asks for a
password, never creates a sign-in of its own, and never refreshes, rotates,
writes, or copies a provider's token.

Only Codex and Claude are supported. Gemini, Cursor, Copilot, Windsurf, and
other tools are not: showing their usage would mean reading browser
cookies, asking you to sign in again, or refreshing and writing tokens,
which Headroom doesn't do.

| Provider | What Headroom reads | Where it connects |
| --- | --- | --- |
| Codex (ChatGPT plan) | `~/.codex/auth.json`, written by the Codex CLI, opened read-only: the access token and account ID | `https://chatgpt.com/backend-api/wham/usage` |
| Claude (Claude Code sign-in, file) | `~/.claude/.credentials.json`, if it exists: the access token, its expiry, and the plan name | `https://api.anthropic.com/api/oauth/usage` |
| Claude (Claude Code sign-in, Keychain) | If that file doesn't exist, the `Claude Code-credentials` item in your login Keychain. Headroom checks that the item exists and when it last changed without reading its contents, and reads the token only to make the usage request. It never shows a Keychain prompt. Turn this off with **Use Claude Code's Keychain sign-in** in Settings → Limits (on by default) | `https://api.anthropic.com/api/oauth/usage` |
| Claude (Ante single sign-in) | `~/.ante/auth/credentials/oauth/anthropic.json`, Ante's original single-file sign-in, if it exists | `https://api.anthropic.com/api/oauth/usage` |
| Claude accounts in Ante (for example Personal and Work) | Requires the Ante CLI at `~/.ante/bin/ante`. Headroom lists only the **file names** in `~/.ante/auth/credentials/oauth/anthropic/`, which are the account names. The files themselves aren't opened | No direct connection. Headroom runs `~/.ante/bin/ante usage anthropic/<account> --json`, stops it after 20 seconds, and Ante fetches the usage itself |
| Claude Code version | Headroom runs `claude --version` from a standard install location (`~/.local/bin`, `~/.claude/local`, `/opt/homebrew/bin`, or `/usr/local/bin`), if one exists | None |

Details:

- Each request sends only your sign-in token (and, for Codex, your account
  ID) to the provider that issued it, to ask for your own usage. Nothing
  about your Mac or your other readings is included.
- The Codex request identifies itself as `Headroom`. To match what the
  Claude endpoint expects, the Claude request identifies itself with a
  Claude Code user agent, `claude-cli/<version> (external, cli)`, using the
  version from `claude --version` (or a recent default if Claude Code isn't
  found).
- The Keychain is never read in a way that can prompt you: if macOS would
  need to ask for permission, the read fails and Limits shows that Claude
  usage is unavailable. With **Use Claude Code's Keychain sign-in** turned
  off, Headroom doesn't touch the Keychain at all.
- When Claude Code's sign-in changes (for example, after Claude Code
  renews it), Headroom notices from the file's or Keychain item's
  modification time, without reading the secret, and tries again.
- While any named Ante account exists, Headroom shows those accounts and
  doesn't show Claude Code's own sign-in as a separate row. Settings →
  Limits says when this is the case.
- Tokens are held in memory only. They are never written to disk, logged,
  or cached by the network layer. Ante and the providers' own CLIs may
  renew their own sign-ins; Headroom never does.
- The latest readings (plan name, usage percentages, reset times, account
  names, and credit balance) are saved to `quota-cache.json` in Headroom's
  data folder so they show instantly after relaunch. No tokens are saved.
- Polling happens about every 15 minutes and when you open the panel, and
  stops while a provider asks Headroom to back off (rate limits are
  honored).
- If no sign-in exists, Headroom makes no Limits requests.

**These endpoints are unofficial.** They are the private, undocumented
endpoints the providers' own apps use, not public APIs. They can change or
stop working at any time without notice, and using them is subject to each
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
