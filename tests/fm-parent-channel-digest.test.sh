#!/usr/bin/env bash
# tests/fm-parent-channel-digest.test.sh - a secondmate's routine child events
# (child PR ready, merged, child done, an answered hold the parent already
# closed) reach the parent home's state/<mate-id>.digest instead of the status
# stream every parent wake comes from, while a captain question, a blocker, a
# failure, and a correlated answer still land on that stream
# (bin/fm-parent-channel-lib.sh owns the routing rule).
#
# Covers the routing rule through the local publisher entry point, the remote
# reply adapter's mirror routing the same lines on the parent side, the real
# watcher's signal scan and heartbeat backstop staying quiet on digest growth,
# bin/fm-secondmate-digest.sh's read position, and the real fm-wake-drain.sh
# presenting the digest only with a heartbeat.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-parent-channel-digest)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

# The real drain asserts watcher liveness through fm-guard.sh, whose tangle
# check warns when FM_ROOT sits on a feature branch; point it at a fresh
# non-git dir so the banner stays inert in this disposable worktree.
FM_ROOT_OVERRIDE="$(fm_test_tmproot fm-parent-channel-digest-root)"
export FM_ROOT_OVERRIDE
mkdir -p "$FM_ROOT_OVERRIDE"

cleanup() { rm -rf -- "$TMP_ROOT" "$FM_ROOT_OVERRIDE"; }
trap cleanup EXIT

# seed_local_pair <dir>: a parent home that registers secondmate `mate`, and
# that mate's home bound to it on the local route.
seed_local_pair() {  # <dir>
  local dir=$1
  mkdir -p "$dir/parent/state" "$dir/parent/data" "$dir/mate/state"
  printf 'kind=secondmate\nhome=%s\n' "$dir/mate" > "$dir/parent/state/mate.meta"
  printf '%s\n' mate > "$dir/mate/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$dir/parent" \
    > "$dir/mate/.fm-secondmate-parent"
}

# publish <dir> <line>...: publish each line from the mate home through the
# channel library, exactly as every script publisher does.
publish() {  # <dir> <line>...
  local dir=$1
  shift
  bash -c '
    root=$1 home=$2
    shift 2
    # shellcheck source=bin/fm-parent-channel-lib.sh
    . "$root/bin/fm-parent-channel-lib.sh"
    for line in "$@"; do
      fm_parent_channel_report "$home" "$home/state" "$line" || exit "$?"
    done
  ' _ "$ROOT" "$dir/mate" "$@"
}

# unstamped <file>: the file's lines with their emission-time tag removed.
unstamped() {  # <file>
  sed -E 's/ \[at=[0-9]+\]//' "$1" 2>/dev/null
}

# --- the routing rule on the local route ----------------------------------

