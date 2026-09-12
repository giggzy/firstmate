#!/usr/bin/env bash
# fm-decision-hold.sh - transitional compatibility shim over bin/fm-captain-hold.sh.
#
# The separate "decision" concept collapsed into the one primitive the captain
# cares about: a task held for the captain. bin/fm-captain-hold.sh owns every
# surviving behavior; this shim only maps the retired command surface onto it so
# in-flight work briefed before the collapse keeps working for one release, and
# it will be removed in the release after the collapse lands.
#
# Mapping (old -> new):
#   id <origin> <key>                      -> prints the legacy <origin>-decision-<key> identity
#   hold <origin> <key> --title --reason [--repo]
#                                          -> hold <origin>-decision-<key> --origin <origin> ...
#   complete <origin> (--none | <key>...)  -> complete <origin> (--none | <origin>-decision-<key>...)
#   verify <origin>                        -> verify <origin>
#   resolve <origin> <key> --decision-file <f> --routed-to <id>...
#                                          -> answer <origin>-decision-<key> with the routed ids
#                                             appended to the decision text, then clear the
#                                             recorded blocked-by edges through tasks-axi; an
#                                             exact replay of a pre-collapse routed record reuses
#                                             its historical digest and text before clearing edges
#   answer|decline|repair <origin> <key> --decision-file <f>
#                                          -> answer <origin>-decision-<key> --decision-file <f>
#   answers (<origin> | --any-origin) --source <p>
#                                          -> answers with the same positional (the intake resolves
#                                             task ids first and legacy identities second)
#   bind <source> (<origin> | --any-origin) -> bind <source> [<origin>]
#   unbind | binding <source>              -> unchanged
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-decision-hold: %s\n' "$*" >&2
  exit 1
}

validate_slug() {  # <label> <value>
  case "$2" in
    ''|*[!A-Za-z0-9._-]*) fail "$1 must be a non-empty privacy-safe slug: $2" ;;
  esac
}

compose() {  # <origin> <key>
  validate_slug origin-id "$1"
  validate_slug decision-key "$2"
  printf '%s-decision-%s' "$1" "$2"
}

task_show() {
  FM_HOME="$FM_HOME" FM_DATA_OVERRIDE='' "$SCRIPT_DIR/fm-tasks-axi.sh" show "$1" --full 2>/dev/null
}

show_field() {
  local output=$1 field=$2
  printf '%s\n' "$output" | sed -n "s/^  $field: //p" | head -1
}

normalized_blocked_by() {
  local blocked
  blocked=$(show_field "$1" blocked_by | tr -d '[:space:]')
  blocked=${blocked#\"}
  blocked=${blocked%\"}
  [ "$blocked" != - ] || blocked=''
  printf '%s' "$blocked"
}

list_has_key() {
  case ",$1," in
    *",$2,"*) return 0 ;;
    *) return 1 ;;
  esac
}

sha256_text() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    fail "shasum or sha256sum is required"
  fi
}

recorded_field() {
  local rest=$1 label=$2
  case "$rest" in
    *"$label: "*) rest=${rest#*"$label: "} ;;
    *) return 1 ;;
  esac
}

sorted_key_union() {  # <comma-list> <newline-or-space-separated-new-keys>
  local existing=$1 new=$2
  {
    printf '%s\n' "$existing" | tr ',' '\n'
    printf '%s\n' "$new" | tr ' ' '\n'
  } | sed '/^$/d' | LC_ALL=C sort -u | paste -sd, -
}

meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# The PR identity parser permits only pr_head and X link fields after pr=.
# Replace the inventory before that suffix, preserving its original order.
stamp_inventory() (  # <meta> <comma-separated-keys>
  local meta=$1 keys=$2 state device tmp line seen_pr=0 has_pr=0
  state=${meta%/*}
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  device=$(fm_pr_file_device "$state") || return 1
  fm_pr_regular_destination_on_device_or_absent "$meta" "$device" || return 1
  if grep -q '^pr=' "$meta"; then
    has_pr=1
  fi
  tmp=$(mktemp "$state/.fm-decision-meta.XXXXXX") || return 1
  trap 'rm -f -- "$tmp"' EXIT
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      pr=*) seen_pr=1 ;;
      decisions_reviewed=*|decision_keys=*) continue ;;
    esac
    [ "$seen_pr" -eq 1 ] || printf '%s\n' "$line" >> "$tmp" || return 1
  done < "$meta"
  printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$keys" >> "$tmp" || return 1
  if [ "$has_pr" -eq 1 ]; then
    seen_pr=0
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        pr=*) seen_pr=1 ;;
        decisions_reviewed=*|decision_keys=*) continue ;;
      esac
      [ "$seen_pr" -eq 0 ] || printf '%s\n' "$line" >> "$tmp" || return 1
    done < "$meta"
  fi
  chmod 0600 "$tmp" || return 1
  fm_pr_private_file_valid "$tmp" 600 "$device" || return 1
  if [ "$has_pr" -eq 1 ]; then
    fm_pr_metadata_identity_parse "$tmp" || return 1
  fi
  fm_pr_regular_destination_on_device_or_absent "$meta" "$device" || return 1
  mv -f -- "$tmp" "$meta"
)

origin_open_decisions() {  # <origin-id>
  local origin=$1 meta="$STATE/$1.meta" status_file="$STATE/$1.status" open kind last verb
  open=$(status_open_decisions "$status_file")
  [ -n "$open" ] || return 0
  [ -f "$meta" ] || { printf '%s' "$open"; return 0; }
  kind=$(meta_value "$meta" kind)
  [ -n "$kind" ] || kind=ship
  if [ "$kind" != secondmate ]; then
    last=$(last_status_line "$status_file")
    verb=$(status_line_verb "$last")
    case "$verb" in
      done|failed) return 0 ;;
    esac
  fi
  printf '%s' "$open"
}

body_has_resolution_record() {  # <hold-body>
  case "$1" in
    *"Resolution recorded by fm-decision-hold."*"Routed work:"*) return 0 ;;
  esac
  return 1
}

resolution_body() {  # <mode> <routed-csv> [routed-task-id...]
  local mode=$1 routed_csv=$2 body dep
  shift 2
  # Command substitution strips the trailing newline, so restore it before the
  # routed-work list to keep each entry on its own durable backlog line.
  body=$(printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: %s\nResolution mode: %s\n\nCaptain decision:\n%s\n\nRouted work:' \
    "$DECISION_DIGEST" "$routed_csv" "$mode" "$DECISION_TEXT")
  body="${body}"$'\n'
  if [ "$#" -eq 0 ]; then
    body="${body}${ROUTED_NONE}"$'\n'
  else
    for dep in "$@"; do
      body="${body}- ${dep}"$'\n'
    done
  fi
  printf '%s' "$body"
}

# tasks-axi quotes multi-entry blocked_by as "a,b,c"; strip so edge ids match.
normalized_blocked_by() {  # <show-output>
  local blocked
  blocked=$(show_field "$1" blocked_by | tr -d '[:space:]')
  blocked=${blocked#\"}
  blocked=${blocked%\"}
  printf '%s' "$blocked"
}

# Space-separated ids of live work still blocked by <hold-id>. The listing is only
# a cheap prefilter whose first field is always an unquoted id; every candidate is
# confirmed against its own authoritative record before it is reported.
tasks_blocked_by() {  # <hold-id>
  local id=$1 rows row candidate show found=''
  rows=$(tasks_axi list --fields blocked_by) \
    || fail "could not read backlog work while checking what $id still blocks"
  while IFS= read -r row; do
    case "$row" in
      *"$id"*) : ;;
      *) continue ;;
    esac
    candidate=${row%%,*}
    candidate=${candidate// /}
    [ -n "$candidate" ] || continue
    [ "$candidate" != "$id" ] || continue
    case "$candidate" in
      *[!A-Za-z0-9._-]*) continue ;;
    esac
    show=$(task_show "$candidate") || continue
    list_has_key "$(normalized_blocked_by "$show")" "$id" || continue
    found="${found}${found:+ }$candidate"
  done <<EOF
$rows
EOF
  printf '%s' "$found"
}

verify_hold_active() {  # <hold-id>
  local id=$1 show state held kind hold_kind
  show=$(task_show "$id") || fail "captain hold $id is absent from $FM_HOME/data/backlog.md"
  state=$(show_field "$show" state)
  held=$(show_field "$show" held)
  kind=$(show_field "$show" kind)
  hold_kind=$(show_field "$show" hold_kind)
  [ "$state" = queued ] || fail "captain hold $id is not queued (state=$state)"
  [ "$held" = yes ] || fail "captain hold $id is not active"
  [ "$kind" = captain ] || fail "backlog item $id is not kind captain"
  [ "$hold_kind" = captain ] || fail "backlog item $id is not held for the captain"
}

verify_hold_resolved() {  # <hold-id>
  local id=$1 show state kind body
  show=$(task_show "$id") || return 1
  state=$(show_field "$show" state)
  kind=$(show_field "$show" kind)
  body=$(show_field "$show" body)
  [ "$state" = "done" ] || return 1
  [ "$kind" = captain ] || return 1
  body_has_resolution_record "$body"
}

verify_hold_durable() {  # <hold-id>
  local id=$1 show state held kind hold_kind body
  show=$(task_show "$id") || fail "captain decision $id is absent from $FM_HOME/data/backlog.md"
  state=$(show_field "$show" state)
  held=$(show_field "$show" held)
  kind=$(show_field "$show" kind)
  hold_kind=$(show_field "$show" hold_kind)
  body=$(show_field "$show" body)
  if [ "$state" = queued ] && [ "$held" = yes ] && [ "$kind" = captain ] && [ "$hold_kind" = captain ]; then
    return 0
  fi
  if [ "$state" = "done" ] && [ "$kind" = captain ] && body_has_resolution_record "$body"; then
    return 0
  fi
  fail "captain decision $id is neither actively held nor durably resolved"
}

verify_resolution_identity() {
  local id=$1 hold_body=$2 decision_digest=$3 routed_csv=$4 resolution_prefix resolution_fields recorded_digest recorded_routes
  resolution_prefix='"Resolution recorded by fm-decision-hold.\nDecision digest: '
  case "$hold_body" in
    "$resolution_prefix"*) resolution_fields=${hold_body#"$resolution_prefix"} ;;
    *) fail "captain hold $id has no retry identity record" ;;
  esac
  case "$resolution_fields" in
    *'\nRouted identities: '*'\n\nCaptain decision:'*) : ;;
    *) fail "captain hold $id has an invalid retry identity record" ;;
  esac
  recorded_digest=${resolution_fields%%\\n*}
  resolution_fields=${resolution_fields#*\\nRouted identities: }
  recorded_routes=${resolution_fields%%\\n*}
  [ "$recorded_digest" = "$decision_digest" ] \
    || fail "captain hold $id records a different captain decision"
  [ "$recorded_routes" = "$routed_csv" ] \
    || fail "captain hold $id records different routed work"
}

command_id() {
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  hold_id "$1" "$2"
}

command_hold() {
  local origin=${1:-} key=${2:-} title='' reason='' repo='' id show state kind existing_title body
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --title) shift; title=${1:-} ;;
      --reason) shift; reason=${1:-} ;;
      --repo) shift; repo=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  validate_one_line title "$title"
  validate_one_line reason "$reason"
  case "$reason" in *'('*|*')'*) fail "reason must not contain parentheses (tasks-axi hold contract)" ;; esac
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  id=$(hold_id "$origin" "$key")
  if show=$(task_show "$id"); then
    state=$(show_field "$show" state)
    kind=$(show_field "$show" kind)
    existing_title=$(show_field "$show" title)
    [ "$state" != "done" ] || fail "captain decision $id is already durably resolved; use a new decision key for a new decision"
    [ "$kind" = captain ] || fail "existing backlog identity $id is not kind captain"
    [ "$existing_title" = "$title" ] || fail "existing captain hold $id has a different title"
  else
    if [ -z "$repo" ] && [ -f "$STATE/$origin.meta" ]; then
      repo=$(meta_value "$STATE/$origin.meta" project)
      repo=${repo%/}
      repo=${repo##*/}
    fi
    [ -n "$repo" ] || repo=firstmate
    validate_one_line repo "$repo"
    body=$(printf 'Origin: %s\nDecision key: %s\nState: awaiting captain decision.' "$origin" "$key")
    tasks_axi add "$id" "$title" --kind captain --repo "$repo" --body "$body" >/dev/null \
      || fail "could not create captain decision item $id"
  fi
  tasks_axi hold "$id" --reason "$reason" --kind captain >/dev/null \
    || fail "could not activate captain hold $id"
  verify_hold_active "$id"
  printf '%s\n' "$id"
}

