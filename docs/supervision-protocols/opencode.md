Mode: OpenCode TUI plugin background wake.

When supervision is appropriate and away mode is not active (the plugin performs a guarded check itself):
1. Drain first with `bin/fm-wake-drain.sh`.
2. The OpenCode plugin (`.opencode/plugins/fm-primary-watch-arm.js`) performs its own session-lock safety check before attempting an arm. It treats a missing, corrupt, or dead lock-holder as safe to arm (it also probes the recorded PID with a low-cost liveness check); only a live lock held by another unrelated firstmate process will cause the plugin to report read-only/healthy and refuse to start a fresh watcher.
3. When the plugin sees `session.idle` it spawns `bin/fm-watch-arm.sh --restart` (non-blocking from the idle handler). If the spawned child exits with an actionable watcher reason or a failure, the plugin uses `client.session.promptAsync` to surface the wake to the user.
4. If the plugin reports `watcher: healthy ...` (a live, identity-matching watcher already holds the lock), do not start another cycle. The plugin will not suppress a genuine guard-run when the lock holder is alive and external; it instead surfaces that condition as `healthy`/`external` so the guard can run a non-blind follow-up.
5. If the plugin reports a watcher failure, drain queued wakes, inspect the failure text, and use `bin/fm-watch-arm.sh` manually only as a short recovery probe.
6. Never use shell `&` for watcher supervision.
   The arm mechanism above is plugin-owned, not a model tool call, but a manual recovery probe that backgrounds, pipes, or bundles the arm is denied automatically by the PreToolUse seatbelt (`.opencode/plugins/fm-primary-pretool-check.js`, `bin/fm-arm-pretool-check.sh`).
7. Do not rely on this plugin in headless `opencode run`; firstmate primary supervision targets persistent OpenCode TUI sessions.

OpenCode's persistent TUI plugin runtime is the wake mechanism.
The plugin applies in the main primary checkout and a secondmate's own home, and stays silent only in child crewmate and scout worktrees.