test_local_routine_lines_reach_the_digest_and_waking_lines_the_stream() {
  local dir="$TMP_ROOT/local" status digest
  seed_local_pair "$dir"
  status="$dir/parent/state/mate.status"
  digest="$dir/parent/state/mate.digest"
  publish "$dir" \
    'done [key=child-pr-c1]: child c1 PR ready: https://github.com/example/repo/pull/1 mode=no-mistakes yolo=on' \
    'done [key=merged-c1]: merged c1 https://github.com/example/repo/pull/1' \
    'done [key=child-outcome-c2-done-0a1b2c3d]: child c2 done: report ready report=data/c2/report.md' \
    'done [key=inactive-outcome-mate-c3-done]: inactive terminal child=c3 fingerprint=abc' \
    'failed [key=child-outcome-c4-failed-0a1b2c3d]: child c4 failed: tests red' \
    'failed [key=inactive-outcome-mate-c5-failed]: inactive terminal child=c5 fingerprint=def' \
    'needs-decision [key=captain-hold-t1-1]: captain hold t1: pick the rollout window' \
    'blocked [key=ci-down]: the forge is unreachable' \
    'done [key=child-review-c6]: child c6 review ready: https://review.example/6' \
    'done [corr=0123456789abcdef] [key=child-pr-c7]: answer to the routed request' \
    || fail "a channel publish failed"
  for want in \
    'done [key=child-pr-c1]: child c1 PR ready' \
    'done [key=merged-c1]: merged c1' \
    'done [key=child-outcome-c2-done-0a1b2c3d]: child c2 done' \
    'done [key=inactive-outcome-mate-c3-done]: inactive terminal child=c3'; do
    assert_grep "$want" <(unstamped "$digest") "a routine child event missed the digest: $want"
    assert_no_grep "$want" "$status" "a routine child event still woke the parent: $want"
  done
  for want in \
    'failed [key=child-outcome-c4-failed-0a1b2c3d]' \
    'failed [key=inactive-outcome-mate-c5-failed]' \
    'needs-decision [key=captain-hold-t1-1]' \
    'blocked [key=ci-down]' \
    'done [key=child-review-c6]' \
    'done [corr=0123456789abcdef] [key=child-pr-c7]'; do
    assert_grep "$want" <(unstamped "$status") "a waking line missed the parent stream: $want"
    assert_no_grep "$want" "$digest" "a waking line was hidden in the digest: $want"
  done
  # A retried publish is deduplicated where the line first landed.
  publish "$dir" 'done [key=merged-c1]: merged c1 https://github.com/example/repo/pull/1' \
    'failed [key=child-outcome-c4-failed-0a1b2c3d]: child c4 failed: tests red' \
    || fail "a retried publish failed"
  [ "$(grep -c 'key=merged-c1' "$digest")" -eq 1 ] || fail "a retried routine line was appended twice"
  [ "$(grep -c 'key=child-outcome-c4-failed' "$status")" -eq 1 ] || fail "a retried waking line was appended twice"
  pass "routine child events land in the digest while questions, blockers, failures, and answers wake the parent"
}

test_answered_hold_wakes_until_the_parent_has_closed_it() {
  local dir="$TMP_ROOT/hold" status digest
  seed_local_pair "$dir"
  status="$dir/parent/state/mate.status"
  digest="$dir/parent/state/mate.digest"
  # Answered in the mate home while the parent still holds the hold open: only
  # the stream can close it in the parent's open-decision fold.
  publish "$dir" 'needs-decision [key=captain-hold-t1-1]: captain hold t1: pick' \
    'resolved [key=captain-hold-t1-1]: captain hold t1: answered in the mate pane' \
    || fail "hold publish failed"
  assert_grep 'resolved [key=captain-hold-t1-1]' <(unstamped "$status") \
    "an answer to a hold the parent still holds open missed the stream"
  bash -c '. "$1/bin/fm-classify-lib.sh"; status_open_decisions "$2" secondmate' _ "$ROOT" "$status" \
    | grep -F 'captain-hold-t1-1' >/dev/null && fail "the parent's fold kept an answered hold open"
  # The parent relays the captain's answer and closes the hold itself first, as
  # fm-send --resolve-key does; the mate's matching answer is then routine.
  publish "$dir" 'needs-decision [key=captain-hold-t2-1]: captain hold t2: pick' || fail "hold publish failed"
  printf 'resolved [key=captain-hold-t2-1]: answered through the parent\n' >> "$status"
  publish "$dir" 'resolved [key=captain-hold-t2-1]: captain hold t2: answered' || fail "answer publish failed"
  assert_grep 'resolved [key=captain-hold-t2-1]: captain hold t2: answered' <(unstamped "$digest") \
    "an answer the parent already recorded still woke it"
  [ "$(grep -c 'key=captain-hold-t2-1' "$status")" -eq 2 ] \
    || fail "the mate's answer to an already closed hold reached the stream"
  # A retry of the first answer stays where it landed instead of moving.
  publish "$dir" 'resolved [key=captain-hold-t1-1]: captain hold t1: answered in the mate pane' \
    || fail "answer retry failed"
  [ "$(grep -c 'resolved \[key=captain-hold-t1-1\]' "$status")" -eq 1 ] || fail "an answer retry was appended twice"
  assert_no_grep 'captain-hold-t1-1' "$digest" "an answer retry moved into the digest"
  pass "an answered hold wakes the parent until the parent has closed it, then it is routine"
}

