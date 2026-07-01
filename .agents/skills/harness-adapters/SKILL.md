---
name: harness-adapters
description: Agent-only reference for firstmate harness operations. Use before spawning or recovering a crewmate or secondmate, handling a trust dialog, sending a harness-specific skill invocation, interrupting or exiting an agent, resuming an exited agent, or verifying a new harness adapter. Contains verified facts for claude, codex, opencode, pi, and kiro.
user-invocable: false
---

# harness-adapters

Use this reference before any harness-specific firstmate operation: spawn, recovery, trust-dialog handling, skill invocation, interrupt, exit, resume, or adapter verification.

Crewmates default to the same harness firstmate is running on unless `config/crew-harness` records an adapter name.
The captain may override that file at bootstrap or later; a per-task instruction such as "run this one on codex" overrides it for that dispatch only.
`default` means mirror firstmate's own harness.

Each adapter splits into mechanics and knowledge.
The mechanics, including launch command, autonomy flag, and turn-end hook, live in `bin/fm-spawn.sh`.
The supervision knowledge lives here: busy signature, exit command, interrupt, dialogs, resume behavior, skill invocation, and quirks.

Never dispatch a crewmate or secondmate on an unverified adapter.
If `config/crew-harness` names an unverified adapter, tell the captain and fall back to firstmate's own harness until that adapter is verified.
If the captain asks for a new harness, propose verifying it first: spawn a trivial supervised task using `fm-spawn`'s raw-launch-command escape hatch, confirm every fact empirically, then record the mechanics in `fm-spawn`, the busy signature in `fm-watch.sh` and `fm-tmux-lib.sh` defaults, any needed `FM_COMPOSER_IDLE_RE` empty-composer override, and the verified knowledge here.

## Detection

`bin/fm-harness.sh` prints firstmate's own harness, using verified env markers first and then process ancestry.
`bin/fm-harness.sh crew` resolves the effective crewmate harness from `config/crew-harness`.
On `unknown`, ask the captain instead of guessing.
A captain override always beats detection.
When verifying a new adapter, record its env marker and command name in `bin/fm-harness.sh`.

For stuck recovery, the target window's harness is recorded as `harness=` in `state/<id>.meta`.
Use that value for interrupt, exit, resume, and skill-invocation facts.

## no-mistakes skill invocation

Send the validation skill using the target harness's skill invocation form.
Natural language is acceptable if uncertain.

- claude: `/<skill>`, for example `/no-mistakes`.
- codex: `$<skill>`, for example `$no-mistakes`; `/<skill>` is claude-only and codex rejects it as "Unrecognized command".
- opencode: no separate verified skill invocation beyond normal slash-command behavior; use natural language if the exact skill command is uncertain.
- pi: no separate verified skill invocation beyond normal command behavior; use natural language if the exact skill command is uncertain.
- kiro: skills are installed in `~/.kiro/skills/`; kiro does NOT respond to `/no-mistakes` as a slash-command invocation — crewmates on kiro ignore the slash and instead run `no-mistakes axi run --intent "..."` directly from the shell. This is verified: both crewmates in the 2026-07-01 smoke test skipped the slash and used the CLI path successfully. Brief kiro crewmates to use `no-mistakes axi run --intent "..."` explicitly; do not use `/no-mistakes` in kiro briefs.

## no-mistakes gate-response protocol (all harnesses)

When a no-mistakes gate surfaces a `needs-decision` finding, firstmate relays it to the captain, gets the decision, then **steers the crewmate to respond** — it does NOT run `no-mistakes axi respond` from its own shell.
Running `axi respond` from firstmate's shell advances the pipeline gate but leaves the crewmate idle watching an unexpected state; the crewmate needs a steer to re-attach, and the pipeline stays fragile until it does.
This invariant applies regardless of crewmate harness (claude, codex, kiro, pi).

Correct steer pattern — adapt the action to match the captain's decision:

```sh
# captain approved a fix:
bin/fm-send.sh fm-<id> 'the captain approved: fix it. Run: no-mistakes axi respond --action fix. Then continue driving the pipeline.'

# captain approved as-is (no changes needed):
bin/fm-send.sh fm-<id> 'the captain approved: accept as-is. Run: no-mistakes axi respond --action approve. Then continue driving the pipeline.'

# captain chose to skip this step:
bin/fm-send.sh fm-<id> 'the captain decided to skip this step. Run: no-mistakes axi respond --action skip. Then continue driving the pipeline.'
```

