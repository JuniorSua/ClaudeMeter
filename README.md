# ClaudeMeter

A native, local-first macOS menu bar app that shows your Claude usage at a glance
— the same session and weekly percentages as Claude Code's `/usage`, plus charts
of your local Claude Code token usage and one-click account profile switching.

<!-- Add a screenshot here, e.g. docs/screenshot.png -->

## Features

- **Menu bar:** two tiny stacked percentages — **session** on top, **weekly**
  below — so it stays narrow and leaves room for your other menu bar apps.
- **Click for detail:** a native popover with your official account usage
  (Session, Weekly · All Models, and per-model weekly limits, with an
  "active limit" badge and reset countdowns), today's and this week's token
  totals with a composition chart (input / output / cache write / cache read),
  a 7-day activity chart, per-model breakdown, and estimated cost.
- **Official account usage:** reads your existing Claude Code login — 
  **silently, no permission pop-ups, never your password** — and queries
  Anthropic's usage endpoint: the exact numbers Claude Code shows. When the
  access token expires (~8h), it refreshes it the same way Claude Code does,
  so the meter stays live around the clock. See [SECURITY.md](SECURITY.md).
- **Profile switching:** if you use
  [`claude-switch`](https://github.com/Mamdouh66/homebrew-tap) (`brew install
  mamdouh66/tap/claude-switch`) profiles for multiple accounts, a dropdown in
  the popover switches between them in one click, shows each profile's plan
  (pro/max), and reloads the right account's usage immediately.
- **Local-first & private:** reads `~/.claude` for **metadata only** (token
  counts, model, timestamps). No prompt/completion text is ever stored, no
  telemetry, nothing is uploaded. See [SECURITY.md](SECURITY.md).
- **Lightweight & native:** Swift + AppKit/SwiftUI, no Dock icon, no third-party
  menu bar wrapper, no runtime dependencies. Charts use a colorblind-validated
  palette with dedicated light- and dark-mode colors.

## Requirements

- macOS 13 (Ventura) or newer
- Swift toolchain (Xcode or Command Line Tools — `xcode-select --install`)
- [Claude Code](https://claude.com/claude-code) installed and logged in (for the
  official account usage; local stats work with just a `~/.claude` directory)
- Optional: `claude-switch` for the multi-account profile dropdown

## Build & run

No Xcode project required — it builds with Swift Package Manager and assembles a
double-clickable `.app`:

```bash
git clone https://github.com/JuniorSua/ClaudeMeter.git
cd ClaudeMeter
./scripts/build-app.sh        # swift build -c release → build/ClaudeMeter.app
open build/ClaudeMeter.app    # menu bar only, no Dock icon
```

No keychain prompt, no password dialog — credentials are read through Apple's
own `security` tool, which is already authorized for the Claude Code login. To
keep the app around, drag `build/ClaudeMeter.app` into `/Applications` and
enable "Launch at login" in Settings.

Run the tests with:

```bash
./scripts/test.sh
```

## How it works

- Reads official usage (session / weekly / per-model) from Anthropic's usage
  endpoint using your Keychain login, at most once every couple of minutes
  (throttled and cached so it never hits rate limits or blanks out). Expired
  access tokens are refreshed automatically with the profile's own refresh
  token, so the meter keeps working even when Claude Code hasn't run all day.
- Scans `~/.claude/**/*.jsonl` incrementally (per-file byte offsets, `uuid`-based
  dedup) for local token/cost metadata, aggregated by session window / local day
  / configurable week, and charted over the trailing 7 days.
- Refreshes on file changes (debounced) plus a timer, and persists the last good
  numbers so they show instantly on launch.
- Profile switches (from the dropdown or the terminal) are detected immediately;
  the app drops the old account's numbers and fetches the new ones so the label
  and the data always match.

## Privacy

ClaudeMeter is local-first. It stores only usage **metadata** and never prompt or
completion text; the only network call is the read-only, authenticated usage
request described above, which can be turned off in Settings (or with the
"Stop Giving Keychain Permission" button right in the popover). Full details in
[SECURITY.md](SECURITY.md).

> Note: the local token totals reflect Claude Code activity on this Mac only.
> Usage from the web, desktop, or other devices isn't included in those totals
> (the official session/weekly percentages are account-wide).

## Development

- `./scripts/test.sh` — unit tests (Swift Testing, no Xcode needed)
- `CLAUDEMETER_SNAPSHOT=/tmp/popover.png open build/ClaudeMeter.app` — renders
  the popover UI to a PNG shortly after launch, for eyeballing UI changes
  without clicking through the menu bar

## License

[MIT](LICENSE)
