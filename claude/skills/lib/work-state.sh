#!/usr/bin/env bash
# work-state.sh — deterministic gather of my merged/open PRs for a project.
# Sourceable (exposes ws_* functions) and executable (runs main).
set -uo pipefail

: "${GH:=gh}"               # override for tests
: "${WORK_STATE_NOW:=}"     # epoch override for tests; empty = real now

ws_require_deps() {
  command -v jq >/dev/null 2>&1 || { echo "work-state: jq is required" >&2; return 2; }
}

# Echo the canonical repo root for DIR (default cwd).
#   main + linked worktree -> the main repo root (SHARED .git via --git-common-dir)
#   submodule              -> the submodule's OWN working root (--show-toplevel),
#                             because its git-common-dir is <super>/.git/modules/<n>
#                             whose parent is not a working tree
#   bare repo              -> unsupported: warn + return 4 (skip)
#   not a git repo         -> return 2
ws_canonical_key() {
  local dir="${1:-.}" common
  common="$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null)" || {
    echo "work-state: not a git repo: $dir" >&2; return 2; }
  if [ "$(git -C "$dir" rev-parse --is-bare-repository 2>/dev/null)" = "true" ]; then
    echo "work-state: bare repo unsupported, skipping: $dir" >&2; return 4
  fi
  case "$common" in /*) : ;; *) common="$dir/$common" ;; esac
  common="$(realpath "$common")"
  case "$common" in
    */.git/modules/*) realpath "$(git -C "$dir" rev-parse --show-toplevel)" || return 1 ;;
    *) realpath "$(dirname "$common")" || return 1 ;;
  esac
}

# Echo the config block whose repo_paths contains KEY (trailing slash tolerated).
# Code 2 = invalid/unreadable JSON; code 3 = no matching block.
ws_select_config() {
  local key cfg="${2:-$HOME/.claude/reconcile/projects.json}"
  key="$(realpath "$1" 2>/dev/null || echo "$1")"
  [ -r "$cfg" ] || { echo "work-state: no config at $cfg" >&2; return 3; }
  jq -e . "$cfg" >/dev/null 2>&1 || { echo "work-state: invalid JSON in $cfg" >&2; return 2; }
  jq -e --arg k "$key" '
    to_entries
    | map(select(.value.repo_paths | map(sub("/$";"")) | index($k)))
    | .[0].value // empty' "$cfg" \
    || { echo "work-state: no config block matches $key" >&2; return 3; }
}

ws_iso_to_epoch() {  # "YYYY-MM-DDTHH:MM:SSZ" -> epoch
  local ts="$1"
  date -u -d "$ts" +%s 2>/dev/null \
    || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null
}
ws_epoch_to_iso() {  # epoch -> "YYYY-MM-DDTHH:MM:SSZ" (tests/fixtures)
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}
ws_in_window() {  # TS WINDOW_DAYS [NOW] -> 0 if within window, else 1
  local ts_e now="${3:-$(date +%s)}"
  ts_e="$(ws_iso_to_epoch "$1")" || return 1
  [ "$ts_e" -ge $(( now - ${2} * 86400 )) ]
}

# Args: repos_json window_days now_epoch.
# Emits {merged,open,truncated,gh_ok,partial,errors}. Merged AND open PRs carry
# body for Jira-key matching (branch/title/body); open PRs also carry mergeable +
# statusCheckRollup so /reconcile can flag "review-ready" (not failing-checks AND
# not merge-conflicted) and untracked PRs (body key match).
# gh_ok=false ONLY when gh auth itself fails (whole source down); a single repo
# query that errors is surfaced in errors[] with partial=true, never dropped.
ws_gather_github() {
  local repos="$1" window="$2" now="${3:-$(date +%s)}" cap="${WS_GH_CAP:-200}"
  if ! "$GH" api user --jq .login >/dev/null 2>&1; then
    echo '{"merged":[],"open":[],"truncated":false,"gh_ok":false,"partial":false,"errors":[]}'
    return 0
  fi
  local merged='[]' open='[]' truncated=false errors='[]' repo raw rc
  while IFS= read -r repo; do
    raw="$("$GH" pr list -R "$repo" --author @me --state merged --limit "$cap" \
      --json number,title,headRefName,mergedAt,url,body)"; rc=$?
    if [ "$rc" -ne 0 ]; then
      errors="$(jq -c --argjson e "$errors" --arg r "$repo" '$e + [{repo:$r,source:"merged"}]' <<<'null')"
    else
      [ "$(jq 'length' <<<"$raw")" -ge "$cap" ] && truncated=true
      merged="$(jq -c --argjson m "$merged" --arg repo "$repo" --argjson now "$now" --argjson w "$window" '
        $m + ([ .[] | select(.mergedAt != null)
                | select(((($now) - (.mergedAt | fromdateiso8601)) / 86400) <= $w)
                | . + {repo:$repo} ])' <<<"$raw")"
    fi
    raw="$("$GH" pr list -R "$repo" --author @me --state open --limit "$cap" \
      --json number,title,headRefName,mergedAt,url,isDraft,body,mergeable,statusCheckRollup)"; rc=$?
    if [ "$rc" -ne 0 ]; then
      errors="$(jq -c --argjson e "$errors" --arg r "$repo" '$e + [{repo:$r,source:"open"}]' <<<'null')"
    else
      [ "$(jq 'length' <<<"$raw")" -ge "$cap" ] && truncated=true
      open="$(jq -c --argjson o "$open" --arg repo "$repo" '$o + ([ .[] | . + {repo:$repo} ])' <<<"$raw")"
    fi
  done < <(jq -r '.[]' <<<"$repos")
  local partial=false
  [ "$(jq 'length' <<<"$errors")" -gt 0 ] && partial=true
  jq -c -n --argjson merged "$merged" --argjson open "$open" --argjson t "$truncated" \
    --argjson partial "$partial" --argjson errors "$errors" \
    '{merged:$merged, open:$open, truncated:$t, gh_ok:true, partial:$partial, errors:$errors}'
}

ws_main() {
  ws_require_deps || return $?
  local repo="." cfg="$HOME/.claude/reconcile/projects.json" now=""
  while [ $# -gt 0 ]; do case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --config) cfg="$2"; shift 2 ;;
    --now) now="$2"; shift 2 ;;
    *) echo "work-state: unknown arg $1" >&2; return 2 ;;
  esac; done
  [ -n "$now" ] && WORK_STATE_NOW="$now"
  local key block name repos window
  key="$(ws_canonical_key "$repo")" || return $?
  block="$(ws_select_config "$key" "$cfg")" || return $?   # codes 2/3 bubble up
  name="$(jq -r --arg k "$key" 'to_entries|map(select(.value.repo_paths|map(sub("/$";""))|index($k)))|.[0].key' "$cfg")"
  repos="$(jq -c '.github_repos // []' <<<"$block")"
  window="$(jq -r '.merged_window_days // 9' <<<"$block")"
  local gh; gh="$(ws_gather_github "$repos" "$window" "${WORK_STATE_NOW:-$(date +%s)}")"
  jq -c -n --arg name "$name" --argjson cfg "$block" --argjson gh "$gh" \
    '{project:$name, config:$cfg, github:$gh}'
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then ws_main "$@"; fi
