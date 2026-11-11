#!/usr/bin/env bash
# fm-claude-account.sh - choose which declared Claude account a Claude spawn
# from this home should launch on, with the quota evidence for every account.
#
# Usage: fm-claude-account.sh pick [--model <claude-model>]
#        fm-claude-account.sh --help
#
# Reads this home's config/claude-account (FM_CONFIG_OVERRIDE, else
# $FM_HOME/config) through bin/fm-worker-account-lib.sh, which owns the pool
# format and refuses a malformed pool or cap map. Without the file, or with one
# line and no config/claude-account-caps, there is nothing to choose: pick
# prints that account (`none` without a file, meaning spawn without --account)
# and exits 0 without running quota-axi.
#
# Otherwise pick reads quota-axi once through fm_worker_account_claude_snapshot
# in bin/fm-worker-account-lib.sh, which owns that bounded call, and binds each
# declared entry to at most one schema-6 claude lane with
# quota_claude_entry_lane in bin/fm-quota-axi-lib.sh, which owns the
# accountLocator matching. A path containing ':' cannot be named in
# QUOTA_AXI_CLAUDE_PROFILES and stays unmeasured.
#
# Quota is per account, not per machine. A lane quota-axi cannot read here (for
# example a keychain locked to this session) is measured from a recent reading
# of the same account when fm_quota_reuse_readings in bin/fm-quota-axi-lib.sh
# accepts one: a `fresh` lane at the same path, younger than
# FM_CLAUDE_QUOTA_READING_MAX_AGE (600 s default), with a matching account
# identity, read from FM_CLAUDE_QUOTA_READINGS (default
# $HOME/.local/state/quota-axi-refresh/*.json). A live fresh lane always wins.
# The lane line and basis then end `via reading <file> refreshedAt <time>`.
#
# The applicable scope is the lane's `model:<model>` row when --model names a
# model quota-axi reports for that lane, else the one family scope that
# quota_family_scope in bin/fm-quota-axi-lib.sh evidences for that id (a full
# claude-fable-* id reads quota-axi's `model:fable` window, because quota-axi names
# the window by the vendor's model id, not by the full model name), else its
# `all_models` row. A lane that fell back to `all_models` for a named model says
# so on its lane line, never silently. A lane is
#   eligible    its state is fresh, the scope is known, effectivePercentRemaining
#               is above zero, and runway is not exhausted_now;
#   exhausted   fresh and known, but at zero remaining or exhausted_now;
#   unmeasured  anything else: no matching lane, no locator, a non-fresh state,
#               no applicable or no known scope, or no usable quota-axi output;
#   capped      config/claude-account-caps caps it, and its weekly use, read
#               exactly as the launch-time cap reads it (quota_claude_weekly),
#               is unknown or at or over that cap, so a launch would refuse
#               it. A capped entry is never chosen, not even as the
#               unmeasured default.
# Eligible lanes rank by the highest known spendPriority, ahead of eligible
# lanes whose spendPriority is unknown; an exact tie goes to the earliest
# resetsAt (the first limiting window's reset, as quota-axi's TOON shows it),
# then to the earlier line in the file. With no eligible lane, the first
# unmeasured entry in file order is chosen and marked as an unmeasured
# default, never silently; when every entry is exhausted or capped, nothing is
# chosen.
#
# Output (stdout): one `lane:` evidence line per declared entry in file order
# (entry, accountKey or `unmeasured`, scope, effectivePercentRemaining,
# spendPriority, runway, resetsAt, verdict, and reason), one `basis:` line,
# and finally `account: <entry>` naming the exact line to pass to
# bin/fm-spawn.sh --account. The exhausted outcome prints no account line.
#
# Exit status: 0 an account was named; 1 the pool or its configuration was
# refused (the error names the file); 2 usage error; 3 every declared account
# is measured and exhausted or capped, so the caller must report instead of
# spawning.
# FM_QUOTA_AXI_MIN is not raised for this helper: an older quota-axi without
# account lanes or locators simply yields the disclosed unmeasured default.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
FM_CLAUDE_ACCOUNT_EXHAUSTED_EXIT=3

# shellcheck source=bin/fm-worker-account-lib.sh
. "$SCRIPT_DIR/fm-worker-account-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

die_usage() {
  printf 'error: %s\n' "$1" >&2
  echo "usage: fm-claude-account.sh pick [--model <claude-model>]" >&2
  exit 2
}

case "${1:-}" in
-h | --help | help)
  usage
  exit 0
  ;;
