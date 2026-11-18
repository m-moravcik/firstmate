#!/usr/bin/env bash
# Behavior tests for bin/fm-claude-account.sh pick: choosing which declared
# line of a config/claude-account pool a Claude spawn launches on.
#
# A stub quota-axi on PATH answers with fixture JSON shaped like quota-axi's
# schema-6 `--provider claude --full --json` output (per-account lanes, each
# with an accountLocator) and records the environment and arguments it was
# called with, so every case asserts on the helper's public output, exit
# status, and the one quota-axi call it makes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PICK="$ROOT/bin/fm-claude-account.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-account)
FAKEBIN="$TMP_ROOT/fakebin"
CFG="$TMP_ROOT/config"
FAKE_HOME="$TMP_ROOT/home"
WORK="$TMP_ROOT/claude-work"
MON="$TMP_ROOT/claude-monivio"
SNAPSHOT="$TMP_ROOT/snapshot.json"
CALLS="$TMP_ROOT/quota-calls"
READINGS="$TMP_ROOT/readings"
mkdir -p "$FAKEBIN" "$CFG" "$FAKE_HOME/.claude" "$WORK" "$MON" "$READINGS"

cat > "$FAKEBIN/quota-axi" <<SH
#!/usr/bin/env bash
printf 'CLAUDE_CONFIG_DIR=%s PROFILES=%s ARGS=%s\n' "\${CLAUDE_CONFIG_DIR-unset}" "\${QUOTA_AXI_CLAUDE_PROFILES-unset}" "\$*" >> '$CALLS'
[ -f '$SNAPSHOT' ] || exit 1
cat '$SNAPSHOT'
SH
chmod +x "$FAKEBIN/quota-axi"

DEFAULT_STORE='Claude Code-credentials'

# lane <accountKey> <path> <keychainService> <all_models epr> <spendPriority> <runway> <resetsAt> [<model> <epr> <spendPriority> <runway>]
# Prints one schema-6 claude lane. An empty spendPriority publishes an
# unknown selection; `-` as the path omits the accountLocator entirely.
lane() {
  jq -n --arg key "$1" --arg path "$2" --arg kc "$3" --argjson epr "$4" --arg sp "$5" \
    --arg runway "$6" --arg reset "$7" --arg model "${8:-}" --arg mepr "${9:-0}" \
    --arg msp "${10:-}" --arg mrunway "${11:-}" '
    def sel($s): if $s == "" then {status: "unknown"} else {status: "known", spendPriority: ($s | tonumber)} end;
    {provider: "claude", accountKey: $key,
     state: {status: "fresh", stale: false},
     windows: [{id: "five_hour", resetsAt: $reset}, {id: "model:x", resetsAt: "2026-12-31T00:00:00Z"}],
     quotaSemantics: {status: "known", effectiveAvailability: (
       [{scope: "all_models", status: "known", effectivePercentRemaining: $epr, boundedBy: ["five_hour"],
         limitingWindowIds: ["five_hour"], runway: {status: $runway}, selection: sel($sp)}] +
       (if $model == "" then [] else
         [{scope: ("model:" + $model), status: "known", effectivePercentRemaining: ($mepr | tonumber),
           boundedBy: ["five_hour", "model:x"], limitingWindowIds: ["model:x"],
           runway: {status: $mrunway}, selection: sel($msp)}] end))}}
    + (if $path == "-" then {} else
        {accountLocator: ({kind: "config-dir", path: $path} + (if $kc == "" then {} else {keychainService: $kc} end))} end)'
}

# snapshot <schemaVersion> <lane-json>...
snapshot() {
  local schema=$1
  shift
  printf '%s\n' "$@" | jq -s --argjson schema "$schema" '{schemaVersion: $schema, providers: .}' > "$SNAPSHOT"
}

pool() {
  printf '%s\n' "$@" > "$CFG/claude-account"
}

# pick [args...]: run the helper from a caller whose own CLAUDE_CONFIG_DIR
# names another account, which quota-axi must never inherit.
pick() {
  : > "$CALLS"
  env HOME="$FAKE_HOME" PATH="$FAKEBIN:$PATH" FM_CONFIG_OVERRIDE="$CFG" \
    CLAUDE_CONFIG_DIR="$TMP_ROOT/ambient" "$PICK" pick "$@" 2>&1
}

# stale_lane <accountKey> <path> <keychainService> [<accountId>]
# A lane quota-axi could not read here: stale, no measured scope.
stale_lane() {
  lane "$1" "$2" "$3" 0 "" unknown 2026-10-11T15:00:00Z | jq --arg id "${4:-}" '
    .state = {status: "stale", stale: true, reason: "keychain_access_denied"} |
    .quotaSemantics = {status: "unknown", effectiveAvailability: []} |
    if $id == "" then . else .account = {accountId: $id} end'
}