The crewmate runs `axi respond` itself, stays in the driver seat, and the pipeline stays coherent throughout.

## claude (VERIFIED)

| Fact | Value |
|---|---|
| Busy-pane signature | `esc to interrupt` |
| Exit command | `/exit` |
| Interrupt | single Escape |
| Skill invocation | `/<skill>` (e.g. `/no-mistakes`) |

First launch in a fresh worktree, or first ever on a machine, may show a trust or bypass-permissions confirmation.
After every spawn, peek the pane within about 20 seconds.
If such a dialog is showing, accept it with `bin/fm-send.sh <window> --key Enter`, or the choice the dialog requires, and verify the brief started processing.

Claude renders a predicted-next-prompt suggestion as dim/faint text inside an otherwise-empty composer after a turn completes.
A plain `tmux capture-pane` cannot tell that ghost text apart from typed text.
Firstmate launches every claude crewmate and secondmate with `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false`, scoped to firstmate-launched agents through `bin/fm-spawn.sh`, so it never touches the captain's global config.
The CLI's `--prompt-suggestions` flag is print/SDK-mode only and does not suppress the interactive composer ghost text, verified empirically on v2.1.186.
As defense in depth for any pane that flag cannot reach, including the captain's own firstmate composer that away-mode reads, the pane reader in `bin/fm-tmux-lib.sh` captures only the composer line with ANSI styling, drops dim/faint SGR 2 runs, and ignores them, so only normal-intensity typed text counts as pending input.
That styled capture is internal to the boolean detector only.
`fm-peek` and every other human or LLM-facing capture path stays plain `tmux capture-pane` with no escape codes.

## codex (VERIFIED 2026-06-11, codex-cli 0.139.0)

| Fact | Value |
|---|---|
| Busy-pane signature | `esc to interrupt` (shown as `• Working (Xs • esc to interrupt)`) |
| Exit command | `/quit` (slash popup needs about 1 second between text and Enter; `fm-send` handles it) |
| Interrupt | single Escape |
| Skill invocation | `$<skill>` (e.g. `$no-mistakes`); `/<skill>` is claude-only and codex rejects it as "Unrecognized command" |

A `$<skill>` invocation opens a `$`-autocomplete (skill) popup, the same hazard as the `/` slash popup: submitting too fast lets the popup swallow the Enter, so the invocation never lands.
`fm-send` handles it the same way it handles `/` - it gives the popup a longer settle (1.2s) between typing and the first Enter, with `fm_tmux_submit_core`'s retried Enter as the safety net - but the `$` settle is scoped to `harness=codex`, read from the target's `state/<id>.meta`.
That scope matters because, unlike `/`, a leading `$` commonly starts ordinary text (`$5/month`, `$HOME`), so a universal `$` rule would needlessly slow plain steers to claude/opencode/pi; only a codex target receiving a `$...` message gets the popup-settle.
An explicit `session:window` target has no meta, so its harness is unknown and treated as non-codex (the safe fast-path default).
This is why the validation trigger (`$no-mistakes`) to a codex crew now lands on the first Enter instead of biting the popup.

Directory trust dialog on first run per repo root: "Do you trust the contents of this directory?"
Accept with Enter.
The decision persists for the repo, so later worktrees of the same project skip it.

Resume after exit with `codex resume <session-id>`.
The session id is printed on quit.

## opencode (VERIFIED 2026-06-11, v1.15.7-1.17.3)

| Fact | Value |
|---|---|
| Busy-pane signature | `esc interrupt` (dotted spinner footer; note no "to") |
| Exit command | `/exit` |
| Interrupt | double Escape; known flaky while a long shell command runs, so a wedged pane may need `/exit` and relaunch |

No trust dialog.
Opencode can auto-upgrade itself in the background and the running TUI can exit mid-task, observed live from 1.15.7 to 1.17.3.
If a pane shows the exit banner, relaunch with `--continue` to resume the session.
`--prompt` does not auto-submit alongside `--continue`, so send the next instruction via `fm-send` once the TUI is up.