pick) shift ;;
'') die_usage "a subcommand is required" ;;
*) die_usage "unknown subcommand: $1" ;;
esac

MODEL=
while [ "$#" -gt 0 ]; do
  case "$1" in
  --model)
    [ -n "${2:-}" ] || die_usage "--model requires a value"
    MODEL=$2
    shift 2
    ;;
  --model=*)
    MODEL=${1#--model=}
    [ -n "$MODEL" ] || die_usage "--model requires a value"
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *) die_usage "unexpected argument: $1" ;;
  esac
done
[ "$MODEL" != default ] || MODEL=

ENTRIES=$(fm_worker_account_entries claude "$CONFIG") || exit 1
if [ -z "$ENTRIES" ]; then
  echo "basis: this home has no config/claude-account, so Claude workers launch unpinned; spawn without --account"
  echo "account: none"
  exit 0
fi
DECLARED=()
while IFS= read -r line; do
  DECLARED+=("${line%%$'\t'*}")
done <<EOF_ENTRIES
$ENTRIES
EOF_ENTRIES
CAPS=$(fm_worker_account_cap_map "$CONFIG" "$(printf '%s\n' "${DECLARED[@]}")") || exit 1
if [ "${#DECLARED[@]}" -eq 1 ] && [ -z "$CAPS" ]; then
  echo "basis: config/claude-account declares one account, so there is nothing to choose"
  echo "account: ${DECLARED[0]}"
  exit 0
fi
CAPS_JSON=$(printf '%s\n' "$CAPS" | jq -R 'select(length > 0) | split("\t") | {key: .[0], value: (.[1] | tonumber)}' | jq -s from_entries) || {
  echo "error: could not read config/claude-account-caps" >&2
  exit 1
}

fm_worker_account_claude_snapshot "${DECLARED[@]}"
SNAPSHOT=$FM_WORKER_ACCOUNT_SNAPSHOT
GLOBAL_REASON=$FM_WORKER_ACCOUNT_SNAPSHOT_REASON
MAX_AGE=$(fm_worker_account_cap_max_age)

DECLARED_JSON=$(printf '%s\n' "${DECLARED[@]}" | jq -R . | jq -s .)

