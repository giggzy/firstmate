#!/usr/bin/env bash
# Regression tests for cleanup endpoint and worktree-slot identity validation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-endpoint-safety)
REAL_TMUX=$(command -v tmux || true)

make_case() {  # <name>
  local dir=$1
  mkdir -p "$TMP_ROOT/$dir/home/state" "$TMP_ROOT/$dir/home/data" \
    "$TMP_ROOT/$dir/home/config" "$TMP_ROOT/$dir/fakebin" \
    "$TMP_ROOT/$dir/worktree" "$TMP_ROOT/$dir/project"
  git init -q "$TMP_ROOT/$dir/project"
  : > "$TMP_ROOT/$dir/worktree/sentinel"
  : > "$TMP_ROOT/$dir/runtime.log"
  cat > "$TMP_ROOT/$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf 'tmux' >> "${FM_RUNTIME_LOG:?}"
printf ' <%s>' "$@" >> "${FM_RUNTIME_LOG:?}"
printf '\n' >> "${FM_RUNTIME_LOG:?}"
exit 0
SH
  cat > "$TMP_ROOT/$dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse' >> "${FM_RUNTIME_LOG:?}"
printf ' <%s>' "$@" >> "${FM_RUNTIME_LOG:?}"
printf '\n' >> "${FM_RUNTIME_LOG:?}"
exit 0
SH
  chmod +x "$TMP_ROOT/$dir/fakebin/tmux" "$TMP_ROOT/$dir/fakebin/treehouse"
  printf '%s\n' "$TMP_ROOT/$dir"
}

mark_case_as_treehouse_pool() {  # <case>
  local dir=$1
  rm -rf "$dir/worktree"
  mkdir -p "$dir/pool/1"
  git -C "$dir/project" -c user.name=test -c user.email=test@example.invalid \
    commit --allow-empty -qm pool-fixture
  git -C "$dir/project" worktree add -q --detach "$dir/pool/1/project"
  ln -s "pool/1/project" "$dir/worktree"
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' \
    "$dir/pool/1/project" > "$dir/pool/treehouse-state.json"
  : > "$dir/worktree/sentinel"
}

run_case() {  # <case> <id>
  local dir=$1 id=$2
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
  FM_RUNTIME_LOG="$dir/runtime.log" PATH="$dir/fakebin:$PATH" \
    "$TEARDOWN" "$id" --force
}

assert_refused_without_mutation() {  # <case> <id> <description>
  local dir=$1 id=$2 description=$3 rc
  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "$description: teardown unexpectedly succeeded"
  assert_present "$dir/home/state/$id.meta" "$description: metadata changed before refusal"
  assert_present "$dir/worktree/sentinel" "$description: worktree changed before refusal"
  [ ! -s "$dir/runtime.log" ] || fail "$description: runtime command ran before refusal: $(cat "$dir/runtime.log")"
}

test_invalid_endpoint_records_refuse_before_mutation() {
  local dir id=endpoint-a

  dir=$(make_case missing)
  fm_write_meta "$dir/home/state/$id.meta" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "missing endpoint"

  dir=$(make_case empty)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=" "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "empty endpoint"

  dir=$(make_case malformed)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=ambient-current-window" "worktree=$dir/worktree" \
    "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "malformed endpoint"

  dir=$(make_case mismatched)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-other-task" "endpoint_task_id=other-task" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "task-mismatched endpoint"

  dir=$(make_case empty-binding)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-$id" "endpoint_task_id=" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "empty task binding"

  dir=$(make_case duplicate-binding)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-$id" "endpoint_task_id=$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "duplicate task binding"

  pass "fm-teardown: missing, empty, malformed, ambiguous, and task-mismatched endpoints refuse before every mutation or runtime call"
}

test_control_lock_contention_refuses_before_mutation() {
  local dir id=locked-task lock holder i=0 rc
  dir=$(make_case control-lock)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  lock="$dir/home/state/.control-$id.lock"
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    sleep 30
  ) &
  holder=$!
  while [ ! -e "$lock" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$lock" ] || {
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    fail "could not stage a held lifecycle lock"
  }
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-$id" "endpoint_task_id=other-task" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"

  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "teardown unexpectedly succeeded under lifecycle lock contention"
  assert_present "$dir/home/state/$id.meta" "contended teardown removed task metadata"
  assert_present "$dir/worktree/sentinel" "contended teardown changed the worktree"
  assert_present "$lock" "contended teardown removed another action's lock"
  [ ! -s "$dir/runtime.log" ] \
    || fail "contended teardown reached the runtime: $(cat "$dir/runtime.log")"
  assert_contains "$(cat "$dir/stderr")" "another lifecycle action is already running" \
    "contended teardown should serialize before reading mutable task metadata"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  pass "fm-teardown: a concurrent lifecycle action refuses before mutation"
}