command_complete() {
  local origin=${1:-} meta previous='' supplied='' keys='' key status_file open raw_open key_seen=0 has_meta=0
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  shift
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] && has_meta=1
  if [ "$has_meta" = 1 ]; then
    DECISION_META_LOCK=$(fm_meta_lock_path "$meta") || fail "could not resolve task metadata lock"
    fm_lock_acquire_wait "$DECISION_META_LOCK"
    DECISION_META_LOCK_HELD=1
    [ -f "$meta" ] || fail "task metadata disappeared while recording completion"
  fi
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  if [ "$#" -eq 1 ] && [ "$1" = --none ]; then
    supplied=''
  else
    while [ "$#" -gt 0 ]; do
      [ "$1" != --none ] || fail "--none cannot be combined with decision keys"
      validate_slug decision-key "$1"
      supplied="${supplied}${supplied:+ }$1"
      shift
    done
  fi
  if [ "$has_meta" = 1 ]; then
    previous=$(meta_value "$meta" decision_keys)
  fi
  keys=$(sorted_key_union "$previous" "$supplied")
  if [ -n "$keys" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      verify_hold_durable "$(hold_id "$origin" "$key")"
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi

  status_file="$STATE/$origin.status"
  raw_open=$(status_open_decisions "$status_file")
  open=$(origin_open_decisions "$origin")
  while IFS=$'\t' read -r key _verb _summary; do
    [ -n "$key" ] || continue
    list_has_key "$keys" "$key" \
      || fail "open structured decision $origin/$key has no captain-held inventory entry"
  done <<EOF
$open
EOF

  if [ "$has_meta" = 1 ]; then
    if [ "$(meta_value "$meta" decisions_reviewed)" != 1 ] || [ "$previous" != "$keys" ]; then
      stamp_inventory "$meta" "$keys" || fail "could not safely record decision inventory for $origin"
    fi
    fm_lock_release "$DECISION_META_LOCK"
    DECISION_META_LOCK_HELD=0

    # Transfer any still-open status decision to its durable backlog owner so the
    # live status fold does not duplicate the same Captain's Call item.
    # The transfer line is this home's own bookkeeping close, written by the
    # turn that just reviewed the decision, so it uses the guarded
    # self-announced append (bin/fm-wake-lib.sh) and does not wake this same
    # session; an append failure still fails this command loudly.
    while IFS=$'\t' read -r key _verb _summary; do
      [ -n "$key" ] || continue
      list_has_key "$keys" "$key" || continue
      transfer_rc=0
      fm_wake_status_append_self_announced "$STATE" "$status_file" \
        "captain-held [key=$key]: tracked by $(hold_id "$origin" "$key")" || transfer_rc=$?
      [ "$transfer_rc" -ne 2 ] || fail "cannot append the captain-held transfer for $origin/$key"
      key_seen=1
    done <<EOF
$raw_open
EOF
  fi
  : "$key_seen"
  printf 'complete: %s decision inventory reviewed%s\n' "$origin" "${keys:+ ($keys)}"
}