# reading_lane <accountKey> <path> <keychainService> <epr> <spendPriority> <age seconds> [<identity-json>]
# A fresh lane as another quota-axi left it, refreshed <age> seconds ago.
reading_lane() {
  local at
  at=$(jq -nr --argjson age "$6" '(now - $age | floor) | strftime("%Y-%m-%dT%H:%M:%S.000Z")')
  lane "$1" "$2" "$3" "$4" "$5" through_reset 2026-10-11T15:00:00Z | jq --arg at "$at" --argjson id "${7:-null}" '
    .state.refreshedAt = $at | if $id == null then . else .account = $id end'
}

# reading <file> <lane-json>...: write a quota-axi reading file under $READINGS.
reading() {
  local file=$1
  shift
  printf '%s\n' "$@" | jq -s '{schemaVersion: 6, providers: .}' > "$READINGS/$file"
}

clear_readings() {
  rmdir "${READINGS:?}"/*.json 2>/dev/null || true
  rm -f "${READINGS:?}"/*
}

# reuse_pick: pick with the reading list pointed at $READINGS.
reuse_pick() {
  FM_CLAUDE_QUOTA_READINGS="${FM_CLAUDE_QUOTA_READINGS-$READINGS/*.json}" pick
}

test_two_measured_lanes_pick_the_highest_spend_priority() {
  local out rc
  pool ordinary "$WORK" "$MON"
  snapshot 6 \
    "$(lane profile:home "$FAKE_HOME/.claude" "$DEFAULT_STORE" 60 0.2 through_reset 2026-10-11T15:00:00Z)" \
    "$(lane profile:work "$WORK" "$DEFAULT_STORE-1a2b3c4d" 40 0.6 through_reset 2026-10-11T16:00:00Z)" \
    "$(lane profile:mon "$MON" "$DEFAULT_STORE-5e6f7a8b" 90 0.4 through_reset 2026-10-11T14:00:00Z)"
  out=$(pick); rc=$?
  expect_code 0 "$rc" "a measured pool should yield a choice: $out"
  assert_contains "$out" "lane: ordinary accountKey=profile:home scope=all_models effectivePercentRemaining=60 spendPriority=0.2 runway=through_reset" \
    "the ordinary entry should carry its own lane's evidence"
  assert_contains "$out" "lane: $MON accountKey=profile:mon" "every declared entry should have an evidence line"
  assert_contains "$out" "basis: highest spendPriority 0.6" "the basis should name the ranking scalar"
  assert_equals "account: $WORK" "$(printf '%s\n' "$out" | tail -1)" "the last line should name the highest spendPriority account"
  assert_equals 1 "$(wc -l < "$CALLS" | tr -d ' ')" "quota-axi should run exactly once"
  assert_equals "CLAUDE_CONFIG_DIR=unset PROFILES=$WORK:$MON ARGS=--provider claude --full --json" "$(cat "$CALLS")" \
    "quota-axi should run without the caller's CLAUDE_CONFIG_DIR and with every path entry as a profile"
  pass "pick ranks measured lanes by spendPriority and runs quota-axi once with the pool's paths"
}

test_model_scope_row_is_used_when_reported() {
  local out rc
  pool ordinary "$WORK"
  snapshot 6 \
    "$(lane profile:home "$FAKE_HOME/.claude" "$DEFAULT_STORE" 60 0.2 through_reset 2026-10-11T15:00:00Z)" \
    "$(lane profile:work "$WORK" "$DEFAULT_STORE-1a2b3c4d" 80 0.7 through_reset 2026-10-11T16:00:00Z \
      claude-opus-5 0 -1 exhausted_now)"
  out=$(pick --model claude-opus-5); rc=$?
  expect_code 0 "$rc" "a model-scoped pick should still choose: $out"
  assert_contains "$out" "lane: $WORK accountKey=profile:work scope=model:claude-opus-5 effectivePercentRemaining=0" \
    "the model's own scope should apply to the lane that reports it"
  assert_contains "$out" "lane: ordinary accountKey=profile:home scope=all_models" \
    "a lane without that model's scope should fall back to all_models"
  assert_equals "account: ordinary" "$(printf '%s\n' "$out" | tail -1)" "the model-exhausted lane must not be chosen"
  out=$(pick --model claude-sonnet-5); rc=$?
  expect_code 0 "$rc" "a pick for an unscoped model should choose: $out"
  assert_equals "account: $WORK" "$(printf '%s\n' "$out" | tail -1)" "an unscoped model should rank by all_models"
  pass "pick applies a lane's model scope when quota-axi reports one, else all_models"
}

test_full_fable_model_id_uses_the_model_fable_scope() {
  local out rc
  pool ordinary "$WORK"
  # quota-axi names the Fable window `model:fable` (the vendor's model id), while
  # a spawn passes the full model id. Lane A's Fable window is spent but its
  # all_models window is healthy and ranks higher; lane B is healthy on both.
  snapshot 6 \
    "$(lane profile:home "$FAKE_HOME/.claude" "$DEFAULT_STORE" 70 0.9 through_reset 2026-10-11T15:00:00Z \
      fable 0 -1 exhausted_now)" \
    "$(lane profile:work "$WORK" "$DEFAULT_STORE-1a2b3c4d" 50 0.3 through_reset 2026-10-11T16:00:00Z \
      fable 40 0.2 projected_exhaustion)"
  out=$(pick --model claude-fable-5-1); rc=$?
  expect_code 0 "$rc" "a full Fable model id should still choose a lane: $out"
  assert_contains "$out" "lane: ordinary accountKey=profile:home scope=model:fable effectivePercentRemaining=0 spendPriority=-1 runway=exhausted_now" \
    "the spent Fable window must be the scope applied to the lane that reports it"
  assert_contains "$out" "lane: $WORK accountKey=profile:work scope=model:fable effectivePercentRemaining=40" \
    "the healthy lane should be ranked on its own Fable window"
  assert_contains "$out" "verdict=exhausted (no allowance left in the model:fable scope)" "the exhaustion should name the Fable scope"
  assert_equals "account: $WORK" "$(printf '%s\n' "$out" | tail -1)" "a lane with a spent Fable window must not be picked for a Fable spawn"

  out=$(pick --model fable); rc=$?
  expect_code 0 "$rc" "the bare alias should choose: $out"
  assert_equals "account: $WORK" "$(printf '%s\n' "$out" | tail -1)" "the bare Fable alias already matches the scope and must keep doing so"

  out=$(pick --model claude-sonnet-5-5); rc=$?
  expect_code 0 "$rc" "a non-Fable model should choose: $out"
  assert_contains "$out" "lane: ordinary accountKey=profile:home scope=all_models effectivePercentRemaining=70" \
    "a non-Fable model must not read the Fable window"
  assert_contains "$out" "claude-sonnet-5-5 has no quota-axi model scope on this lane, so all_models applied" \
    "the all_models fallback for a model with no evidenced scope must be disclosed"
  assert_equals "account: ordinary" "$(printf '%s\n' "$out" | tail -1)" "a non-Fable model ranks on all_models, where lane A leads"

  out=$(pick); rc=$?
  expect_code 0 "$rc" "a pick without --model should choose: $out"
  assert_not_contains "$out" "has no quota-axi model scope" "no model means no model-scope disclosure"
  pass "pick maps a full claude-fable-* model id to the model:fable scope and discloses the all_models fallback elsewhere"
}

test_exact_model_scope_wins_over_the_fable_family_scope() {
  local out rc
  pool ordinary "$WORK"
  snapshot 6 \
    "$(lane profile:home "$FAKE_HOME/.claude" "$DEFAULT_STORE" 70 0.9 through_reset 2026-10-11T15:00:00Z \
      fable 0 -1 exhausted_now | jq '.quotaSemantics.effectiveAvailability += [
        {scope: "model:claude-fable-5-1", status: "known", effectivePercentRemaining: 55,
         limitingWindowIds: ["model:x"], runway: {status: "through_reset"}, selection: {status: "known", spendPriority: 0.8}}]')" \
    "$(lane profile:work "$WORK" "$DEFAULT_STORE-1a2b3c4d" 50 0.3 through_reset 2026-10-11T16:00:00Z \
      fable 40 0.2 projected_exhaustion)"
  out=$(pick --model claude-fable-5-1); rc=$?
  expect_code 0 "$rc" "an exact scope should choose: $out"
  assert_contains "$out" "lane: ordinary accountKey=profile:home scope=model:claude-fable-5-1 effectivePercentRemaining=55" \
    "an exact model:<id> scope must win over the family scope"
  assert_equals "account: ordinary" "$(printf '%s\n' "$out" | tail -1)" "the exact scope's healthy window decides"

  snapshot 6 \
    "$(lane profile:home "$FAKE_HOME/.claude" "$DEFAULT_STORE" 70 0.9 through_reset 2026-10-11T15:00:00Z \
      fable 0 -1 exhausted_now)" \
    "$(lane profile:work "$WORK" "$DEFAULT_STORE-1a2b3c4d" 50 0.3 through_reset 2026-10-11T16:00:00Z \
      fable 0 -1 exhausted_now)"
  out=$(pick --model claude-fable-5-1); rc=$?
  expect_code 3 "$rc" "every lane's Fable window spent must exit exhausted: $out"
  assert_not_contains "$out" "account:" "no account may be named when every Fable window is spent"
  pass "pick prefers an exact model scope, and exits 3 when every lane's Fable window is spent"
}

test_exhausted_lane_is_skipped() {
  local out rc
  pool ordinary "$WORK"
  snapshot 6 \
    "$(lane profile:home "$FAKE_HOME/.claude" "$DEFAULT_STORE" 30 -0.4 through_reset 2026-10-11T15:00:00Z)" \
    "$(lane profile:work "$WORK" "$DEFAULT_STORE-1a2b3c4d" 0 0.9 exhausted_now 2026-10-11T16:00:00Z)"
  out=$(pick); rc=$?
  expect_code 0 "$rc" "one eligible lane should be chosen: $out"
  assert_contains "$out" "verdict=exhausted" "the exhausted lane should be reported as exhausted"
  assert_equals "account: ordinary" "$(printf '%s\n' "$out" | tail -1)" "an exhausted lane must never win on spendPriority"
  pass "pick skips an exhausted lane even when its spendPriority is higher"
}

test_all_exhausted_exits_distinctly() {
  local out rc
  pool ordinary "$WORK"
  snapshot 6 \
    "$(lane profile:home "$FAKE_HOME/.claude" "$DEFAULT_STORE" 0 -1 exhausted_now 2026-10-11T15:00:00Z)" \
    "$(lane profile:work "$WORK" "$DEFAULT_STORE-1a2b3c4d" 0 -1 exhausted_now 2026-10-11T16:00:00Z)"
  out=$(pick); rc=$?
  expect_code 3 "$rc" "an all-exhausted pool should exit with the distinct exhausted status"
  assert_contains "$out" "every declared Claude account is measured and exhausted" "the exhaustion should be stated"
  assert_not_contains "$out" "account:" "no account may be named when every lane is exhausted"
  pool ordinary "$WORK" "$MON"
  out=$(pick); rc=$?
  expect_code 0 "$rc" "an unmeasured account should remain choosable beside exhausted ones: $out"
  assert_contains "$out" "basis: UNMEASURED DEFAULT" "choosing an unmeasured account must be disclosed"
  assert_equals "account: $MON" "$(printf '%s\n' "$out" | tail -1)" "the first unmeasured line should be chosen over exhausted ones"
  pass "pick exits 3 when every declared account is exhausted, and otherwise discloses an unmeasured fallback"
}

test_unmeasured_pool_discloses_the_first_line_default() {
  local out rc
  pool "$WORK" ordinary
  snapshot 5 "$(lane x - "" 50 0.5 through_reset 2026-10-11T15:00:00Z | jq 'del(.accountKey)')"
  out=$(pick); rc=$?
  expect_code 0 "$rc" "an old quota-axi should still yield the default: $out"
  assert_contains "$out" "accountKey=unmeasured" "an unmatched entry should be reported as unmeasured"
  assert_contains "$out" "no account lanes (schema 5)" "the old schema should be named as the reason"
  assert_contains "$out" "basis: UNMEASURED DEFAULT" "the default should be marked as unmeasured"
  assert_equals "account: $WORK" "$(printf '%s\n' "$out" | tail -1)" "the unmeasured default is the first line"

  snapshot 6 "$(lane profile:a - "" 50 0.5 through_reset 2026-10-11T15:00:00Z)"
  out=$(pick); rc=$?
  expect_code 0 "$rc" "lanes without locators should still yield the default: $out"
  assert_contains "$out" "no quota-axi lane carries a locator for this account" "a missing locator should be named"
  assert_equals "account: $WORK" "$(printf '%s\n' "$out" | tail -1)" "a locator-less snapshot falls back to the first line"

  rm -f "$SNAPSHOT"
  out=$(pick); rc=$?
  expect_code 0 "$rc" "a failing quota-axi should still yield the default: $out"
  assert_contains "$out" "quota-axi printed no valid quota snapshot" "the failed read should be named"
  assert_equals "account: $WORK" "$(printf '%s\n' "$out" | tail -1)" "a failed read falls back to the first line"
  pass "pick discloses an unmeasured first-line default for old, locator-less, or failed quota-axi output"
}

test_ordinary_binds_only_the_unsuffixed_default_store() {
  local out rc
  pool ordinary "$WORK"
  # The decoy is ~/.claude selected explicitly through CLAUDE_CONFIG_DIR, which
  # Claude keys to a suffixed store: a different login than `ordinary`.
  snapshot 6 \
    "$(lane profile:decoy "$FAKE_HOME/.claude" "$DEFAULT_STORE-0f0f0f0f" 95 0.9 through_reset 2026-10-11T15:00:00Z)" \
    "$(lane profile:home "$FAKE_HOME/.claude" "$DEFAULT_STORE" 20 0.1 through_reset 2026-10-11T15:00:00Z)" \
    "$(lane profile:work "$WORK" "$DEFAULT_STORE-1a2b3c4d" 50 0.3 through_reset 2026-10-11T16:00:00Z)"
  out=$(pick); rc=$?
  expect_code 0 "$rc" "the pool should be measured: $out"
  assert_contains "$out" "lane: ordinary accountKey=profile:home" "ordinary should bind the unsuffixed default store"
  assert_equals "account: $WORK" "$(printf '%s\n' "$out" | tail -1)" "the decoy's evidence must not be credited to ordinary"
  pass "pick binds ordinary to the unsuffixed Claude Code-credentials lane only"
}

test_ties_break_by_reset_then_pool_order() {
  local out rc
  pool ordinary "$WORK" "$MON"
  snapshot 6 \
    "$(lane profile:home "$FAKE_HOME/.claude" "$DEFAULT_STORE" 50 0.3 through_reset 2026-10-11T18:00:00Z)" \
    "$(lane profile:work "$WORK" "$DEFAULT_STORE-1a2b3c4d" 50 0.3 through_reset 2026-10-11T15:00:00Z)" \
    "$(lane profile:mon "$MON" "$DEFAULT_STORE-5e6f7a8b" 50 0.1 through_reset 2026-10-11T12:00:00Z)"
  out=$(pick); rc=$?
  expect_code 0 "$rc" "a tied pool should still choose: $out"
  assert_contains "$out" "tied and broken by the earliest resetsAt" "the tie-break should be stated"
  assert_equals "account: $WORK" "$(printf '%s\n' "$out" | tail -1)" "the earlier reset should win a spendPriority tie"
  snapshot 6 \
    "$(lane profile:home "$FAKE_HOME/.claude" "$DEFAULT_STORE" 50 0.3 through_reset 2026-10-11T15:00:00Z)" \
    "$(lane profile:work "$WORK" "$DEFAULT_STORE-1a2b3c4d" 50 0.3 through_reset 2026-10-11T15:00:00Z)"
  out=$(pick); rc=$?
  expect_code 0 "$rc" "a fully tied pool should still choose: $out"
  assert_contains "$out" "tied and broken by the earlier line" "the pool-order tie-break should be stated"
  assert_equals "account: ordinary" "$(printf '%s\n' "$out" | tail -1)" "an exact tie should go to the earlier line"
  pass "pick breaks an exact spendPriority tie by the earliest reset, then by pool order"
}

test_single_line_or_absent_pin_skips_quota_axi() {
  local out rc
  pool "$WORK"
  out=$(pick --model claude-opus-5); rc=$?
  expect_code 0 "$rc" "a single-line pin should succeed: $out"
  assert_equals "account: $WORK" "$(printf '%s\n' "$out" | tail -1)" "a single line is the only choice"
  [ ! -s "$CALLS" ] || fail "a single-line pin must not run quota-axi: $(cat "$CALLS")"
  rm "$CFG/claude-account"
  out=$(pick); rc=$?
  expect_code 0 "$rc" "an unpinned home should succeed: $out"
  assert_contains "$out" "spawn without --account" "an unpinned home should say to spawn without --account"
  assert_equals "account: none" "$(printf '%s\n' "$out" | tail -1)" "an unpinned home has no account to name"
  [ ! -s "$CALLS" ] || fail "an unpinned home must not run quota-axi: $(cat "$CALLS")"
  pass "pick skips quota-axi for a single-line or absent pin"
}

test_malformed_pool_and_usage_refuse() {
  local out rc
  printf 'ordinary\n%s\nordinary\n' "$WORK" > "$CFG/claude-account"
  out=$(pick); rc=$?
  expect_code 1 "$rc" "a duplicated pool line must refuse"
  assert_contains "$out" "config/claude-account must hold one account per line" "the refusal should name the file"
  [ ! -s "$CALLS" ] || fail "a malformed pool must refuse before quota-axi runs"
  out=$("$PICK" choose 2>&1); rc=$?
  expect_code 2 "$rc" "an unknown subcommand is a usage error"
  out=$("$PICK" --help 2>&1); rc=$?
  expect_code 0 "$rc" "--help should succeed"
  assert_contains "$out" "fm-claude-account.sh pick [--model <claude-model>]" "--help should print the usage"
  pass "pick refuses a malformed pool and rejects bad usage"
}

test_token_map_is_validated_but_does_not_change_the_pick() {
  local out rc
  pool ordinary "$WORK" "$MON"
  snapshot 6 \
    "$(lane profile:home "$FAKE_HOME/.claude" "$DEFAULT_STORE" 60 0.2 through_reset 2026-10-11T15:00:00Z)" \
    "$(lane profile:work "$WORK" "$DEFAULT_STORE-1a2b3c4d" 40 0.6 through_reset 2026-10-11T16:00:00Z)" \
    "$(lane profile:mon "$MON" "$DEFAULT_STORE-5e6f7a8b" 90 0.4 through_reset 2026-10-11T14:00:00Z)"
  printf '%s keychain:fm-svc/cm\n' "$WORK" > "$CFG/claude-account-tokens"
  out=$(pick); rc=$?
  expect_code 0 "$rc" "a valid token map must not change the pick: $out"
  assert_equals "account: $WORK" "$(printf '%s\n' "$out" | tail -1)" "the pick should rank exactly as without the token map"
  assert_not_contains "$out" "keychain:" "the pick must not read token sources"
  printf '%s keychain:fm-svc/cm\n' "$TMP_ROOT/undeclared" > "$CFG/claude-account-tokens"
  out=$(pick); rc=$?
  expect_code 1 "$rc" "a token map naming an undeclared account must refuse the pick"
  assert_contains "$out" "config/claude-account-tokens maps '$TMP_ROOT/undeclared', which config/claude-account does not declare" \
    "the refusal should name the undeclared account"
  [ ! -s "$CALLS" ] || fail "a malformed token map must refuse before quota-axi runs"
  rm "$CFG/claude-account-tokens"
  pass "pick validates the token map with the pool and otherwise ignores it"
}

# A pool whose ordinary lane reads fresh live and whose $WORK lane quota-axi
# could not read here (stale), with the reading refreshed <age> seconds ago.
reuse_fixture() {
  local age=$1 identity=${2:-null} live_id=${3:-}
  clear_readings
  pool ordinary "$WORK"
  snapshot 6 \
    "$(lane profile:home "$FAKE_HOME/.claude" "$DEFAULT_STORE" 30 0.1 through_reset 2026-10-11T15:00:00Z)" \
    "$(stale_lane profile:work "$WORK" "$DEFAULT_STORE-1a2b3c4d" "$live_id")"
  reading pxl.json "$(reading_lane profile:remote "$WORK" "$DEFAULT_STORE-ffffffff" 80 0.7 "$age" "$identity")"
}

test_recent_reading_measures_a_stale_lane_with_provenance() {
  local out rc
  reuse_fixture 120
  out=$(reuse_pick); rc=$?
  expect_code 0 "$rc" "a reused lane should still yield a choice: $out"
  assert_contains "$out" "lane: $WORK accountKey=profile:work scope=all_models effectivePercentRemaining=80 spendPriority=0.7 runway=through_reset" \
    "the reused lane should be measured exactly like a live fresh one, under the live lane's key"
  assert_contains "$out" "verdict=eligible (fresh and measured via reading $READINGS/pxl.json refreshedAt " \
    "the lane line should name the reading it rests on"
  assert_contains "$out" "basis: highest spendPriority 0.7 among 2 eligible account(s); the chosen lane was measured via reading $READINGS/pxl.json refreshedAt " \
    "the basis should name the provenance of the chosen lane"
  assert_not_contains "$out" "UNMEASURED DEFAULT" "a reused lane is measured, never an unmeasured default"
  assert_equals "account: $WORK" "$(printf '%s\n' "$out" | tail -1)" "the reused lane should win on its own spendPriority"
  assert_not_contains "$(printf '%s\n' "$out" | grep '^lane: ordinary')" "via reading" "a live fresh lane carries no provenance"
  pass "pick measures a stale lane from a recent reading and names the reading"
}

test_reading_older_than_the_bound_stays_unmeasured() {
  local out rc
  reuse_fixture 700
  out=$(reuse_pick); rc=$?
  expect_code 0 "$rc" "an old reading must not break the pick: $out"
  assert_contains "$out" "lane: $WORK accountKey=profile:work scope=none effectivePercentRemaining=unknown" \
    "a reading older than the bound should leave the lane unmeasured"
  assert_contains "$out" "lane status is stale" "the lane should keep its live reason"
  assert_not_contains "$out" "via reading" "an old reading must leave no provenance"
  assert_equals "account: ordinary" "$(printf '%s\n' "$out" | tail -1)" "the unreadable lane must not win"
  out=$(FM_CLAUDE_QUOTA_READING_MAX_AGE=900 reuse_pick); rc=$?
  expect_code 0 "$rc" "a widened bound should pick: $out"
  assert_contains "$out" "effectivePercentRemaining=80" "FM_CLAUDE_QUOTA_READING_MAX_AGE should widen the bound"
  out=$(FM_CLAUDE_QUOTA_READING_MAX_AGE=bogus reuse_pick)
  assert_not_contains "$out" "via reading" "an unusable bound falls back to the 600 s default"
  reuse_fixture 590
  out=$(reuse_pick)
  assert_contains "$out" "via reading" "a reading just inside the 600 s default should be reused"
  pass "pick ignores a reading older than FM_CLAUDE_QUOTA_READING_MAX_AGE (600 s default)"
}

test_identity_mismatch_is_ignored() {
  local out
  reuse_fixture 60 '{"accountId":"acct-remote","email":"a@example.com"}' acct-live
  out=$(reuse_pick)
  assert_not_contains "$out" "via reading" "differing accountIds must not be reused"
  assert_contains "$out" "effectivePercentRemaining=unknown" "a mismatching reading leaves the lane unmeasured"
  reuse_fixture 60 '{"accountId":"acct-live","email":"other@example.com"}' acct-live
  out=$(reuse_pick)
  assert_contains "$out" "via reading" "an equal accountId should be reused"
  reuse_fixture 60 '{"email":"A@Example.com"}'
  out=$(reuse_pick)
  assert_contains "$out" "via reading" "a side without identity leaves the path match alone"
  clear_readings
  snapshot 6 \
    "$(lane profile:home "$FAKE_HOME/.claude" "$DEFAULT_STORE" 30 0.1 through_reset 2026-10-11T15:00:00Z)" \
    "$(stale_lane profile:work "$WORK" "$DEFAULT_STORE-1a2b3c4d" | jq '.account = {email: "a@example.com"}')"
  reading pxl.json "$(reading_lane profile:remote "$WORK" "$DEFAULT_STORE-ffffffff" 80 0.7 60 '{"email":"a@example.com"}')"
  assert_contains "$(reuse_pick)" "via reading" "an equal email should be reused when neither side has an accountId"
  reading pxl.json "$(reading_lane profile:remote "$WORK" "$DEFAULT_STORE-ffffffff" 80 0.7 60 '{"email":"b@example.com"}')"
  assert_not_contains "$(reuse_pick)" "via reading" "differing emails must not be reused"
  reading pxl.json "$(reading_lane profile:remote "$WORK" "$DEFAULT_STORE-ffffffff" 80 0.7 60 '{"accountId":"acct-1"}')"
  assert_not_contains "$(reuse_pick)" "via reading" "identities of different kinds cannot be shown equal"
  pass "pick reuses a reading only when the non-secret account identity agrees"
}

test_live_fresh_lane_beats_any_reading() {
  local out
  pool ordinary "$WORK"
  clear_readings
  snapshot 6 \
    "$(lane profile:home "$FAKE_HOME/.claude" "$DEFAULT_STORE" 30 0.1 through_reset 2026-10-11T15:00:00Z)" \
    "$(lane profile:work "$WORK" "$DEFAULT_STORE-1a2b3c4d" 40 0.3 through_reset 2026-10-11T16:00:00Z | jq '.account = {accountId: "acct-live"}')"
  reading pxl.json \
    "$(reading_lane profile:remote "$WORK" "$DEFAULT_STORE-ffffffff" 99 0.99 10 '{"accountId":"acct-live"}')" \
    "$(reading_lane profile:other "$FAKE_HOME/.claude" "$DEFAULT_STORE" 99 0.99 10 '{"accountId":"acct-other"}')"
  out=$(reuse_pick)
  assert_contains "$out" "lane: $WORK accountKey=profile:work scope=all_models effectivePercentRemaining=40 spendPriority=0.3" \
    "a live fresh lane keeps its own measurement"
  assert_not_contains "$out" "via reading" "a live fresh lane never takes a reading"
  assert_equals "account: $WORK" "$(printf '%s\n' "$out" | tail -1)" "the live spendPriority decides"
  pass "pick lets a live fresh lane win over a younger or different reading"
}

test_reading_selection_rules() {
  local out
  reuse_fixture 300
  rm -f "$READINGS/pxl.json"
  reading old.json "$(reading_lane profile:r1 "$WORK" "$DEFAULT_STORE-ffffffff" 10 0.2 400)"
  reading new.json "$(reading_lane profile:r2 "$WORK" "$DEFAULT_STORE-ffffffff" 20 0.4 100)"
  out=$(reuse_pick)
  assert_contains "$out" "effectivePercentRemaining=20 spendPriority=0.4" "the freshest reading across files should win"
  reading new.json \
    "$(reading_lane profile:r2 "$WORK" "$DEFAULT_STORE-ffffffff" 20 0.4 100 | jq '.state.status = "stale"')" \
    "$(reading_lane profile:r3 "$MON" "$DEFAULT_STORE-eeeeeeee" 20 0.4 100)"
  reading old.json "$(reading_lane profile:r1 "$WORK" "$DEFAULT_STORE-ffffffff" 10 0.2 400 | jq '.state.status = "stale"')"
  out=$(reuse_pick)
  assert_not_contains "$out" "via reading" "a non-fresh reading lane or one for another path is never reused"
  reuse_fixture 60
  out=$(FM_CLAUDE_QUOTA_READINGS="$TMP_ROOT/missing/*.json:$READINGS/pxl.json" pick)
  assert_contains "$out" "via reading $READINGS/pxl.json" "FM_CLAUDE_QUOTA_READINGS should take a delimiter list of files and globs"
  out=$(FM_CLAUDE_QUOTA_READINGS='' pick)
  assert_not_contains "$out" "via reading" "an empty FM_CLAUDE_QUOTA_READINGS should disable reuse"
  pass "pick takes the freshest fresh same-path reading from the declared files"
}

test_missing_or_unusable_reading_files_change_nothing() {
  local baseline out
  reuse_fixture 60
  clear_readings
  baseline=$(reuse_pick)
  assert_not_contains "$baseline" "via reading" "no reading files means no provenance"
  assert_contains "$baseline" "verdict=unmeasured (lane status is stale)" "no reading files behaves as before: the stale lane stays unmeasured"
  printf 'not json {' > "$READINGS/garbage.json"
  printf '{"schemaVersion":6}' > "$READINGS/noproviders.json"
  printf '[1,2]' > "$READINGS/array.json"
  : > "$READINGS/empty.json"
  mkdir "$READINGS/dir.json"
  out=$(reuse_pick)
  assert_equals "$baseline" "$out" "missing, unparsable, or empty reading files must leave the output identical"
  out=$(FM_CLAUDE_QUOTA_READINGS="$TMP_ROOT/never/*.json" pick)
  assert_equals "$baseline" "$out" "a reading list naming nothing must leave the output identical"
  out=$(pick)
  assert_equals "$baseline" "$out" "the default reading directory under HOME being absent must leave the output identical"
  clear_readings
  pass "pick behaves exactly as before when no usable reading file exists"
}

test_default_reading_directory_is_under_home() {
  local out
  reuse_fixture 60
  mkdir -p "$FAKE_HOME/.local/state/quota-axi-refresh"
  mv "$READINGS/pxl.json" "$FAKE_HOME/.local/state/quota-axi-refresh/last.json"
  out=$(pick)
  assert_contains "$out" "via reading $FAKE_HOME/.local/state/quota-axi-refresh/last.json" \
    "the default reading list should be \$HOME/.local/state/quota-axi-refresh/*.json"
  pass "pick reads \$HOME/.local/state/quota-axi-refresh/*.json by default"
}

test_two_measured_lanes_pick_the_highest_spend_priority
test_model_scope_row_is_used_when_reported
test_full_fable_model_id_uses_the_model_fable_scope
test_exact_model_scope_wins_over_the_fable_family_scope
test_exhausted_lane_is_skipped
test_all_exhausted_exits_distinctly
test_unmeasured_pool_discloses_the_first_line_default
test_ordinary_binds_only_the_unsuffixed_default_store
test_ties_break_by_reset_then_pool_order
test_single_line_or_absent_pin_skips_quota_axi
test_malformed_pool_and_usage_refuse
test_token_map_is_validated_but_does_not_change_the_pick
test_recent_reading_measures_a_stale_lane_with_provenance
test_reading_older_than_the_bound_stays_unmeasured
test_identity_mismatch_is_ignored
test_live_fresh_lane_beats_any_reading
test_reading_selection_rules
test_missing_or_unusable_reading_files_change_nothing
test_default_reading_directory_is_under_home

echo "# all fm-claude-account tests passed"
