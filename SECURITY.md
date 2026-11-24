# Security policy

## Supported versions

Only the latest release receives security fixes. Headroom updates itself,
so the fix reaches you through the normal update check. If you turned off
automatic checks, use **Check for Updates** or download the
[latest release](https://github.com/il-figlio/headroom/releases/latest).

## Reporting a vulnerability

Please report security problems privately, not in a public issue.

1. Open the repository's
   [Security tab](https://github.com/il-figlio/headroom/security) and choose
   **Report a vulnerability**. This opens a private advisory that only the
   maintainers can see.
2. Describe the problem, the Headroom version, your macOS version, and the
   steps to reproduce it. A proof of concept helps but isn't required.

We aim to acknowledge reports within a week. Once a fix is released, the
advisory is published with credit to you, unless you prefer to stay
anonymous.

## Scope

Examples of what we want to hear about:

- Anything that lets the update process install code that isn't a signed
  Headroom release.
- Provider sign-in tokens being written to disk, logged, or sent anywhere
  other than the provider that issued them.
- Headroom quitting a process you didn't choose, or deleting or modifying
  any file outside its own data folder.
- Agent transcripts or other local data leaving your Mac.

Problems in the provider services that Limits reads from, or in Sparkle
itself, should go to those projects. We're still glad to hear about them if
they affect Headroom.