**Watcher (OpenCode-specific behavior).**
`bin/fm-watch-arm.sh` detects the OpenCode harness and manages a dedicated `fm-watch` tmux window running `fm-watch.sh` in an auto-re-arm loop (`while true; do bin/fm-watch.sh; sleep 1; done`).
The script returns immediately after confirming the watcher is alive; it does not block.
Call `bin/fm-watch-arm.sh` as a normal foreground bash call — no harness-tracked background mechanism needed.
Call it at session start (after bootstrap) and any time the watcher may have died.
Wakes are **queue-based**: the watcher writes to `.wake-queue` when an event fires, but there is no push notification to firstmate.
Always run `bin/fm-wake-drain.sh` at the start of every turn to drain any wakes that fired since the last prompt.
The `fm-watch` window in the firstmate tmux session holds the loop; if it is missing, `bin/fm-watch-arm.sh` recreates it automatically.

**Limitation: no autonomous wake-up on OpenCode.**
The watcher accurately detects crewmate completions (`done:`, `needs-decision:`, `failed:`) and writes them to `state/.wake-queue`, but OpenCode's TUI mode has no mechanism to inject a message into the active session from a background process.
Crewmate completions accumulate in the queue and are only surfaced when the captain next sends a message.
During long pipeline phases (lint, document, CI wait) firstmate is effectively blind to crewmate state changes unless the captain checks in.

**Workaround:** Use `/afk` mode during long-running crewmate work. The away-mode daemon already solves this: it monitors the wake queue and injects escalations into the firstmate pane via `tmux send-keys`. With `/afk` active, crewmate `done:`, `blocked:`, and `needs-decision:` signals reach firstmate autonomously without captain intervention. This is the recommended pattern for kiro crewmates running long pipelines (15–20 min) on OpenCode.

**Forward paths (for future work):**
- *Always-on daemon (best fit):* Extend the away-mode daemon to a lightweight "always-on" mode that injects only actionable wakes — no away-mode batching — without requiring `state/.afk` to be set. This would give firstmate autonomous wake-up during normal supervision on OpenCode.
- *opencode serve mode:* If firstmate ran under `opencode serve`, a background file-watcher on `state/.wake-queue` could call `POST /session/{id}/message` to inject a wake phrase. The REST API is confirmed: `POST /session/{id}/message` with `{"parts":[{"type":"text","text":"..."}]}` triggers a full AI turn. Requires running firstmate differently.
- *launchd WatchPaths:* A macOS `LaunchAgents` plist watching `state/.wake-queue` could fire a script that `tmux send-keys` into the firstmate window. No polling, low overhead. Requires one-time `launchctl load` setup.

## pi (VERIFIED 2026-06-11)

| Fact | Value |
|---|---|
| Busy-pane signature | `Working...` (braille spinner prefix; no `esc to interrupt` text) |
| Exit command | `/quit` |
| Interrupt | single Escape |

Pi has no permission system, so crewmates are always autonomous.
Keep the brief as one positional argument.
Multiple positional args become separate queued messages; `fm-spawn`'s template already does this correctly.

Project trust dialog can appear on the first pi run in any not-yet-trusted directory, observed even on clean worktrees.
Accept with Enter.
The decision persists per path in `~/.pi/agent/trust.json`, so later spawns in the same worktree slot skip it.

`fm-spawn` keeps the turn-end extension in `state/`, outside the worktree, because project-local extension files make the trust gate strictly worse and pollute the project.
The extension must listen for pi's `turn_end` event, not `agent_end`, so the watcher wakes after each completed turn instead of only when the whole agent run exits.
Pi sets `PI_CODING_AGENT=true` for its children; this is its harness-detection env marker.

## kiro (VERIFIED 2026-06-28, kiro-cli 2.9.0)

| Fact | Value |
|---|---|
| Busy-pane signature | `Kiro is working` (full footer: `Kiro is working · Type to steer · Ctrl+S to queue`) |
| Idle-pane signature | `ask a question or describe a task` (input box placeholder) |
| Exit command | `/quit` |
| Interrupt | single Escape (shows `● Cancelled streaming` then returns to idle) |
| Skill invocation | CLI only: `no-mistakes axi run --intent "..."` — `/no-mistakes` slash-command does NOT fire in kiro (verified 2026-07-01) |
| Env marker | `KIRO_SESSION_ID` (set for child processes) |
| Resume | `kiro-cli --resume-id <session-id>` (id printed on exit) |