test_main_home_publishes_nothing() {
  local dir="$TMP_ROOT/main-home" rc=0
  mkdir -p "$dir/state"
  bash -c '. "$1/bin/fm-parent-channel-lib.sh"; fm_parent_channel_report "$2" "$2/state" "done [key=merged-x]: merged x"' \
    _ "$ROOT" "$dir" || rc=$?
  [ "$rc" -eq 1 ] || fail "a main home must report nothing to publish (rc=$rc)"
  [ -z "$(find "$dir/state" -name '*.digest')" ] || fail "a main home wrote a digest"
  pass "a main home has no parent and writes no digest"
}

# --- the remote mirror routes with the same rule ---------------------------

sha256_of() {  # <file>
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

# delta_result <log> <from> <out>: one captured delta of <log> from byte
# <from> to its end, in the shape bin/fm-remote-delta-read.sh produces.
delta_result() {  # <log> <from> <out>
  local log=$1 from=$2 out=$3 to dir
  dir=$(dirname "$out")
  to=$(LC_ALL=C wc -c < "$log" | tr -d ' ')
  if [ "$from" -eq 0 ]; then : > "$dir/from-prefix"; else head -c "$from" "$log" > "$dir/from-prefix"; fi
  tail -c "+$((from + 1))" "$log" > "$dir/payload"
  {
    printf 'schema=fm-remote-delta.v1\nstatus=delta\npath=state/parent-replies.status\n'
    printf 'from_offset=%s\nto_offset=%s\n' "$from" "$to"
    printf 'from_prefix_sha256=%s\n' "$(sha256_of "$dir/from-prefix")"
    printf 'to_prefix_sha256=%s\n' "$(sha256_of "$log")"
    printf 'payload_sha256=%s\n' "$(sha256_of "$dir/payload")"
    printf 'payload_bytes=%s\n' "$((to - from))"
    printf 'reason=\n\n'
    cat "$dir/payload"
  } > "$out"
}

ingest() {  # <parent-home> <result>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_DATA_OVERRIDE="$1/data" \
    "$ROOT/bin/fm-procevent-remote-reply.sh" ingest ios "$2"
}

test_remote_mirror_routes_each_line_with_the_same_rule() {
  local dir="$TMP_ROOT/remote" parent log status digest out from
  parent="$dir/parent"
  mkdir -p "$parent/state" "$parent/data" "$dir/remote/state" "$dir/work"
  printf 'kind=secondmate\nremote=1\n' > "$parent/state/ios.meta"
  log="$dir/remote/state/parent-replies.status"
  status="$parent/state/ios.status"
  digest="$parent/state/ios.digest"
  # One delta that opens and answers a hold, plus routine facts, a decision
  # the parent will close itself, and a correlated answer.
  {
    printf 'done [key=child-pr-c1] [at=1]: child c1 PR ready: https://github.com/example/repo/pull/1\n'
    printf 'needs-decision [key=captain-hold-t1-1] [at=2]: captain hold t1: pick\n'
    printf 'resolved [key=captain-hold-t1-1] [at=3]: captain hold t1: answered in the mate pane\n'
    printf 'needs-decision [key=captain-hold-t2-1] [at=4]: captain hold t2: pick\n'
    printf 'done [key=merged-c1] [at=5]: merged c1 https://github.com/example/repo/pull/1\n'
    printf 'done [corr=0123456789abcdef] [at=6]: the routed audit is clean\n'
  } > "$log"
  delta_result "$log" 0 "$dir/work/delta-1"
  out=$(ingest "$parent" "$dir/work/delta-1") || fail "the first remote delta was not ingested: $out"
  assert_contains "$out" 'appended=6' "the first delta did not mirror every line"
  for want in 'key=child-pr-c1' 'key=merged-c1'; do
    assert_grep "$want" "$digest" "a mirrored routine line missed the digest: $want"
    assert_no_grep "$want" "$status" "a mirrored routine line still woke the parent: $want"
  done
  for want in 'needs-decision [key=captain-hold-t1-1]' 'resolved [key=captain-hold-t1-1]' \
    'needs-decision [key=captain-hold-t2-1]' 'done [corr=0123456789abcdef]'; do
    assert_grep "$want" "$status" "a mirrored waking line missed the parent stream: $want"
  done
  # The parent closes the second hold itself, then the mate's answer arrives.
  printf 'resolved [key=captain-hold-t2-1]: answered through the parent\n' >> "$status"
  from=$(LC_ALL=C wc -c < "$log" | tr -d ' ')
  printf 'resolved [key=captain-hold-t2-1] [at=7]: captain hold t2: answered\n' >> "$log"
  delta_result "$log" "$from" "$dir/work/delta-2"
  out=$(ingest "$parent" "$dir/work/delta-2") || fail "the second remote delta was not ingested: $out"
  assert_grep 'resolved [key=captain-hold-t2-1] [at=7]' "$digest" \
    "a mirrored answer the parent already recorded still woke it"
  assert_no_grep '[at=7]' "$status" "a mirrored answer to a closed hold reached the stream"
  # A replayed capture adds nothing anywhere.
  out=$(ingest "$parent" "$dir/work/delta-2") || fail "a replayed delta failed: $out"
  assert_contains "$out" 'appended=0' "a replayed delta was not deduplicated"
  [ "$(grep -c 'captain-hold-t2-1' "$digest")" -eq 1 ] || fail "a replayed delta duplicated a digest line"
  pass "the remote mirror routes each line to the stream or the digest by the local rule"
}

# --- the parent watcher never wakes on the digest --------------------------

# Source the watcher once with an isolated state/home; its source guard returns
# before the lock/loop, so only the functions load.
WATCH_HOME="$TMP_ROOT/watch"
seed_local_pair "$WATCH_HOME"
export FM_STATE_OVERRIDE="$WATCH_HOME/parent/state"
export FM_HOME="$WATCH_HOME/parent"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-watch.sh"

test_watcher_stays_quiet_while_only_the_digest_grows() {
  local out rc
  # shellcheck disable=SC2034 # read by the sourced watcher's scans at call time
  STATE="$WATCH_HOME/parent/state"
  publish "$WATCH_HOME" 'done [key=child-pr-c1]: child c1 PR ready: https://github.com/example/repo/pull/1' \
    'done [key=merged-c1]: merged c1 https://github.com/example/repo/pull/1' \
    || fail "routine publish failed"
  assert_present "$STATE/mate.digest" "the routine lines did not reach the digest"
  out=$(scan_signals) || fail "scan_signals failed over the parent state"
  [ -z "$out" ] || fail "digest growth produced a parent signal wake: $out"
  heartbeat_scan_finds_actionable; rc=$?
  [ "$rc" -eq 1 ] || fail "digest growth surfaced through the heartbeat backstop: $FM_HEARTBEAT_SURFACE_ENDPOINTS"
  publish "$WATCH_HOME" 'failed [key=child-outcome-c2-failed-0a1b2c3d]: child c2 failed: tests red' \
    || fail "failure publish failed"
  out=$(scan_signals) || fail "scan_signals failed over the parent state"
  printf '%s\n' "$out" | cut -f3 | grep -F 'mate.status' >/dev/null \
    || fail "a child failure must still wake the parent: $out"
  pass "the parent watcher stays quiet on digest growth and still wakes on a failure"
}

# --- reading the digest -----------------------------------------------------

digest_read() {  # <home> <args>...
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-secondmate-digest.sh" "$@"
}

test_reader_marks_what_it_shows_and_keeps_a_partial_line() {
  local home="$TMP_ROOT/reader" out
  mkdir -p "$home/state"
  printf 'done [key=child-pr-a1]: a1 ready\ndone [key=merged-a1]: a1 merged\n' > "$home/state/alpha.digest"
  printf 'done [key=merged-b1]: b1 merged\n' > "$home/state/beta.digest"
  out=$(digest_read "$home" --peek) || fail "peek failed"
  assert_contains "$out" 'SECONDMATE DIGEST' "the digest header is missing"
  assert_contains "$out" 'alpha done [key=child-pr-a1]: a1 ready' "peek missed a line"
  assert_contains "$out" 'beta done [key=merged-b1]: b1 merged' "peek missed another mate"
  out=$(digest_read "$home" --max 2) || fail "a capped read failed"
  assert_contains "$out" 'alpha done [key=merged-a1]' "a capped read did not show oldest first"
  assert_not_contains "$out" 'beta done' "a capped read showed more than its cap"
  assert_contains "$out" '1 more unread' "a capped read did not count what remains"
  out=$(digest_read "$home") || fail "a read failed"
  assert_contains "$out" 'beta done [key=merged-b1]' "the remaining line was not shown"
  assert_not_contains "$out" 'alpha' "an already shown line was shown again"
  out=$(digest_read "$home") || fail "an empty read failed"
  [ -z "$out" ] || fail "a fully read digest printed: $out"
  printf 'done [key=merged-a2]: a2 merg' >> "$home/state/alpha.digest"
  out=$(digest_read "$home") || fail "a read over a partial line failed"
  [ -z "$out" ] || fail "a line still being appended was shown: $out"
  printf 'ed\n' >> "$home/state/alpha.digest"
  out=$(digest_read "$home" alpha) || fail "a named read failed"
  assert_contains "$out" 'alpha done [key=merged-a2]: a2 merged' "a completed line was not shown"
  out=$(digest_read "$home" --all beta) || fail "an --all read failed"
  assert_contains "$out" 'beta done [key=merged-b1]' "--all did not show a read line"
  # A replaced digest is a new file: it is read from its start.
  printf 'done [key=merged-a3]: a3 merged\n' > "$home/state/alpha.digest.new"
  mv -f "$home/state/alpha.digest.new" "$home/state/alpha.digest"
  out=$(digest_read "$home") || fail "a read of a replaced digest failed"
  assert_contains "$out" 'alpha done [key=merged-a3]' "a replaced digest was not read from its start"
  digest_read "$home" --bogus >/dev/null 2>&1 && fail "an unknown flag was accepted"
  pass "the reader shows each complete line once, oldest first, and leaves a partial line unread"
}

# --- the drain presents the digest with a heartbeat only --------------------

queue_wake() {  # <home> <kind> <key> <payload>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_wake_append "$2" "$3" "$4"
  ' _ "$ROOT" "$2" "$3" "$4"
}

drain() {  # <home>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null
}

test_drain_presents_the_digest_only_with_a_heartbeat() {
  local dir="$TMP_ROOT/drain" home out
  seed_local_pair "$dir"
  home="$dir/parent"
  publish "$dir" 'done [key=merged-c1]: merged c1 https://github.com/example/repo/pull/1' \
    || fail "routine publish failed"
  queue_wake "$home" check "probe" "check: an unrelated poll result" || fail "queueing a check failed"
  out=$(drain "$home") || fail "the drain failed"
  assert_not_contains "$out" 'SECONDMATE DIGEST' "a non-heartbeat drain presented the digest"
  queue_wake "$home" heartbeat heartbeat heartbeat || fail "queueing a heartbeat failed"
  out=$(drain "$home") || fail "the heartbeat drain failed"
  assert_contains "$out" 'SECONDMATE DIGEST' "a heartbeat drain did not present the digest"
  assert_contains "$out" 'mate done [key=merged-c1]' "a heartbeat drain did not show the routine line"
  out=$(drain "$home") || fail "the repeated heartbeat drain failed"
  assert_not_contains "$out" 'key=merged-c1' "a presented digest line was presented again"
  pass "the real drain presents unread digest lines with a heartbeat and only then"
}

test_local_routine_lines_reach_the_digest_and_waking_lines_the_stream
test_answered_hold_wakes_until_the_parent_has_closed_it
test_main_home_publishes_nothing
test_remote_mirror_routes_each_line_with_the_same_rule
test_watcher_stays_quiet_while_only_the_digest_grows
test_reader_marks_what_it_shows_and_keeps_a_partial_line
test_drain_presents_the_digest_only_with_a_heartbeat
