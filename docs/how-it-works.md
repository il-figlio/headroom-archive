# How Headroom works

The technical details behind each part of the panel. For what Headroom
reads and sends, see [PRIVACY.md](../PRIVACY.md).

## Memory

- **Kernel memory pressure** (`kern.memorystatus_vm_pressure_level`):
  Normal, Elevated, or Critical, plus dispatch-source events so brief
  pressure spikes are still recorded. Pressure is the primary health signal.
  It is never inferred from "RAM used".
- **Estimated memory used, swap, and compressed memory** from
  `host_statistics64` and `vm.swapusage`.
- **Per-app footprints** from the `proc_pid_rusage` physical footprint,
  grouped by parent chain and bundle path so helper processes count toward
  their app.
- **Guarded quit.** Quit sends a normal terminate request, so apps can ask
  you to save. Force Quit asks for confirmation first. Every request
  revalidates the process ID, bundle identity, and launch date, so a
  recycled process ID can never quit the wrong process. Finder and Headroom
  itself are protected. Nothing is ever quit automatically.
- **Favorites dock.** Pin apps from a row's ··· menu. A compact icon strip
  appears under the header: click to switch to a running app or launch it.
  Pins are stored in preferences.

## Disk

- **Free, purgeable, and total** capacity from a single volume-attribute
  read, sampled with memory history. No scanning is involved.
- **Trends:** a 24-hour free-space chart, the measured fill rate, and an
  estimate of days until full.
- **Consumer scan, on demand only.** A bounded set of roots (your home
  folder at depth one, `~/Library` one level deeper, and `/Applications`)
  is walked on a single thread at the lowest I/O priority
  (`IOPOL_THROTTLE`). The scan can be cancelled and its results are cached
  with per-location changes since the previous scan. It runs only when you
  open Trends and the cached results are more than a day old, or when you
  press **Rescan**. It never runs on a timer.
- **Non-destructive by design.** Rows offer *Reveal in Finder* and *Copy
  path*. There is no delete button. Headroom observes continuously,
  analyzes on demand, and never deletes.
- **Disk-full guard.** With less than about 512 MB free, history stops
  writing rather than add to the problem.

Consumer totals don't add up to physical usage: APFS snapshots, clones, and
shared allocations make that impossible, and Headroom doesn't claim
otherwise.

## Limits

Limits shows your Codex and Claude plan usage windows, the plan name,
credit balance where one exists, and reset times. On new installs Limits is
off until you turn it on. While it is off, Headroom reads no sign-ins, runs
no command-line tools, and makes no usage requests.

- **Codex** reads the sign-in that the Codex CLI stores in
  `~/.codex/auth.json` (read-only) and asks
  `chatgpt.com/backend-api/wham/usage` for the plan, rate-limit windows, and
  credits. An API-key-only sign-in has no plan limits to show.
- **Claude** uses Claude Code's sign-in: `~/.claude/.credentials.json` if
  that file exists, otherwise the `Claude Code-credentials` item in your
  login Keychain. Headroom also accepts Ante's original single-file sign-in,
  `~/.ante/auth/credentials/oauth/anthropic.json`. It asks
  `api.anthropic.com/api/oauth/usage` for the 5-hour window, the weekly
  window, and model-specific weekly windows (for example Sonnet or Opus)
  when Anthropic reports them.
- **Keychain without prompts.** Headroom checks that the Keychain item
  exists without reading it, and reads the token only to make the usage
  request. The read never shows a Keychain prompt: if macOS would need to
  ask you, it fails quietly and Limits says Claude usage is unavailable.
  **Use Claude Code's Keychain sign-in** in Settings → Limits (on by
  default) turns Keychain use off entirely.
- **Sign-in changes.** When Claude Code renews or replaces its sign-in,
  Headroom notices from the modification time of the file or Keychain item,
  without reading the secret, and tries again.
- **Named Claude accounts from Ante.** Separate rows for accounts such as
  Personal and Work need the Ante CLI installed at `~/.ante/bin/ante`, with
  named sign-ins in `~/.ante/auth/credentials/oauth/anthropic/`. Headroom
  lists those file names (it never opens the files) and runs
  `ante usage anthropic/<account> --json` for each, with a 20-second limit.
  Ante manages its own sign-ins. While any named Ante account exists, those
  accounts replace the Claude Code row, and Settings says so.
- **Read-only.** Headroom never refreshes, rotates, writes, or copies
  provider tokens. When a sign-in expires, Limits says so and the
  provider's own app or CLI (or Ante) renews it.
- **Polite polling.** About every 15 minutes and when you open the panel.
  `Retry-After` and HTTP 429 responses back a source off. A failed refresh
  keeps the last good reading, dimmed and labeled with when it was fetched.
  A window whose reset time has passed shows "Reset — updating". Collapsed,
  each account shows its most constrained window; expand it for the rest.
- **Nothing without a sign-in.** If no provider sign-in exists, nothing is
  fetched and the card stays hidden.

### Supported and not supported