command_verify() {
  local origin=${1:-} meta reviewed keys key open
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] || fail "origin metadata is absent: $meta"
  require_tasks_axi
  reviewed=$(meta_value "$meta" decisions_reviewed)
  [ "$reviewed" = 1 ] || fail "origin $origin has no completed unresolved-decision inventory"
  keys=$(meta_value "$meta" decision_keys)
  if [ -n "$keys" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      verify_hold_durable "$(hold_id "$origin" "$key")"
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi
  open=$(origin_open_decisions "$origin")
  while IFS=$'\t' read -r key _verb _summary; do
    [ -n "$key" ] || continue
    list_has_key "$keys" "$key" \
      || fail "open structured decision $origin/$key is outside the reviewed inventory"
    verify_hold_durable "$(hold_id "$origin" "$key")"
  done <<EOF
$open
EOF
  printf 'verified: %s unresolved-decision inventory\n' "$origin"
}

command_resolve() {
  local origin=${1:-} key=${2:-} decision_file='' routed='' routed_csv id dep tmp answer_file show state blocked hold_show hold_body
  local resolution_recorded=0 legacy_replay=0 decision_text decision_digest recorded_digest recorded_routes
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision-file) shift; decision_file=${1:-} ;;
      --routed-to) shift; validate_slug routed-task "${1:-}"; routed="${routed}${routed:+ }${1:-}" ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  id=$(compose "$origin" "$key")
  [ -n "$decision_file" ] || fail "--decision-file is required"
  [ -f "$decision_file" ] || fail "decision file does not exist: $decision_file"
  [ -n "$routed" ] || fail "at least one --routed-to task is required; use answer when the captain's answer routes no work"
  routed=$(printf '%s\n' "$routed" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u | paste -sd' ' -)
  routed_csv=$(printf '%s' "$routed" | tr ' ' ',')
  decision_text=$(cat "$decision_file")
  [ -n "$decision_text" ] || fail "decision file must not be empty"
  decision_digest=$(sha256_text "$decision_text")
  hold_show=$(task_show "$id") || fail "captain decision $id does not exist in the active home"
  hold_body=$(show_field "$hold_show" body)
  case "$hold_body" in
    *"Resolution recorded by fm-decision-hold."*"Routed identities: "*)
      recorded_digest=$(recorded_field "$hold_body" "Decision digest" || true)
      recorded_routes=$(recorded_field "$hold_body" "Routed identities" || true)
      [ "$recorded_digest" = "$decision_digest" ] \
        || fail "captain decision $id records a different captain decision"
      [ "$recorded_routes" = "$routed_csv" ] \
        || fail "captain decision $id records different routed work"
      resolution_recorded=1
      legacy_replay=1
      ;;
    *"Resolution recorded by fm-captain-hold."*)
      resolution_recorded=1
      ;;
  esac
  for dep in $routed; do
    show=$(task_show "$dep") || fail "routed task $dep does not exist in the active home"
    state=$(show_field "$show" state)
    [ "$state" != "done" ] || [ "$resolution_recorded" = 1 ] \
      || fail "routed task $dep is already done"
    blocked=$(normalized_blocked_by "$show")
    list_has_key "$blocked" "$id" || [ "$resolution_recorded" = 1 ] \
      || fail "routed task $dep is not durably blocked by $id"
  done
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-decision-hold-resolve.XXXXXX") \
    || fail "cannot stage the captain decision"
  if ! { cat "$decision_file" && printf '\n\nRouted work:\n' \
    && printf '%s\n' "$routed" | tr ' ' '\n' | sed 's/^/- /'; } > "$tmp"; then
    rm -f -- "$tmp"
    fail "cannot stage the captain decision for $id"
  fi
  answer_file=$tmp
  [ "$legacy_replay" = 0 ] || answer_file=$decision_file
  if ! "$CAPTAIN_HOLD" answer "$id" --decision-file "$answer_file"; then
    rm -f -- "$tmp"
    exit 1
  fi
  rm -f -- "$tmp"
  for dep in $routed; do
    show=$(task_show "$dep") || fail "routed task $dep disappeared before routing"
    if list_has_key "$(normalized_blocked_by "$show")" "$id"; then
      FM_HOME="$FM_HOME" FM_DATA_OVERRIDE='' "$SCRIPT_DIR/fm-tasks-axi.sh" unblock "$dep" --by "$id" >/dev/null \
        || fail "could not route the recorded decision to $dep"
    fi
  done
  printf 'resolved: %s -> %s\n' "$id" "$routed"
}

