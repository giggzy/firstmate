#!/usr/bin/env bash
#
# <xbar.title>Quota Usage</xbar.title>
# <xbar.version>1.0.0</xbar.version>
# <xbar.desc>Menu bar summary of Anthropic (Claude), OpenAI (Codex), and GitHub Copilot quota-axi windows.</xbar.desc>
# <xbar.dependencies>quota-axi,jq</xbar.dependencies>
# <xbar.abouturl>https://github.com/kunchenguid/quota-axi</xbar.abouturl>
#
# SwiftBar (https://swiftbar.app) / xbar (https://xbarapp.com) plugin.
# Drop this file into your SwiftBar/xbar plugins folder; the ".5m." segment
# of the filename sets a 5-minute refresh interval (rename to change it).
#
# Requires quota-axi >= 0.1.17 (https://github.com/kunchenguid/quota-axi)
# and jq on PATH.
#
# Kiro is intentionally not shown: quota-axi has no "kiro" provider and
# kiro-cli exposes no usage/quota subcommand, only a web dashboard.
# Do not add a Kiro scraper here without a real local API/CLI surface to
# read from - there wasn't one as of this writing.
#
# GitHub Copilot's numbers are shown with an explicit "unverified" flag and
# never feed the menu-bar color/summary line: quota-axi's own output already
# declines to compute an effective remaining percentage for Copilot, because
# the windows it reads all came back with an epoch (1970) reset timestamp -
# a strong sign the underlying data is incomplete, not that the account is
# genuinely untouched. Treat Copilot here as "reported, not trusted."

set -u

QUOTA_AXI_BIN="${QUOTA_AXI_BIN:-quota-axi}"

# --- fallbacks: always print at least one menu-bar line + one dropdown line,
# even on total failure, so the plugin never renders as blank/missing. ------

fail() {
  printf '%s\n' "$1"
  echo "---"
  printf '%s\n' "$2"
  exit 0
}

if ! command -v "$QUOTA_AXI_BIN" >/dev/null 2>&1; then
  fail "Quota: not installed ⚠️ | color=red" \
    "quota-axi not found on PATH -- install: npm install -g quota-axi | color=gray"
fi

if ! command -v jq >/dev/null 2>&1; then
  fail "Quota: jq missing ⚠️ | color=red" \
    "jq is required to parse quota-axi output -- install: brew install jq | color=gray"
fi

json="$("$QUOTA_AXI_BIN" --json --allow-keychain-prompt 2>/dev/null || true)"

if [ -z "$json" ] || ! printf '%s' "$json" | jq -e . >/dev/null 2>&1; then
  fail "Quota: no data ⚠️ | color=red" \
    "quota-axi --json returned no parseable output -- run it in a terminal to see the raw error | color=gray"
fi

# --- helpers -----------------------------------------------------------

color_for_pct() {
  local pct="${1%%.*}"
  if [ -z "$pct" ]; then
    echo gray
  elif [ "$pct" -ge 50 ]; then
    echo green
  elif [ "$pct" -ge 20 ]; then
    echo orange
  else
    echo red
  fi
}

# Effective all-models remaining percentage quota-axi is willing to vouch
# for, or empty when it has none (auth issues, or a provider like Copilot
# where quota-axi itself won't compute one).
effective_pct() {
  jq -r --arg p "$1" '
    [.providers[]? | select(.provider == $p) |
      (.quotaSemantics.effectiveAvailability[]? | select(.scope == "all_models") | .effectivePercentRemaining)
    ] | first // empty
  ' <<<"$json"
}

provider_status() {
  jq -r --arg p "$1" '.providers[]? | select(.provider == $p) | .state.status // "unknown"' <<<"$json"
}

provider_error() {
  jq -r --arg p "$1" '.providers[]? | select(.provider == $p) | .state.error // empty' <<<"$json"
}