# One jq pass owns lane binding, classification, and ranking, so the evidence
# printed and the choice made always come from the same reading.
# shellcheck disable=SC2016  # jq program text, not shell expansion.
RESULT=$(printf '%s\n' "$SNAPSHOT" | jq -r \
  --argjson declared "$DECLARED_JSON" \
  --arg model "$MODEL" \
  --arg home "${HOME:-}" \
  --arg global "$GLOBAL_REASON" \
  --argjson caps "$CAPS_JSON" \
  --argjson max_age "$MAX_AGE" "$FM_QUOTA_ROW_JQ"'
  def str: if . == null then "unknown" else tostring end;
  [.providers[]? | select(.provider == "claude" and (.accountKey | type) == "string")] as $lanes |
  def lane($e): quota_claude_entry_lane($lanes; $e; $home);
  def scope_of($row):
    ($row.quotaSemantics.effectiveAvailability // []) as $s |
    quota_family_scope("claude"; $model) as $family |
    (if $model != "" then
       (([$s[] | select(.scope == ("model:" + $model))] | first) //
        (if $family != "" then ([$s[] | select(.scope == $family)] | first) else null end))
     else null end)
    // ([$s[] | select(.scope == "all_models")] | first);
  def reset_of($row; $sc):
    [($sc.limitingWindowIds // [])[] as $id | ($row.windows // [])[] |
      select(.id == $id) | (.resetsAt // empty)] | first;
  [range(0; $declared | length) as $i | $declared[$i] as $e | lane($e) as $row |
    (if $row == null then null else scope_of($row) end) as $sc |
    (if $caps[$e] == null then null
     elif $row == null and $global != "" then {used: null, why: $global}
     else quota_claude_weekly($row; $max_age) end) as $wk |
    {idx: $i, entry: $e,
     fallback: ($model != "" and $sc != null and $sc.scope == "all_models"),
     key: ($row.accountKey // "unmeasured"),
     scope: ($sc.scope // "none"),
     epr: $sc.effectivePercentRemaining,
     sp: $sc.selection.spendPriority?,
     runway: $sc.runway.status?,
     resets: (if $sc == null then null else reset_of($row; $sc) end),
     via: (if $row.quotaReuse? == null then null
       else "via reading \($row.quotaReuse.file) refreshedAt \($row.quotaReuse.refreshedAt)" end)} |
    if $wk != null and ($wk.used == null or $wk.used >= $caps[$e]) then
      .verdict = "capped" |
      .reason = "config/claude-account-caps caps it at \($caps[$e])% weekly use for new launches, and its weekly use is \(if $wk.used == null then "unknown" else "at or over that" end): \($wk.why)"
    elif $row == null then
      .verdict = "unmeasured" |
      .reason = (if $global != "" then $global
        elif ($e | contains(":")) and $e != "ordinary" then "a path containing : cannot be named in QUOTA_AXI_CLAUDE_PROFILES"
        elif ($lanes | length) == 0 then "quota-axi reported no Claude account lanes"
        else "no quota-axi lane carries a locator for this account" end)
    elif ($row.state.status? // "unknown") != "fresh" then
      .verdict = "unmeasured" | .reason = "lane status is \($row.state.status? // "unknown")"
    elif $sc == null then
      .verdict = "unmeasured" | .reason = "the lane reports no all_models scope"
    elif $sc.status != "known" or (.epr | type) != "number" then
      .verdict = "unmeasured" | .reason = "the \(.scope) scope is not measured"
    elif .epr <= 0 or .runway == "exhausted_now" then
      .verdict = "exhausted" | .reason = "no allowance left in the \(.scope) scope"
    else
      .verdict = "eligible" |
      .reason = (if (.sp | type) == "number" then "fresh and measured" else "fresh and measured; spendPriority unknown" end)
    end |
    if .via == null then . else .reason += " " + .via end
  ] as $rows |
  ($rows[] | ["lane", .idx, .key, .scope, (.epr | str), (.sp | str), (.runway | str), (.resets | str), .verdict,
    (.reason + (if .fallback then "; \($model) has no quota-axi model scope on this lane, so all_models applied" else "" end))] | @tsv),
  ([$rows[] | select(.verdict == "eligible")] |
    sort_by([(if (.sp | type) == "number" then 0 else 1 end), (if (.sp | type) == "number" then -.sp else 0 end), (.resets // "~"), .idx])) as $eligible |
  if ($eligible | length) > 0 then
    $eligible[0] as $best | ($eligible[1] // null) as $next |
    (if ($best.sp | type) != "number" then
       "no eligible account reports spendPriority, so the earliest resetsAt, then the earlier line, decided"
     elif $next != null and $next.sp == $best.sp then
       (if $next.resets != $best.resets then "highest spendPriority \($best.sp), tied and broken by the earliest resetsAt"
        else "highest spendPriority \($best.sp), tied and broken by the earlier line in config/claude-account" end)
     else "highest spendPriority \($best.sp) among \($eligible | length) eligible account(s)" end) as $core |
    ($core + (if $best.via == null then "" else "; the chosen lane was measured " + $best.via end)) as $why |
    ["choice", $best.idx, $why] | @tsv
  elif ([$rows[] | select(.verdict == "unmeasured")] | length) > 0 then
    ([$rows[] | select(.verdict == "unmeasured")] | first) as $first |
    ["choice", $first.idx, "UNMEASURED DEFAULT: no account is measurably eligible (\($first.reason)), so the first unmeasured line in config/claude-account is used without quota evidence"] | @tsv
  else
    (if ([$rows[] | select(.verdict == "capped")] | length) > 0
     then "no declared Claude account is eligible: each is measured and exhausted or not under its weekly-use cap in config/claude-account-caps; report instead of spawning"
     else "every declared Claude account is measured and exhausted; report instead of spawning" end) as $why |
    ["exhausted", "-", $why] | @tsv
  end
') || {
  echo "error: could not evaluate the quota-axi snapshot for config/claude-account" >&2
  exit 1
}

rc=0
while IFS=$'\t' read -r kind f1 f2 f3 f4 f5 f6 f7 f8 f9; do
  case "$kind" in
  lane)
    echo "lane: ${DECLARED[$f1]} accountKey=$f2 scope=$f3 effectivePercentRemaining=$f4 spendPriority=$f5 runway=$f6 resetsAt=$f7 verdict=$f8 ($f9)"
    ;;
  choice)
    echo "basis: $f2"
    echo "account: ${DECLARED[$f1]}"
    ;;
  exhausted)
    echo "basis: $f2"
    rc=$FM_CLAUDE_ACCOUNT_EXHAUSTED_EXIT
    ;;
  esac
done <<EOF_RESULT
$RESULT
EOF_RESULT
exit "$rc"
