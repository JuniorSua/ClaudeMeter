# ClaudeMeter

A native, local-first macOS menu bar app that shows your Claude usage at a glance
— the same session and weekly percentages as Claude Code's `/usage`, plus a
detailed breakdown of your local Claude Code token usage.

<!-- Add a screenshot here, e.g. docs/screenshot.png -->

## Features

- **Menu bar:** two tiny stacked percentages — **session** on top, **weekly**
  below — so it stays narrow and leaves room for your other menu bar apps.
- **Click for detail:** a native popover with your official account usage
  (Session, Weekly · All Models, and per-model weekly limits like Fable, with an
  "active limit" badge and reset countdowns), plus today's and this week's local
  token totals and an estimated cost.
- **Official account usage:** reads your existing Claude Code login from the
  macOS Keychain and queries Anthropic's usage endpoint — the exact numbers
  Claude Code shows. Follows [`claude-switch`](https://github.com/) profiles: the
  active account is the one displayed.
- **Local-first & private:** reads `~/.claude` for **metadata only** (token
  counts, model, timestamps). No prompt/completion text is ever stored, no
  telemetry, nothing is uploaded. See [SECURITY.md](SECURITY.md).
- **Lightweight & native:** Swift + AppKit/SwiftUI, no Dock icon, no third-party
  menu bar wrapper, no runtime dependencies.

## Requirements

- macOS 13 (Ventura) or newer
- Swift toolchain (Xcode or Command Line Tools — `xcode-select --install`)

## Build & run

No Xcode project required — it builds with Swift Package Manager and assembles a
double-clickable `.app`:

```bash
./scripts/build-app.sh        # swift build -c release → build/ClaudeMeter.app
open build/ClaudeMeter.app     # menu bar only, no Dock icon
```

On first launch, macOS asks to let ClaudeMeter read your Claude Code login from
the Keychain — click **Always Allow**. To keep it around, drag
`build/ClaudeMeter.app` into `/Applications` and enable "Launch at login" in
Settings.

Run the tests with:

```bash
./scripts/test.sh
```

## How it works

- Reads official usage (session / weekly / per-model) from Anthropic's usage
  endpoint using your Keychain login, at most once every couple of minutes
  (throttled and cached so it never hits rate limits or blanks out).
- Scans `~/.claude/**/*.jsonl` incrementally (per-file byte offsets, `uuid`-based
  dedup) for local token/cost metadata, aggregated by session window / local day
  / configurable week.
- Refreshes on file changes (debounced) plus a timer, and persists the last good
  numbers so they show instantly on launch.

## Privacy

ClaudeMeter is local-first. It stores only usage **metadata** and never prompt or
completion text; the only network call is the read-only, authenticated usage
request described above, which can be turned off in Settings. Full details in
[SECURITY.md](SECURITY.md).

> Note: the local token totals reflect Claude Code activity on this Mac only.
> Usage from the web, desktop, or other devices isn't included in those totals
> (the official session/weekly percentages are account-wide).

## License

[MIT](LICENSE)