test_non_pool_teardown_ignores_task_set_lock() {
  local dir id=non-pool-task lock ready holder i=0
  dir=$(make_case non-pool-task-set-lock)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/missing-worktree" "project=$dir/project" "kind=scout"
  lock="$dir/home/state/.task-set.lock"
  ready="$dir/task-set-lock-ready"
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    trap 'fm_lock_release "$lock"' EXIT
    : > "$ready"
    sleep 30
  ) &
  holder=$!
  while [ ! -e "$ready" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$ready" ] || {
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    fail "could not stage an in-progress task publication"
  }

  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr" \
    || fail "non-pool teardown was blocked by an unrelated task publication: $(cat "$dir/stderr")"
  assert_absent "$dir/home/state/$id.meta" "non-pool teardown left task metadata"
  assert_present "$lock" "non-pool teardown removed the publisher's lock"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  pass "fm-teardown: non-pool cleanup ignores unrelated task publication locks"
}

test_metadata_lock_serializes_destructive_cleanup() {
  local dir id=metadata-locked-task lock ready release holder teardown_pid i=0 rc
  dir=$(make_case metadata-lock)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  lock="$dir/home/state/.meta-$id.lock"
  ready="$dir/meta-lock-ready"
  release="$dir/meta-lock-release"
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    trap 'fm_lock_release "$lock"' EXIT
    : > "$ready"
    while [ ! -e "$release" ]; do
      sleep 0.01
    done
  ) &
  holder=$!
  while [ ! -e "$ready" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$ready" ] || {
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    fail "could not stage a held metadata lock"
  }

  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr" &
  teardown_pid=$!
  sleep 0.2
  if ! kill -0 "$teardown_pid" 2>/dev/null; then
    : > "$release"
    wait "$holder" 2>/dev/null || true
    wait "$teardown_pid" 2>/dev/null || true
    fail "teardown did not wait for the shared metadata writer lock"
  fi
  assert_present "$dir/home/state/$id.meta" "metadata-lock contention removed task metadata"
  assert_present "$dir/worktree/sentinel" "metadata-lock contention changed the worktree"
  [ ! -s "$dir/runtime.log" ] \
    || fail "metadata-lock contention reached the runtime: $(cat "$dir/runtime.log")"

  : > "$release"
  wait "$holder" || fail "metadata lock holder failed"
  wait "$teardown_pid"; rc=$?
  expect_code 0 "$rc" "teardown should complete after the metadata writer releases"
  assert_absent "$dir/home/state/$id.meta" \
    "serialized teardown left a task record that a completed writer could resurrect"
  pass "fm-teardown: destructive cleanup serializes with metadata writers"
}

test_supported_backend_endpoint_records_validate() {
  local dir id backend target
  dir=$(make_case valid-backends)
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-backend.sh"

  id=tmux-task
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$dir/worktree" "project=$dir/project"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid tmux endpoint refused"
  [ "$FM_BACKEND_VALIDATED_BACKEND:$FM_BACKEND_VALIDATED_TARGET" = "tmux:firstmate:fm-$id" ] || fail "tmux endpoint validation returned wrong identity"

  id=tmux-spaced-session
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=team work:fm-$id" "worktree=$dir/worktree" "project=$dir/project"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid tmux endpoint with a spaced session name refused"
  [ "$FM_BACKEND_VALIDATED_TARGET" = "team work:fm-$id" ] || fail "tmux validation changed the spaced session identity"

  id=herdr-task
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=lab:w1:p2" "endpoint_task_id=$id" "worktree=$dir/worktree" "project=$dir/project" \
    "backend=herdr" "herdr_session=lab" "herdr_workspace_id=w1" "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid Herdr endpoint refused"

  id=zellij-task
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=lab:7" "endpoint_task_id=$id" "worktree=$dir/worktree" "project=$dir/project" \
    "backend=zellij" "zellij_session=lab" "zellij_tab_id=3" "zellij_pane_id=7"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid Zellij endpoint refused"

  id=orca-task
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-7" \
    "worktree=$dir/worktree" "project=$dir/project" "backend=orca" "orca_worktree_id=worktree-9"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid Orca endpoint refused"
  [ "$FM_BACKEND_VALIDATED_TARGET" = term-7 ] || fail "Orca validation did not select its terminal"

  id=cmux-task
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=workspace-1:surface-2" "endpoint_task_id=$id" "worktree=$dir/worktree" "project=$dir/project" \
    "backend=cmux" "cmux_workspace_id=workspace-1" "cmux_surface_id=surface-2"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid cmux endpoint refused"

  for backend in tmux herdr zellij orca cmux; do
    set +e
    fm_backend_kill "$backend" "" >/dev/null 2>&1
    target=$?
    set -e
    [ "$target" -ne 0 ] || fail "$backend generic kill accepted an empty target"
  done
  pass "cleanup identity: valid tmux, Herdr, Zellij, Orca, and cmux records validate while every empty backend target refuses"
}