command_complete() {
  local origin=${1:-} mapped=''
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  shift
  if [ "$#" -eq 1 ] && [ "$1" = --none ]; then
    exec "$CAPTAIN_HOLD" complete "$origin" --none
  fi
  for key in "$@"; do
    [ "$key" != --none ] || fail "--none cannot be combined with decision keys"
    mapped="${mapped}${mapped:+ }$(compose "$origin" "$key")"
  done
  # shellcheck disable=SC2086  # mapped is a validated space-separated slug list.
  exec "$CAPTAIN_HOLD" complete "$origin" $mapped
}

command_close() {  # <origin> <key> <flag-args...>
  local origin=${1:-} key=${2:-} id
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  id=$(compose "$origin" "$key")
  shift 2
  local decision_file=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision-file) shift; decision_file=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  exec "$CAPTAIN_HOLD" answer "$id" --decision-file "$decision_file"
}

command_hold() {
  local origin=${1:-} key=${2:-} id
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  id=$(compose "$origin" "$key")
  shift 2
  exec "$CAPTAIN_HOLD" hold "$id" --origin "$origin" "$@"
}

case "${1:-}" in
  id) shift; [ "$#" -eq 2 ] || { usage >&2; exit 2; }; compose "$1" "$2"; printf '\n' ;;
  hold) shift; command_hold "$@" ;;
  complete) shift; command_complete "$@" ;;
  verify) shift; exec "$CAPTAIN_HOLD" verify "$@" ;;
  resolve) shift; command_resolve "$@" ;;
  answer|decline|repair) shift; command_close "$@" ;;
  answers) shift; exec "$CAPTAIN_HOLD" answers "$@" ;;
  bind) shift; exec "$CAPTAIN_HOLD" bind "$@" ;;
  unbind) shift; exec "$CAPTAIN_HOLD" unbind "$@" ;;
  binding) shift; exec "$CAPTAIN_HOLD" binding "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