| Tool | Supported | Why |
| --- | --- | --- |
| Codex (ChatGPT plan) | Yes | Reuses the Codex CLI's sign-in file |
| Claude (Claude Code) | Yes | Reuses Claude Code's sign-in file or Keychain item |
| Claude, named accounts | Yes, with the Ante CLI | Ante reads its own sign-ins and fetches the usage |
| Gemini, Cursor, Copilot, Windsurf, and others | No | Their usage would require browser cookies, a new sign-in, or refreshing and writing tokens, none of which Headroom does |

The usage endpoints Limits calls are the ones the providers' own apps use.
They are unofficial, undocumented, and can change or stop working without
notice. [PRIVACY.md](../PRIVACY.md#limits-off-until-you-turn-it-on) lists
every file Limits reads and every request it makes.

## Agents

Agents is off by default. Turn it on from the panel's widget menu. While it
is off, Headroom does no agent scanning at all.

- **What's running now.** The card leads with running sessions: the project,
  the agent, and the live memory footprint of each agent's process tree,
  then today's tokens and estimated spend. A process shared by several
  transcripts is counted once.
- **Provider-agnostic.** Headroom watches the folders coding agents keep
  their session transcripts in (`~/.claude`, `~/.codex`, `~/.openclaw`,
  `~/.devin`, and the folders used by Goose, opencode, Aider, Gemini,
  Cursor, Windsurf, Amp, Continue, and Codeium). Claude Code, Codex, and
  OpenClaw have dedicated readers; any other JSONL transcript goes through a
  generic reader.
- **Incremental.** Transcripts are append-only, so Headroom resumes each file
  at its last complete line and only reads new data, at most 2 MB per file
  per scan. A partially written line is read once it is complete. Offsets,
  file identities, sessions, and usage are saved together, so a replaced or
  restored transcript isn't counted twice. Sessions are rescanned about every
  45 seconds, or every 15 seconds while the panel is open.
- **Live health.** Transcripts are matched to running processes: `live`,
  `stuck` (process alive but transcript quiet for 10 minutes), `zombie`
  (file grew with no process), or `ended`.
- **Honest cost.** Tokens are priced per model from a versioned table. Models
  without a known price are counted in a separate *unpriced* bucket instead
  of being folded into a wrong-looking total.
- **Tool categories.** Raw tool names (`Bash`, `exec_command`,
  `send_message`, `mcp__*`) collapse into categories so usage compares
  across agents.
- **Read-only.** Transcripts are never modified, and Headroom writes nothing
  into agent folders.

## Placement

- **Notch** on Macs that have one (hover to peek, click to pin), **menu bar**
  otherwise. Choose Automatic, Menu bar, or Notch; a closed laptop lid falls
  back to the menu bar.
- The collapsed indicator shows memory only until disk gets tight: below 10%
  free a drive dot appears, and below 5% it turns red.
- Optional Launch at Login through `SMAppService`. No Accessibility or Screen
  Recording permission is needed. A duplicate-instance check keeps two
  copies from competing for the notch.

## History

- SQLite (the system library, in WAL mode) in
  `~/Library/Application Support/Headroom/`. One snapshot about every minute
  while recording, plus extra samples when pressure changes. Samples and
  events are kept for 30 days. Sleep and downtime gaps are excluded from
  trends.
- A `log.md` report (summary, daily readings, app footprints, disk
  consumers, recommendations, pressure transitions, and quit outcomes) is
  rewritten at most every 15 minutes, and immediately when you open it.
- Pause or resume recording, archive and restart the baseline, and open or
  reveal the data from the Trends window.

Recommendations are honest about uncertainty: footprint growth doesn't prove
a leak, and partial readings are labeled as partial.

## Where data lives

```
~/Library/Application Support/Headroom/
├── history.sqlite     # samples, events, disk consumers, agent sessions (WAL)
├── log.md             # generated report
├── quota-cache.json   # last Limits readings, for instant display on relaunch
└── archive-*/         # archived baselines you chose to keep
```

Preferences, including update settings, are stored in the
`org.headroom.app` defaults domain.

## Resource cost

Collapsed, Headroom reads a cheap kernel counter every 15 seconds and
listens for pressure events. Recording history adds one app scan and a
small database write about once a minute. With the panel open, readings
refresh every 2 seconds on a background queue. In short checks on one Mac,
Headroom used about 0.1% of one CPU core and a physical footprint of about
26 MB with history on. The consumer scan is the only folder walk in the
app, and it is throttled, cancellable, and on demand.

## Command line

Running the app's binary with a flag performs one task and exits, or opens
part of the UI at launch. These are useful for scripting and verification.

| Flag | What it does |
| --- | --- |
| `--diagnose` | Prints live memory and disk readings and grouped app footprints, then exits |
| `--capture` | Records one history sample and regenerates `log.md`, then exits |
| `--report` | Regenerates `log.md` from existing history, then exits |
| `--scan` | Runs the throttled consumer scan and prints the results, then exits |
| `--history-dir` | Prints the data folder path, then exits |
| `--show-panel` | Opens the panel right after launch |
| `--show-trends` | Opens the Trends window right after launch |
| `--screenshots [folder]` | Exports labeled screenshots with isolated demo data, without live monitoring |

For example:

```sh
/Applications/Headroom.app/Contents/MacOS/Headroom --diagnose
```