test_tmux_empty_target_refuses_without_invocation() {
  local dir rc
  dir=$(make_case direct-empty)
  set +e
  FM_RUNTIME_LOG="$dir/runtime.log" PATH="$dir/fakebin:$PATH" \
    bash -c '. "$1/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_kill ""' _ "$ROOT" \
    > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "direct empty tmux target unexpectedly succeeded"
  [ ! -s "$dir/runtime.log" ] || fail "direct empty tmux target invoked tmux"
  pass "tmux backend: direct empty target returns nonzero without invoking tmux"
}

test_recorded_process_identity_cleanup_is_exact() {
  local dir target_pid control_pid target_record control_record live_command
  dir=$(make_case recorded-process)
  sleep 30 &
  control_pid=$!
  sleep 30 &
  target_pid=$!
  printf '%s\n' "$control_pid" > "$dir/control.pid"
  printf '%s\n' "$target_pid" > "$dir/target.pid"
  target_record=$(cat "$dir/target.pid")
  control_record=$(cat "$dir/control.pid")
  [ "$target_record" = "$target_pid" ] && [ "$control_record" = "$control_pid" ] \
    || fail "recorded process identity changed before cleanup"
  live_command=$(ps -p "$target_record" -o comm= 2>/dev/null | tr -d '[:space:]')
  case "$live_command" in sleep) ;; *) fail "recorded target pid no longer belongs to the expected child" ;; esac
  kill -TERM "$target_record"
  wait "$target_record" 2>/dev/null || true
  kill -0 "$target_record" 2>/dev/null && fail "exact target pid survived cleanup"
  kill -0 "$control_record" 2>/dev/null || fail "independent control process was disturbed"
  kill -TERM "$control_record"
  wait "$control_record" 2>/dev/null || true
  pass "process cleanup: creation-time PID identity removes only the exact child and preserves the control child"
}

isolated_tmux_window_exists() {  # <dir> <socket> <session> <window>
  ( cd "$1" && "$REAL_TMUX" -S "$2" list-windows -t "$3" -F '#{window_name}' 2>/dev/null ) \
    | grep -Fqx "$4"
}