# Tab-separated id/label/percentRemaining/resetsAt rows for every window a
# provider reports, one per line.
provider_windows() {
  jq -r --arg p "$1" '
    .providers[]? | select(.provider == $p) | .windows[]? |
    [(.id // ""), (.label // ""), (if .percentRemaining == null then "" else (.percentRemaining | tostring) end), (.resetsAt // "")] | @tsv
  ' <<<"$json"
}

print_windows() {
  local provider="$1" line_prefix="$2" trust_color="$3"
  local id label pct resets shown=0
  while IFS=$'\t' read -r id label pct resets; do
    [ -z "$id" ] && continue
    shown=1
    local disp="${label:-$id}"
    if [ -n "$pct" ]; then
      if [ "$trust_color" = "yes" ]; then
        printf '%s%s: %s%% remaining | color=%s\n' "$line_prefix" "$disp" "$pct" "$(color_for_pct "$pct")"
      else
        printf '%s%s: %s%% remaining (unverified) | color=gray\n' "$line_prefix" "$disp" "$pct"
      fi
    else
      printf '%s%s: no percentage reported | color=gray\n' "$line_prefix" "$disp"
    fi
    if [ -n "$resets" ] && [ "$resets" != "1970-01-01T00:00:00.000Z" ]; then
      printf '%s  resets %s | color=gray\n' "$line_prefix" "$resets"
    fi
  done < <(provider_windows "$provider")
  [ "$shown" -eq 0 ] && printf '%sno windows reported | color=gray\n' "$line_prefix"
}

# --- gather trusted providers (Claude, Codex) for the summary line -----

claude_pct="$(effective_pct claude)"
codex_pct="$(effective_pct codex)"

summary="Q"
worst=101
for pct in "$claude_pct" "$codex_pct"; do
  if [ -n "$pct" ]; then
    int_pct="${pct%%.*}"
    [ "$int_pct" -lt "$worst" ] && worst="$int_pct"
  fi
done

if [ -n "$claude_pct" ]; then
  summary="$summary C:${claude_pct%%.*}%"
else
  summary="$summary C:–"
fi
if [ -n "$codex_pct" ]; then
  summary="$summary O:${codex_pct%%.*}%"
else
  summary="$summary O:–"
fi

if [ "$worst" -le 100 ]; then
  summary_color="$(color_for_pct "$worst")"
else
  summary_color=gray
fi

printf '%s | color=%s\n' "$summary" "$summary_color"
echo "---"

# --- Claude (Anthropic) -------------------------------------------------

claude_status="$(provider_status claude)"
if [ -n "$claude_pct" ]; then
  printf 'Claude: %s%% remaining | color=%s\n' "$claude_pct" "$(color_for_pct "$claude_pct")"
elif [ "$claude_status" = "auth_required" ]; then
  printf 'Claude: sign-in required | color=red\n'
else
  err="$(provider_error claude)"
  printf 'Claude: %s | color=orange\n' "${err:-status unknown}"
fi
print_windows claude "--" yes

# --- OpenAI (Codex) -------------------------------------------------

codex_status="$(provider_status codex)"
if [ -n "$codex_pct" ]; then
  printf 'OpenAI (Codex): %s%% remaining | color=%s\n' "$codex_pct" "$(color_for_pct "$codex_pct")"
elif [ "$codex_status" = "auth_required" ]; then
  printf 'OpenAI (Codex): sign-in required | color=red\n'
else
  err="$(provider_error codex)"
  printf 'OpenAI (Codex): %s | color=orange\n' "${err:-status unknown}"
fi
print_windows codex "--" yes

# --- GitHub Copilot (unverified) ----------------------------------------

copilot_status="$(provider_status copilot)"
if [ "$copilot_status" = "auth_required" ]; then
  printf 'GitHub Copilot: sign-in required | color=red\n'
elif [ "$copilot_status" = "fresh" ]; then
  printf 'GitHub Copilot: reported, unverified | color=gray\n'
else
  err="$(provider_error copilot)"
  printf 'GitHub Copilot: %s | color=orange\n' "${err:-status unknown}"
fi
print_windows copilot "--" no

# --- Kiro note -----------------------------------------------------------

echo "---"
echo "Kiro: no local usage API -- check the Kiro web dashboard | color=gray"

# --- footer ---------------------------------------------------------------

echo "---"
generated_at="$(jq -r '.generatedAt // empty' <<<"$json")"
[ -n "$generated_at" ] && printf 'Data as of %s | color=gray\n' "$generated_at"
echo "Refresh | refresh=true"