**VPN / SSL workaround (NYU Langone network only).**
The NYU VPN does TLS inspection via `nyumcdecrypt.nyumc.org` whose CA is scoped in the macOS keychain only for `psm.nyumc.org`.
Kiro-cli uses macOS native TLS which respects `SSL_CERT_FILE`.
Set `KIRO_CA_BUNDLE` in `~/.zshrc` pointing at the rebuilt NYU CA bundle (see `~/workspace/repos/docs/runbooks/ssl-corporate-proxy.md`); `fm-spawn`'s launch template sets `SSL_CERT_FILE="$KIRO_CA_BUNDLE"` only when the variable is non-empty (via a `[ -n ... ] && export` guard, which avoids the zsh word-split pitfall of `${VAR:+KEY=VAL }cmd`).
Off VPN the variable is unset, the guard is skipped, and kiro connects with its default TLS settings.
Rebuild the bundle when hitting certificate expired errors (intermediate cert rotation; see runbook).

**Trust dialog.**
The `--trust-all-tools` confirmation dialog is suppressed by `{"chat.disableTrustAllConfirmation": true}` in `~/.kiro/settings/cli.json`.
`fm-spawn` writes this idempotently before every kiro launch.
If a dialog does appear (e.g. a kiro update reset the setting), accept with two Down keys then Enter (Down=Yes I accept, Down Down=Yes and don't ask again).

**No turn-end hook.**
Kiro V2 exposes no per-turn shell hook; the `hooks` field in agent configs is present but empty in V2.
Stale detection in `fm-watch.sh` covers the idle-crewmate case (threshold `FM_STALE_ESCALATE_SECS`, default 240s).
The crewmate's `done:` status write still wakes the watcher immediately at the end of its work, so end-of-task detection is unaffected.

**kiro brief scaffold note.**
When generating a brief for a kiro ship task, replace the three `/no-mistakes` slash-command references in the no-mistakes DOD with `no-mistakes axi run --intent "..."` before spawning.
The brief template is not harness-conditional; firstmate must make this substitution manually.
The three occurrences are: the initial validation trigger, the DOD instruction ("run /no-mistakes"), and the done-line example.
Search the generated `data/<id>/brief.md` for `/no-mistakes` and replace each with the CLI equivalent before handing it to the crewmate.

**MCP disabled.**
NYU Langone's AWS org has MCP disabled; the warning `MCP disabled by your administrator` appears in the footer but does not affect built-in tools (shell, file read/write, grep, glob, etc.).

**Idle-placeholder and composer state.**
The idle input box shows `ask a question or describe a task ↵` at normal intensity.
`fm-tmux-lib.sh`'s `FM_TMUX_BUSY_REGEX_DEFAULT` includes this pattern so the post-Enter composer check treats it as "empty" (not pending input) on a fast kiro turn where the placeholder reappears before the 0.4s sleep.
This pattern is intentionally absent from `fm-watch.sh`'s `BUSY_REGEX` so stale detection still fires when the crewmate is genuinely idle.

**Pre-flight checklist (run before spawning any ship crewmate on a project with GitHub Actions CI).**

1. **GitHub Actions enabled-status.** Disabled workflows will silently block CI forever on no-mistakes.
   Run before dispatching — any non-active workflow is a blocker:
   ```sh
   gh api repos/<owner>/<repo>/actions/workflows --jq '.workflows[] | select(.state != "active") | .name'
   ```
   If any are listed, re-enable them with:
   ```sh
   gh api --method PUT repos/<owner>/<repo>/actions/workflows/<id>/enable
   ```
   Verify by re-querying the workflow state (the PUT is deterministic; no test PR needed):
   ```sh
   gh api repos/<owner>/<repo>/actions/workflows/<id> --jq '{name,state}'
   ```
   Workflow IDs can be retrieved with `gh api repos/<owner>/<repo>/actions/workflows --jq '.workflows[] | {id, name, state}'`.