test_isolated_tmux_invalid_and_valid_cleanup() {
  local dir socket socket_id session='endpoint safety' target_id=target control=control target=fm-target
  local prefix_target=fm-prefix prefix_survivor=fm-prefix2 rc
  [ -n "$REAL_TMUX" ] || { echo "skip - tmux not installed"; return 0; }
  dir=$(make_case isolated-real)
  socket=dedicated.sock
  socket_id="$dir/$socket"
  ( cd "$dir" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" new-session -d -s "$session" -n "$control" )
  ( cd "$dir" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" new-window -d -t "$session:" -n "$target" )
  printf '%s\n' "$socket_id" > "$dir/socket.identity"
  cat > "$dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
set -eu
[ -z "\${TMUX:-}" ] && [ -z "\${TMUX_PANE:-}" ] || exit 91
[ "\${FM_TEST_TMUX_SOCKET:-}" = '$socket_id' ] || exit 92
[ "\$(cat '$dir/socket.identity')" = '$socket_id' ] || exit 93
printf 'tmux' >> "\${FM_RUNTIME_LOG:?}"
printf ' <%s>' "\$@" >> "\${FM_RUNTIME_LOG:?}"
printf '\n' >> "\${FM_RUNTIME_LOG:?}"
cd '$dir'
exec '$REAL_TMUX' -S '$socket' "\$@"
SH
  chmod +x "$dir/fakebin/tmux"

  fm_write_meta "$dir/home/state/invalid.meta" \
    "window=" "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  set +e
  env -u TMUX -u TMUX_PANE FM_TEST_TMUX_SOCKET="$socket_id" \
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$PATH" "$TEARDOWN" invalid --force \
    > "$dir/invalid.out" 2> "$dir/invalid.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "isolated invalid endpoint unexpectedly succeeded"
  [ ! -s "$dir/runtime.log" ] || fail "isolated invalid endpoint reached tmux"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$control" || fail "invalid cleanup removed control window"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$target" || fail "invalid cleanup removed target window"

  set +e
  # shellcheck disable=SC2016 # $1 expands inside the isolated child shell.
  env -u TMUX -u TMUX_PANE FM_TEST_TMUX_SOCKET="$socket_id" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$PATH" bash -c \
    '. "$1/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_kill ""' _ "$ROOT" \
    > "$dir/empty.out" 2> "$dir/empty.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "isolated direct empty target unexpectedly succeeded"
  [ ! -s "$dir/runtime.log" ] || fail "isolated direct empty target reached tmux"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$control" || fail "direct empty cleanup removed control window"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$target" || fail "direct empty cleanup removed target window"

  ( cd "$dir" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" new-window -d -t "=$session:" -n "$prefix_survivor" )
  # shellcheck disable=SC2016 # $1 and $2 expand inside the isolated child shell.
  env -u TMUX -u TMUX_PANE FM_TEST_TMUX_SOCKET="$socket_id" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$PATH" bash -c \
    '. "$1/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_kill "$2"' _ "$ROOT" "$session:$prefix_target"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$prefix_survivor" \
    || fail "missing exact target cleanup removed its prefix-matched neighbor"

  fm_write_meta "$dir/home/state/$target_id.meta" \
    "window=$session:$target" "endpoint_task_id=$target_id" \
    "worktree=$dir/nonexistent-worktree" "project=$dir/nonexistent-project" \
    "kind=scout" "mode=no-mistakes"
  env -u TMUX -u TMUX_PANE FM_TEST_TMUX_SOCKET="$socket_id" \
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$PATH" "$TEARDOWN" "$target_id" --force \
    > "$dir/valid.out" 2> "$dir/valid.err" \
    || fail "isolated valid endpoint teardown failed: $(cat "$dir/valid.err")"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$target" \
    && fail "valid cleanup did not remove the exact target window"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$control" \
    || fail "valid cleanup removed the independent control window"
  grep -Fqx "tmux <kill-window> <-t> <=$session:=$target>" "$dir/runtime.log" \
    || fail "valid cleanup did not invoke exactly the recorded target: $(cat "$dir/runtime.log")"

  ( cd "$dir" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" kill-server 2>/dev/null ) || true
  pass "fm-teardown: exact tmux cleanup preserves invalid and prefix-matched neighbors while removing only the recorded target"
}

test_isolated_tmux_no_lsof_reap_and_retry() {
  local dir socket session='reap safety' id=reap-task target=fm-reap-task
  local control_pid target_pid rc
  [ -n "$REAL_TMUX" ] || { echo "skip - tmux not installed"; return 0; }
  dir=$(make_case isolated-reap)
  socket="fm-reap-test-$$"
  env -u TMUX -u TMUX_PANE "$REAL_TMUX" -L "$socket" new-session -d -s "$session" -n main 'sleep 120' \
    || fail "could not start isolated tmux server"
  env -u TMUX -u TMUX_PANE "$REAL_TMUX" -L "$socket" new-window -d -t "=$session:" -n "$target" 'sleep 120' \
    || fail "could not start isolated task window"
  control_pid=$(env -u TMUX -u TMUX_PANE "$REAL_TMUX" -L "$socket" display-message -p -t "=$session:=main" '#{pane_pid}')
  target_pid=$(env -u TMUX -u TMUX_PANE "$REAL_TMUX" -L "$socket" display-message -p -t "=$session:=$target" '#{pane_pid}')
  # This wrapper is the only tmux executable on the test PATH. It pins every
  # teardown invocation to this dedicated socket, never the ambient server.
  cat > "$dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
exec '$REAL_TMUX' -L '$socket' "\$@"
SH
  # Fail the first return after closing the task window, as in a cleanup retry.
  cat > "$dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
if [ ! -f '$dir/returned-once' ]; then
  touch '$dir/returned-once'
  exit 1
fi
exit 0
SH
  chmod +x "$dir/fakebin/tmux" "$dir/fakebin/treehouse"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=$session:$target" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  # /usr/sbin is intentionally excluded: lsof is absent, while ps, git, and
  # the isolated tmux wrapper remain available to the actual teardown script.
  set +e
  env -u TMUX -u TMUX_PANE FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    PATH="$dir/fakebin:/usr/bin:/bin" "$TEARDOWN" "$id" --force \
    > "$dir/first.out" 2> "$dir/first.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "first return should fail so cleanup can be retried"
  [ -f "$dir/home/state/$id.meta" ] || fail "failed return erased task record"
  kill -0 "$control_pid" 2>/dev/null || fail "first cleanup killed control pane"
  if kill -0 "$target_pid" 2>/dev/null; then
    fail "live task pane process group survived no-lsof cleanup"
  fi
  # The counterfactual matters: a non-exact lookup silently returns main,
  # while exact lookup fails once the task window has been closed.
  [ "$(env -u TMUX -u TMUX_PANE "$REAL_TMUX" -L "$socket" display-message -p -t "$session:$target" '#{pane_pid}')" = "$control_pid" ] \
    || fail "isolated tmux did not reproduce missing-window fallback"
  if env -u TMUX -u TMUX_PANE "$REAL_TMUX" -L "$socket" has-session -t "=$session:=$target" 2>/dev/null; then
    fail "exact target unexpectedly resolved the closed task window"
  fi
  env -u TMUX -u TMUX_PANE FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    PATH="$dir/fakebin:/usr/bin:/bin" "$TEARDOWN" "$id" --force \
    > "$dir/retry.out" 2> "$dir/retry.err" \
    || fail "retry with absent task pane failed: $(cat "$dir/retry.err")"
  kill -0 "$control_pid" 2>/dev/null || fail "retry killed control pane through tmux target fallback"
  [ ! -f "$dir/home/state/$id.meta" ] || fail "retry did not complete cleanup"
  env -u TMUX -u TMUX_PANE "$REAL_TMUX" -L "$socket" kill-server 2>/dev/null || true
  pass "fm-teardown: without lsof a live task group is reaped and an absent task pane cannot reap the control pane on retry"
}

# --- Treehouse project-lock anchoring across home layouts --------------------
#
# The lock is anchored at the local root home, so every home on this machine
# that can reach the same pool must derive the identical file. A remote parent
# binding terminates that walk at the home holding it: its parent is on another
# machine and can neither hold nor observe a lock taken here.

write_local_parent_record() {  # <home> <parent-home>
  cat > "$1/.fm-secondmate-parent" <<REC
schema=fm-secondmate-parent.v1
route=local
parent_home=$2
REC
}

write_remote_parent_record() {  # <home>
  cat > "$1/.fm-secondmate-parent" <<'REC'
schema=fm-secondmate-parent.v1
route=remote
parent_host=machine-a
REC
}

make_home() {  # <path>
  mkdir -p "$1/state" "$1/data" "$1/config" "$1/projects"
}

resolve_project_lock() {  # <home> <project>
  FM_HOME="$1" bash -c '. "$1"; fm_treehouse_project_lock_path "$2"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$2"
}

test_project_lock_anchors_at_the_local_root_across_home_layouts() {
  local dir main_home main_project local_mate remote_mate remote_child
  local main_lock mate_lock remote_lock child_lock orphan_lock rc
  dir=$(make_case project-lock-anchoring)
  git -C "$dir/project" -c user.name=test -c user.email=test@example.invalid \
    commit --allow-empty -qm anchor-fixture

  # Main-home layout: a root home and a local secondmate beneath it.
  main_home="$dir/home"
  main_project="$main_home/projects/project"
  make_home "$main_home"
  git clone -q "$dir/project" "$main_project"
  local_mate="$dir/local-mate"
  make_home "$local_mate"
  write_local_parent_record "$local_mate" "$main_home"
  git clone -q "$dir/project" "$local_mate/projects/project"

  # Remote layout: a home seeded from another machine, plus its own local child.
  remote_mate="$dir/remote-mate"
  make_home "$remote_mate"
  write_remote_parent_record "$remote_mate"
  git clone -q "$dir/project" "$remote_mate/projects/project"
  remote_child="$dir/remote-mate-child"
  make_home "$remote_child"
  write_local_parent_record "$remote_child" "$remote_mate"
  git clone -q "$dir/project" "$remote_child/projects/project"

  main_lock=$(resolve_project_lock "$main_home" "$main_project") \
    || fail "the root home could not resolve its project lock"
  mate_lock=$(resolve_project_lock "$local_mate" "$local_mate/projects/project") \
    || fail "a local secondmate home could not resolve its project lock"
  remote_lock=$(resolve_project_lock "$remote_mate" "$remote_mate/projects/project") \
    || fail "a remote-seeded secondmate home could not resolve its project lock"
  child_lock=$(resolve_project_lock "$remote_child" "$remote_child/projects/project") \
    || fail "a local child of a remote-seeded home could not resolve its project lock"

  [ "$main_lock" = "$mate_lock" ] \
    || fail "the root home and its local secondmate derived different project locks"
  [ "$remote_lock" = "$child_lock" ] \
    || fail "a remote-seeded home and its local child derived different project locks"
  case "$remote_lock" in
    "$remote_mate/state/"*) ;;
    *) fail "a remote-seeded home anchored its project lock outside its own state: $remote_lock" ;;
  esac

  # An origin-less local-only project still resolves, keyed on its worktree top.
  git init -q "$remote_mate/projects/local-only"
  orphan_lock=$(resolve_project_lock "$remote_mate" "$remote_mate/projects/local-only") \
    || fail "an origin-less local-only project could not resolve its lock in a remote-seeded home"
  [ "$orphan_lock" != "$remote_lock" ] \
    || fail "an origin-less project shared the lock identity of an unrelated origin"

  # Everything other than a remote route still fails closed.
  printf 'schema=fm-secondmate-parent.v1\nroute=sideways\n' \
    > "$remote_child/.fm-secondmate-parent"
  set +e
  resolve_project_lock "$remote_child" "$remote_child/projects/project" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an unsupported parent route resolved a project lock instead of refusing"

  pass "Treehouse project locking anchors at the local root for main-home, local-secondmate, and remote-seeded layouts"
}

test_remote_seeded_home_returns_its_uncontested_slot() {
  local dir id=remote-task rc
  dir=$(make_case remote-home-teardown)
  mark_case_as_treehouse_pool "$dir"
  write_remote_parent_record "$dir/home"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"

  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || fail "teardown in a remote-seeded home refused its own uncontested slot: $(cat "$dir/stderr")"
  assert_absent "$dir/home/state/$id.meta" "remote-seeded teardown left the task record"
  grep -Fq "treehouse <return>" "$dir/runtime.log" \
    || fail "remote-seeded teardown did not return its own pool slot: $(cat "$dir/runtime.log")"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# remote-seeded Treehouse teardown command\n'
    printf '$ FM_HOME=%s bin/fm-teardown.sh %s --force\n' "$dir/home" "$id"
    printf 'stdout:\n'; cat "$dir/stdout"
    printf 'stderr:\n'; cat "$dir/stderr"
    printf 'exit=%s\nruntime calls:\n' "$rc"; cat "$dir/runtime.log"
    printf 'task metadata=%s\nslot sentinel=%s\n' \
      "$([ -e "$dir/home/state/$id.meta" ] && printf present || printf removed)" \
      "$([ -e "$dir/worktree/sentinel" ] && printf present || printf removed)"
  fi

  pass "fm-teardown: a remote-seeded secondmate home returns its own uncontested pool slot"
}

test_remote_seeded_home_still_refuses_a_slot_its_child_holds() {
  local dir id=remote-stale other=child-task child_home child_project rc
  dir=$(make_case remote-home-collision)
  mark_case_as_treehouse_pool "$dir"
  write_remote_parent_record "$dir/home"
  printf 'fixture\n' > "$dir/project/tracked"
  git -C "$dir/project" add tracked
  git -C "$dir/project" -c user.name=test -c user.email=test@example.invalid commit -qm fixture
  child_home="$dir/child-home"
  child_project="$child_home/projects/project"
  make_home "$child_home"
  write_local_parent_record "$child_home" "$dir/home"
  git clone -q "$dir/project" "$child_project"
  printf '%s\n' "- mate - fixture (home: $child_home; scope: test; projects: project; added 2026-01-01)" \
    > "$dir/home/data/secondmates.md"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  fm_write_meta "$child_home/state/$other.meta" \
    "window=firstmate:fm-$other" "endpoint_task_id=$other" \
    "worktree=$dir/worktree" "project=$child_project" "kind=scout"

  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] \
    || fail "a remote-seeded home returned a pool slot its own local child still holds"
  assert_present "$dir/home/state/$id.meta" "remote-layout collision removed stale metadata"
  assert_present "$child_home/state/$other.meta" "remote-layout collision removed live metadata"
  assert_present "$dir/worktree/sentinel" "remote-layout collision reset the shared slot"
  assert_contains "$(cat "$dir/stderr")" "$other" \
    "remote-layout refusal should name the task holding the slot"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# remote-seeded cross-home collision command\n'
    printf '$ FM_HOME=%s bin/fm-teardown.sh %s --force\n' "$dir/home" "$id"
    printf 'stderr:\n'; cat "$dir/stderr"
    printf 'exit=%s\nruntime calls=%s\n' "$rc" \
      "$([ -s "$dir/runtime.log" ] && cat "$dir/runtime.log" || printf none)"
    printf 'remote metadata=%s\nchild metadata=%s\nslot sentinel=%s\n' \
      "$([ -e "$dir/home/state/$id.meta" ] && printf preserved || printf removed)" \
      "$([ -e "$child_home/state/$other.meta" ] && printf preserved || printf removed)" \
      "$([ -e "$dir/worktree/sentinel" ] && printf preserved || printf removed)"
  fi

  pass "fm-teardown: slot ownership across a remote-seeded home and its local child still refuses"
}

test_remote_layout_homes_serialize_on_one_project_lock() {
  local dir id=remote-serialize child_home child_project lock holder rc waited=0
  dir=$(make_case remote-lock-exclusion)
  mark_case_as_treehouse_pool "$dir"
  write_remote_parent_record "$dir/home"
  printf 'fixture\n' > "$dir/project/tracked"
  git -C "$dir/project" add tracked
  git -C "$dir/project" -c user.name=test -c user.email=test@example.invalid commit -qm fixture
  child_home="$dir/child-home"
  child_project="$child_home/projects/project"
  make_home "$child_home"
  write_local_parent_record "$child_home" "$dir/home"
  git clone -q "$dir/project" "$child_project"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"

  # The local child takes the lock its own home derives and stays alive holding
  # it, standing in for a slot allocation running in that home right now.
  lock=$(resolve_project_lock "$child_home" "$child_project") \
    || fail "the local child could not resolve the shared project lock"
  FM_HOME="$child_home" bash -c \
    '. "$1"; fm_lock_try_acquire "$2" || exit 1; : > "$3"; exec sleep 30' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$lock" "$dir/lock-held" &
  holder=$!
  while [ ! -e "$dir/lock-held" ] && [ "$waited" -lt 100 ]; do
    kill -0 "$holder" 2>/dev/null || break
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -e "$dir/lock-held" ] || fail "the local child never took the shared project lock"

  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  [ "$rc" -ne 0 ] \
    || fail "a remote-seeded home returned a pool slot while its local child held the shared lock"
  assert_present "$dir/home/state/$id.meta" "contended remote-layout teardown removed the task record"
  assert_present "$dir/worktree/sentinel" "contended remote-layout teardown reset the slot"
  [ ! -s "$dir/runtime.log" ] \
    || fail "contended remote-layout teardown reached the runtime: $(cat "$dir/runtime.log")"
  assert_contains "$(cat "$dir/stderr")" "another Treehouse slot allocation or return is in progress" \
    "the refusal should name the shared project lock, not some unrelated check"

  pass "Treehouse project locking still serializes two homes across the remote-seeded boundary"
}

test_invalid_endpoint_records_refuse_before_mutation
test_control_lock_contention_refuses_before_mutation
test_non_pool_teardown_ignores_task_set_lock
test_metadata_lock_serializes_destructive_cleanup
test_supported_backend_endpoint_records_validate
test_tmux_empty_target_refuses_without_invocation
test_recorded_process_identity_cleanup_is_exact
test_isolated_tmux_invalid_and_valid_cleanup
test_isolated_tmux_no_lsof_reap_and_retry
