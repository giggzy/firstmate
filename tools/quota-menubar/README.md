# quota-menubar

A [SwiftBar](https://swiftbar.app) / [xbar](https://xbarapp.com) plugin that shows Anthropic (Claude), OpenAI (Codex), and GitHub Copilot quota usage in the macOS menu bar, backed by [`quota-axi`](https://github.com/kunchenguid/quota-axi).

This is a personal utility, not core firstmate machinery — it doesn't hook into any firstmate dispatch or skill logic. It's just a shell script that shells out to `quota-axi --json` and formats the result.

## What SwiftBar / xbar are

Both are free macOS menu bar apps that run a folder of scripts on a timer and render whatever each script prints to stdout as a menu bar item + dropdown menu. SwiftBar is the actively maintained successor to xbar and is generally the better default; xbar also still works with this plugin since they share the same plugin format. Neither is installed or required by this repo — you install one yourself if you want to use this.

## Install

1. Install SwiftBar (`brew install --cask swiftbar`) or xbar (`brew install --cask xbar`), then launch it once and pick (or create) a plugins folder when prompted.
2. Copy `quota-usage.5m.sh` from this directory into that plugins folder.
3. Make sure it's executable: `chmod +x quota-usage.5m.sh` (it already is in this repo, but folder copies don't always preserve that bit).
4. SwiftBar/xbar will pick it up automatically. The `.5m.` in the filename sets a 5-minute refresh interval — rename the file (e.g. `quota-usage.1m.sh`) to change it.

## Requirements

- **`quota-axi` >= 0.1.17** on `PATH`. At the time this was written, `npm install -g quota-axi` on this machine installed a stale `0.1.6` from an old global npm cache — if usage windows look wrong or missing, run `quota-axi update` (or `npm install -g quota-axi@latest`) and confirm with `quota-axi --version` before assuming the plugin is broken.
- **`jq`** on `PATH` (`brew install jq`).
- Claude and OpenAI (Codex) auth already set up the normal way you'd use those CLIs day to day (`claude` login, Codex CLI login). The first run may need one-time macOS Keychain approval — the script always passes `--allow-keychain-prompt` to `quota-axi` for that reason.

## What it shows

- **Menu bar line**: `Q C:<claude%> O:<codex%>`, color-coded green/orange/red by whichever of Claude or Codex is lower.
- **Dropdown**: per-window detail for Claude (session + weekly) and OpenAI/Codex (weekly), each with its reset time.
- **GitHub Copilot**: shown in the dropdown but explicitly labeled "unverified" and always gray, never factored into the menu bar color or summary. `quota-axi` itself declines to compute an effective remaining percentage for Copilot — every window it reports came back with an epoch (`1970-01-01`) reset timestamp, which looks like missing data from GitHub's endpoint rather than a real "never resets" value. Don't trust these numbers without checking GitHub's own billing page.
- **Kiro**: intentionally omitted. As of this writing, `quota-axi` has no `kiro` provider and `kiro-cli` has no usage/quota/billing subcommand — only a `dashboard` command that opens a web page. There's no local API or file to read from, so the plugin just prints a one-line note pointing at the Kiro web dashboard instead of scraping anything. See `data/quota-consolidation-scout-g1/report.md` for how that was verified.
- **Refresh**: a manual "Refresh" item using SwiftBar's native `refresh=true` action.

## If something looks wrong

Run the underlying command directly to separate a plugin bug from a `quota-axi`/auth problem:

```
quota-axi --json --allow-keychain-prompt
```

If that reports `auth_required` for a provider you expect to be signed in to, fix that first (re-run `claude` login, re-run the Codex CLI login, etc.) — the plugin only formats whatever `quota-axi` reports, it doesn't do any auth of its own.

## Testing

There's no menu-bar-level test harness in this repo (SwiftBar/xbar aren't installed here, and this plugin doesn't warrant standing up one for a personal utility script). What's covered instead:

- `bash -n quota-usage.5m.sh` — syntax check.
- `shellcheck quota-usage.5m.sh` — clean at the repo's pinned ShellCheck version (`bin/fm-lint.sh`'s `REQUIRED_SHELLCHECK`).
- The script degrades to a visible, non-blank error line (never silent/blank output) when `quota-axi` is missing, `jq` is missing, or `quota-axi --json` returns unparseable output — verified by running it with those tools removed from `PATH`.
