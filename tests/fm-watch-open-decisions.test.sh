#!/usr/bin/env bash
# Record-age reminders through the watcher's real queue interface: the opt-in
# open-decision reminder and the always-on no-mistakes validation-start reminder.
# No endpoint, harness process, model call, or remote host is needed.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-open-decisions)
export FM_HOME="$TMP_ROOT" FM_STATE_OVERRIDE="$TMP_ROOT/state"
export FM_CONFIG_OVERRIDE="$TMP_ROOT/config"
mkdir -p "$FM_STATE_OVERRIDE" "$FM_CONFIG_OVERRIDE"
# shellcheck source=bin/fm-watch.sh
. "$ROOT/bin/fm-watch.sh"

FM_OPEN_DECISION_OVERDUE_SECS=100
FM_OPEN_DECISION_BACKOFF_MAX_SECS=400

reset_case() {
  rm -f -- "$STATE"/* "$STATE"/.[!.]* "$CONFIG"/*
  OPEN_DECISION_REMINDER=
}

count_wakes() {
  if [ -f "$FM_WAKE_QUEUE" ]; then wc -l < "$FM_WAKE_QUEUE" | tr -d ' '; else printf 0; fi
}

test_disabled() {
  reset_case
  printf 'needs-decision [at=1000] [key=api]: choose\n' > "$STATE/worker.status"
  open_decision_reminder_tick 1200
  [ "$(count_wakes)" = 0 ] || fail "disabled flag queued a reminder"
  [ ! -e "$STATE/.worker.open-decisions-cursor.timed" ] || fail "disabled flag folded status"
  pass "absent flag emits nothing and does not fold status"
}

test_oldest_and_backoff() {
  reset_case
  touch "$CONFIG/open-decision-reminders"
  printf 'needs-decision [at=1000] [key=older]: choose\nworking: continuing\n' > "$STATE/z-worker.status"
  printf 'blocked [at=1050] [key=newer]: help\n' > "$STATE/a-worker.status"
  open_decision_reminder_tick 1099
  [ "$(count_wakes)" = 0 ] || fail "not-yet-overdue key queued a reminder"
  open_decision_reminder_tick 1200
  [ "$(count_wakes)" = 1 ] || fail "oldest overdue key did not queue exactly one wake"
  [ "$OPEN_DECISION_REMINDER" = 'check: open decision overdue: z-worker key=older age=200s' ] \
    || fail "reminder did not select the oldest durable record: $OPEN_DECISION_REMINDER"
  open_decision_reminder_tick 1200
  [ "$(count_wakes)" = 2 ] || fail "another overdue key inherited the oldest key's backoff"
  open_decision_reminder_tick 1299
  [ "$(count_wakes)" = 2 ] || fail "same key repeated before its first backoff"
  open_decision_reminder_tick 1300
  [ "$(count_wakes)" = 3 ] || fail "first repeat did not become due"
  open_decision_reminder_tick 1300
  [ "$(count_wakes)" = 4 ] || fail "second key did not repeat independently"
  open_decision_reminder_tick 1499
  [ "$(count_wakes)" = 4 ] || fail "repeat interval did not double"
  open_decision_reminder_tick 1500
  open_decision_reminder_tick 1500
  [ "$(count_wakes)" = 6 ] || fail "doubled backoff did not expire"
  open_decision_reminder_tick 1899
  [ "$(count_wakes)" = 6 ] || fail "capped interval fired early"
  open_decision_reminder_tick 1900
  open_decision_reminder_tick 1900
  open_decision_reminder_tick 2300
  open_decision_reminder_tick 2300
  [ "$(count_wakes)" = 10 ] || fail "backoff did not stay bounded at the cap"
  pass "oldest key surfaces once, and independent per-key backoff doubles up to its cap"
}

assert_distinct_reminder_identities() {  # <older-task> <older-key> <newer-task> <newer-key>
  local older_task=$1 older_key=$2 newer_task=$3 newer_key=$4 now count=0
  reset_case
  touch "$CONFIG/open-decision-reminders"
  printf 'needs-decision [at=1000] [key=%s]: choose\n' "$older_key" > "$STATE/$older_task.status"
  printf 'blocked [at=1050] [key=%s]: help\n' "$newer_key" >> "$STATE/$newer_task.status"
  for now in 1200 1300 1500 1900 2300; do
    if [ "$count" -gt 0 ]; then
      open_decision_reminder_tick "$((now - 1))"
      [ "$(count_wakes)" = "$count" ] || fail "numeric-looking identity repeated before its backoff"
    fi
    open_decision_reminder_tick "$now"
    count=$((count + 1))
    [ "$(count_wakes)" = "$count" ] || fail "older numeric-looking identity did not become due"
    [ "$OPEN_DECISION_REMINDER" = "check: open decision overdue: $older_task key=$older_key age=$((now - 1000))s" ] \
      || fail "older numeric-looking identity was not selected: $OPEN_DECISION_REMINDER"
    open_decision_reminder_tick "$((now + 1))"
    count=$((count + 1))
    [ "$(count_wakes)" = "$count" ] || fail "distinct numeric-looking identity inherited another identity's backoff"
    [ "$OPEN_DECISION_REMINDER" = "check: open decision overdue: $newer_task key=$newer_key age=$((now + 1 - 1050))s" ] \
      || fail "newer numeric-looking identity was not selected: $OPEN_DECISION_REMINDER"
    open_decision_reminder_tick "$((now + 1))"
    [ "$(count_wakes)" = "$count" ] || fail "numeric-looking identity repeated without waiting"
  done
}

test_numeric_keys_are_distinct() {
  assert_distinct_reminder_identities worker 1 worker 01
  pass "keys 1 and 01 receive separate reminders and retain independent bounded backoff"
}

test_numeric_tasks_are_distinct() {
  assert_distinct_reminder_identities 1 api 01 api
  pass "tasks 1 and 01 receive separate reminders and retain independent bounded backoff"
}

test_resolution_and_reopen() {
  reset_case
  touch "$CONFIG/open-decision-reminders"
  printf 'needs-decision [at=1000] [key=api]: choose\n' > "$STATE/worker.status"
  open_decision_reminder_tick 1200
  printf 'resolved [at=1201] [key=api]: answered\n' >> "$STATE/worker.status"
  open_decision_reminder_tick 1600
  [ "$(count_wakes)" = 1 ] || fail "resolved key kept generating reminders"
  printf 'blocked [at=1600] [key=api]: new episode\n' >> "$STATE/worker.status"
  open_decision_reminder_tick 1700
  [ "$(count_wakes)" = 2 ] || fail "reopened key inherited the resolved episode's backoff"
  pass "resolution stops reminders immediately and a later episode starts fresh"
}

test_wait_exemptions() {
  reset_case
  touch "$CONFIG/open-decision-reminders"
  printf 'needs-decision [at=1000] [key=api]: choose\npaused [at=1050]: validation in flight\n' > "$STATE/paused.status"
  printf 'needs-decision [at=1000] [key=api]: choose\ncaptain-held [at=1050] [key=api]: transferred\n' > "$STATE/transferred.status"
  printf 'needs-decision [at=1000] [key=api]: choose\n' > "$STATE/backlog-held.status"
  # The watcher already delegates backlog ownership to this predicate.
  task_captain_call_open() { [ "$1" = backlog-held ]; }
  open_decision_reminder_tick 1200
  [ "$(count_wakes)" = 0 ] || fail "a declared wait or captain hold queued a reminder"
  printf 'working [at=1201]: resumed\n' >> "$STATE/paused.status"
  open_decision_reminder_tick 1201
  [ "$(count_wakes)" = 1 ] || fail "ending a pause hid the still-open key"
  pass "paused waits, verified transfers, and backlog captain holds are exempt"
}

# A child home's captain hold relayed on its parent channel is already in the
# captain's hands: the structured key prefix exempts it, never the note text.
test_relayed_captain_hold_is_exempt_by_key() {
  reset_case
  touch "$CONFIG/open-decision-reminders"
  printf 'needs-decision [key=captain-hold-api-1] [at=1000]: captain hold api: choose\n' > "$STATE/mate.status"
  printf 'needs-decision [at=1000] [key=rollout]: captain-hold-api-1 is waiting on the captain\n' > "$STATE/prose.status"
  printf 'needs-decision [at=1000] [key=x-captain-hold-1]: choose\n' > "$STATE/infix.status"
  printf 'blocked [at=1000] [key=api]: help\n' > "$STATE/worker.status"
  open_decision_reminder_tick 1200
  open_decision_reminder_tick 1200
  open_decision_reminder_tick 1200
  open_decision_reminder_tick 1200
  [ "$(count_wakes)" = 3 ] || fail "expected exactly the three non-hold keys to remind: $(cat "$FM_WAKE_QUEUE")"
  grep -F 'mate key=captain-hold-api-1' "$FM_WAKE_QUEUE" >/dev/null \
    && fail "a relayed captain-hold key queued a reminder"
  grep -F 'prose key=rollout' "$FM_WAKE_QUEUE" >/dev/null \
    || fail "note prose naming a captain hold exempted an ordinary key"
  grep -F 'infix key=x-captain-hold-1' "$FM_WAKE_QUEUE" >/dev/null \
    || fail "a key merely containing captain-hold was exempted"
  grep -F 'worker key=api' "$FM_WAKE_QUEUE" >/dev/null \
    || fail "an unrelated open key stopped reminding"
  pass "captain-hold- keys are exempt by prefix while unrelated and prose-only keys still remind"
}

# The structured [until=YYYY-MM-DD] field hold --until publishes re-arms the
# relayed key from 00:00 UTC on that date; prose and malformed fields never
# silence a key.
test_relayed_captain_hold_until_rearms() {
  reset_case
  touch "$CONFIG/open-decision-reminders"
  # 1970-01-02T00:00:00Z is epoch 86400.
  printf 'needs-decision [key=captain-hold-api-1] [until=1970-01-02] [at=1000]: captain hold api: choose\n' > "$STATE/dated.status"
  printf 'needs-decision [key=captain-hold-api-2] [at=1000]: captain hold api: revisit [until=1970-01-01]\n' > "$STATE/prose.status"
  open_decision_reminder_tick 86399
  [ "$(count_wakes)" = 0 ] || fail "a dated relayed hold reminded before its date: $(cat "$FM_WAKE_QUEUE")"
  open_decision_reminder_tick 86400
  [ "$(count_wakes)" = 1 ] || fail "a dated relayed hold did not re-arm on its date"
  [ "$OPEN_DECISION_REMINDER" = 'check: open decision overdue: dated key=captain-hold-api-1 age=85400s' ] \
    || fail "the re-armed reminder named the wrong key: $OPEN_DECISION_REMINDER"
  open_decision_reminder_tick 86400
  [ "$(count_wakes)" = 1 ] || fail "an [until=] date written in note prose re-armed a relayed hold"
  printf 'needs-decision [key=captain-hold-api-3] [until=soon] [at=1000]: captain hold api: choose\n' > "$STATE/malformed.status"
  open_decision_reminder_tick 86400
  [ "$(count_wakes)" = 2 ] || fail "a malformed [until=] field silenced a relayed hold"
  pass "a structured [until=] date re-arms a relayed hold; prose never does and a malformed one re-arms at once"
}

# A still-open key republished with only a new [at=] keeps its backoff instead
# of restarting at the threshold; a changed note is a new episode.
test_unchanged_republish_keeps_backoff() {
  reset_case
  touch "$CONFIG/open-decision-reminders"
  printf 'needs-decision [at=1000] [key=api]: choose\n' > "$STATE/worker.status"
  open_decision_reminder_tick 1200
  open_decision_reminder_tick 1300
  [ "$(count_wakes)" = 2 ] || fail "the first two reminders did not fire"
  # The next delay is now 200s. A restarted ramp would fire 100s after 1310.
  printf 'needs-decision [at=1310] [key=api]: choose\n' >> "$STATE/worker.status"
  open_decision_reminder_tick 1450
  [ "$(count_wakes)" = 2 ] || fail "an unchanged republish restarted the backoff at the threshold"
  open_decision_reminder_tick 1500
  [ "$(count_wakes)" = 3 ] || fail "the preserved backoff did not expire"
  [ "$OPEN_DECISION_REMINDER" = 'check: open decision overdue: worker key=api age=500s' ] \
    || fail "an unchanged republish lost the decision's first opened time: $OPEN_DECISION_REMINDER"
  # The next delay is now 400s, so only a new episode fires at 1700.
  printf 'needs-decision [at=1600] [key=api]: choose differently\n' >> "$STATE/worker.status"
  open_decision_reminder_tick 1700
  [ "$(count_wakes)" = 4 ] || fail "a changed note inherited the previous episode's backoff"
  [ "$OPEN_DECISION_REMINDER" = 'check: open decision overdue: worker key=api age=100s' ] \
    || fail "a changed note did not start a new episode: $OPEN_DECISION_REMINDER"
  open_decision_reminder_tick 1800
  [ "$(count_wakes)" = 5 ] || fail "the new episode did not repeat"
  # The next delay is now 200s, so only a new episode fires at 1910.
  printf 'blocked [at=1810] [key=api]: choose differently\n' >> "$STATE/worker.status"
  open_decision_reminder_tick 1910
  [ "$(count_wakes)" = 6 ] || fail "a changed verb inherited the previous episode's backoff"
  [ "$OPEN_DECISION_REMINDER" = 'check: open decision overdue: worker key=api age=100s' ] \
    || fail "a changed verb did not start a new episode: $OPEN_DECISION_REMINDER"
  pass "an unchanged republish keeps its backoff while a changed verb or note restarts it"
}

# A resolution and a same-text reopen landing between two ticks, while the
# watcher is down, is a new episode: the persisted row must not carry over.
test_resolved_same_text_reopen_starts_fresh() {
  reset_case
  touch "$CONFIG/open-decision-reminders"
  printf 'needs-decision [at=1000] [key=api]: choose\n' > "$STATE/worker.status"
  open_decision_reminder_tick 1200
  open_decision_reminder_tick 1300
  [ "$(count_wakes)" = 2 ] || fail "the first two reminders did not fire"
  printf 'resolved [at=1400] [key=api]: answered\n' >> "$STATE/worker.status"
  printf 'needs-decision [at=5000] [key=api]: choose\n' >> "$STATE/worker.status"
  restarted_tick() {
    FM_OPEN_DECISION_OVERDUE_SECS=100 FM_OPEN_DECISION_BACKOFF_MAX_SECS=400 \
      bash -c '. "$1/bin/fm-watch.sh"; open_decision_reminder_tick "$2"' _ "$ROOT" "$1"
  }
  restarted_tick 5001
  [ "$(count_wakes)" = 2 ] || fail "a reopen after resolution inherited the old episode: $(tail -1 "$FM_WAKE_QUEUE")"
  restarted_tick 5099
  [ "$(count_wakes)" = 2 ] || fail "a reopened key reminded before the threshold"
  restarted_tick 5100
  [ "$(count_wakes)" = 3 ] || fail "a reopened key did not remind at the threshold"
  tail -1 "$FM_WAKE_QUEUE" | grep -F 'worker key=api age=100s' >/dev/null \
    || fail "the reopen's age was not measured from its own time: $(tail -1 "$FM_WAKE_QUEUE")"
  restarted_tick 5199
  [ "$(count_wakes)" = 3 ] || fail "the reopened episode repeated before its reset first delay"
  restarted_tick 5200
  [ "$(count_wakes)" = 4 ] || fail "the reopened episode did not repeat at its reset first delay"
  pass "a resolution and same-text reopen between ticks starts a fresh episode across a restart"
}

# An unchanged republish keeps its opened time, but its deferral date always
# follows the newest line.
test_republish_updates_until_date() {
  reset_case
  touch "$CONFIG/open-decision-reminders"
  # 1970-01-02T00:00:00Z is epoch 86400; 1970-01-03T00:00:00Z is 172800.
  printf 'needs-decision [key=captain-hold-api-1] [until=1970-01-03] [at=1000]: captain hold api: choose\n' > "$STATE/mate.status"
  open_decision_reminder_tick 86400
  [ "$(count_wakes)" = 0 ] || fail "a dated relayed hold reminded before its date"
  printf 'needs-decision [key=captain-hold-api-1] [until=1970-01-02] [at=50000]: captain hold api: choose\n' >> "$STATE/mate.status"
  open_decision_reminder_tick 86400
  [ "$(count_wakes)" = 1 ] || fail "a republished earlier [until=] date did not re-arm the hold"
  [ "$OPEN_DECISION_REMINDER" = 'check: open decision overdue: mate key=captain-hold-api-1 age=85400s' ] \
    || fail "the republish lost its first opened time: $OPEN_DECISION_REMINDER"
  pass "a republish keeps its opened time and takes the newest deferral date"
}

test_unknown_times_and_keyless() {
  reset_case
  touch "$CONFIG/open-decision-reminders"
  printf 'needs-decision [key=missing]: choose\nblocked [at=bad] [key=bad]: help\nblocked [at=1000]: legacy\n' > "$STATE/worker.status"
  open_decision_reminder_tick 1200
  [ "$(count_wakes)" = 0 ] || fail "unknown emission time or keyless record was inferred overdue"
  pass "only explicitly keyed records with valid source timestamps are aged"
}

test_timed_fold_is_incremental() {
  reset_case
  touch "$CONFIG/open-decision-reminders"
  printf 'needs-decision [at=1000] [key=api]: choose\n' > "$STATE/worker.status"
  export FM_OPEN_DECISIONS_READ_PROBE="$TMP_ROOT/fold.reads"
  : > "$FM_OPEN_DECISIONS_READ_PROBE"
  open_decision_reminder_tick 1200
  open_decision_reminder_tick 1201
  [ "$(wc -l < "$FM_OPEN_DECISIONS_READ_PROBE" | tr -d ' ')" = 1 ] \
    || fail "unchanged poll reread the task's history"
  printf 'resolved [key=api]: answered\n' >> "$STATE/worker.status"
  open_decision_reminder_tick 1202
  [ "$(tail -1 "$FM_OPEN_DECISIONS_READ_PROBE" | cut -f2)" = 29 ] \
    || fail "resolution poll folded more than newly appended bytes"
  [ "$(count_wakes)" = 1 ] || fail "incremental resolution left a reminder live"
  unset FM_OPEN_DECISIONS_READ_PROBE
  pass "quiet polls reuse the timed fold and only new status bytes are folded"
}

test_invalid_settings() {
  reset_case
  touch "$CONFIG/open-decision-reminders"
  printf 'blocked [at=1000] [key=api]: help\n' > "$STATE/worker.status"
  if FM_OPEN_DECISION_OVERDUE_SECS=0 open_decision_reminder_tick 1200; then
    fail "zero threshold enabled an unbounded reminder loop"
  fi
  if FM_OPEN_DECISION_BACKOFF_MAX_SECS=99 open_decision_reminder_tick 1200; then
    fail "cap below the threshold was accepted"
  fi
  [ "$(count_wakes)" = 0 ] || fail "invalid settings queued a reminder"
  pass "invalid settings refuse the tick without queueing reminders"
}

test_timed_cursor_retirement() {
  reset_case
  touch "$CONFIG/open-decision-reminders"
  printf 'blocked [at=1000] [key=api]: help\n' > "$STATE/worker.status"
  open_decision_reminder_tick 1200
  status_retire_presentation_task "$STATE" worker
  [ ! -e "$STATE/.worker.open-decisions-cursor.timed" ] || fail "task retirement left its timed cursor"
  open_decision_reminder_tick 1600
  [ "$(count_wakes)" = 1 ] || fail "retired task kept generating reminders"
  pass "task retirement removes the timed cursor and ends reminders"
}

test_watcher_loop() {
  local dir="$TMP_ROOT/watcher-loop" pid i=0
  mkdir -p "$dir/state" "$dir/config"
  fm_test_track_watcher_state "$dir/state"
  touch "$dir/config/open-decision-reminders" "$dir/state/home-summary.json"
  printf 'needs-decision [at=1000] [key=api]: choose\n' > "$dir/state/worker.status"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_OPEN_DECISION_OVERDUE_SECS=100 FM_OPEN_DECISION_BACKOFF_MAX_SECS=400 \
    bash "$ROOT/bin/fm-watch.sh" > "$dir/out" 2> "$dir/err" &
  pid=$!
  while [ "$i" -lt 100 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "real watcher failed to wake on an overdue record"
  fi
  wait "$pid" || fail "real watcher exited unsuccessfully: $(cat "$dir/err")"
  grep -F 'check: open decision overdue: worker key=api age=' "$dir/out" >/dev/null \
    || fail "real watcher did not print the reminder wake"
  [ "$(wc -l < "$dir/state/.wake-queue" | tr -d ' ')" = 1 ] \
    || fail "real watcher did not durably queue exactly one reminder"
  pass "the actual watcher wakes and exits on an overdue key without any recorded pane"
}

# --- no-mistakes validation-start reminder ---------------------------------
# A stub current-state reader stands in for bin/fm-crew-state.sh, whose own
# tests pin the verdict it prints for a done: no run has validated; every call
# is logged so the tests can bound how often the reminder reads it.
NM_STUB_DIR="$TMP_ROOT/nm-stub"
mkdir -p "$NM_STUB_DIR"
cat > "$NM_STUB_DIR/fm-crew-state.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$NM_STUB_DIR/calls"
cat "$NM_STUB_DIR/$1.crew" 2>/dev/null || true
STUB
chmod +x "$NM_STUB_DIR/fm-crew-state.sh"
export NM_STUB_DIR

nm_reset() {
  reset_case
  rm -f -- "$NM_STUB_DIR"/*.crew "$NM_STUB_DIR/calls"
  NM_VALIDATION_REMINDER=
  FM_CREW_STATE_BIN="$NM_STUB_DIR/fm-crew-state.sh"
  task_captain_call_open() { return 1; }
}

nm_task() {  # <id> <kind> <mode> <status-text> [extra meta line]
  printf 'kind=%s\nmode=%s\nbranch=fm/%s\n' "$2" "$3" "$1" > "$STATE/$1.meta"
  [ -z "${5:-}" ] || printf '%s\n' "$5" >> "$STATE/$1.meta"
  printf '%s' "$4" > "$STATE/$1.status"
}

nm_crew() {  # <id> <crew-state line>
  printf '%s\n' "$2" > "$NM_STUB_DIR/$1.crew"
}

nm_not_started() {  # <id>
  nm_crew "$1" "state: blocked · source: status-log · $FM_NM_VALIDATION_NOT_STARTED · steer the worker to start /no-mistakes"
}

nm_calls() {  # [id] -> number of current-state reads (of that task)
  if [ ! -f "$NM_STUB_DIR/calls" ]; then printf 0
  elif [ -n "${1:-}" ]; then grep -cx -- "$1" "$NM_STUB_DIR/calls" || true
  else wc -l < "$NM_STUB_DIR/calls" | tr -d ' '
  fi
}

test_nm_validation_reminder_fires_once() {
  local now
  nm_reset
  nm_task worker ship no-mistakes $'done [at=1000]: implementation committed, ready to validate\n'
  nm_not_started worker
  nm_validation_start_tick 1599
  [ "$(count_wakes)" = 0 ] || fail "the reminder fired before the done: was ten minutes old"
  [ "$(nm_calls)" = 0 ] || fail "a young done: cost a current-state read"
  nm_validation_start_tick 1600
  [ "$(count_wakes)" = 1 ] || fail "a ten-minute-old done: with no run did not queue exactly one wake"
  assert_contains "$NM_VALIDATION_REMINDER" "check: no-mistakes validation not started: worker " \
    "the reminder did not name the task"
  assert_contains "$NM_VALIDATION_REMINDER" "steer the worker to run /no-mistakes now" \
    "the reminder did not tell the supervisor what to do"
  for now in 1601 1615 2200 5000 "$((1600 + PAUSE_RESURFACE_SECS - 1))"; do
    nm_validation_start_tick "$now"
  done
  [ "$(count_wakes)" = 1 ] || fail "the reminder repeated before the long recheck cadence"
  [ "$(nm_calls)" = 1 ] || fail "an already reported done: kept costing current-state reads"
  nm_validation_start_tick "$((1600 + PAUSE_RESURFACE_SECS))"
  [ "$(count_wakes)" = 2 ] || fail "an unanswered reminder was never rechecked on the long cadence"
  pass "a no-mistakes done: with no run surfaces once after ten minutes, then only on the long recheck cadence"
}

test_nm_validation_reminder_exemptions() {
  local id
  nm_reset
  nm_task live ship no-mistakes $'done [at=1000]: committed\n'
  nm_crew live 'state: working · source: run-step · validating (running) · run: r1'
  nm_task parked ship no-mistakes $'done [at=1000]: committed\n'
  nm_crew parked 'state: parked · source: run-step · parked at review: 2 finding(s) · run: r2'
  nm_task passed ship no-mistakes $'done [at=1000]: committed\n'
  nm_crew passed 'state: done · source: run-step · checks green: PR ready for review'
  nm_task busy ship no-mistakes $'done [at=1000]: committed\n'
  nm_crew busy 'state: working · source: pane · harness busy (thinking)'
  nm_task held ship no-mistakes $'done [at=1000]: committed\n'
  nm_not_started held
  task_captain_call_open() { [ "$1" = held ]; }
  nm_task registered ship no-mistakes $'done [at=1000]: committed\n' 'pr=https://github.com/o/r/pull/3'
  nm_task direct ship direct-PR $'done [at=1000]: committed\n'
  nm_task scout scout no-mistakes $'done [at=1000]: report written\n'
  nm_task resumed ship no-mistakes $'done [at=1000]: committed\npaused [at=1100]: validation round under way\n'
  nm_task remote ship no-mistakes $'done [at=1000]: committed\n' 'remote_host=far.example'
  for id in registered direct scout resumed remote; do nm_not_started "$id"; done
  nm_validation_start_tick 2000
  [ "$(count_wakes)" = 0 ] || fail "a live, parked, or passed run, a busy worker, or an exempt task raised a reminder: $NM_VALIDATION_REMINDER"
  for id in registered direct scout resumed remote; do
    [ "$(nm_calls "$id")" = 0 ] || fail "$id was read although it can never need the reminder"
  done
  nm_validation_start_tick 2599
  [ "$(nm_calls live)" = 1 ] || fail "a live run was re-read before the next interval"
  nm_not_started live
  nm_validation_start_tick 2600
  [ "$(count_wakes)" = 1 ] || fail "the run ending without a validated PR raised no reminder"
  assert_contains "$NM_VALIDATION_REMINDER" "validation not started: live " \
    "the reminder named the wrong task"
  pass "a live, parked, or passed run, a busy worker, a captain hold, a recorded PR, other modes and kinds, a later event, and a remote task raise no reminder"
}

test_nm_validation_reminder_rearms() {
  nm_reset
  nm_task worker ship '' $'done: committed\n'
  nm_not_started worker
  nm_validation_start_tick 1000
  nm_validation_start_tick 1599
  [ "$(count_wakes)" = 0 ] || fail "an unstamped done: was aged from before it was first seen"
  nm_validation_start_tick 1600
  [ "$(count_wakes)" = 1 ] || fail "an unstamped done: on an unregistered mode never surfaced"
  printf 'done [at=3000]: committed the review fix\n' >> "$STATE/worker.status"
  nm_validation_start_tick 3599
  [ "$(count_wakes)" = 1 ] || fail "a new done: inherited the previous reminder's timing"
  nm_validation_start_tick 3600
  [ "$(count_wakes)" = 2 ] || fail "a new done: did not get its own reminder"
  pass "an unstamped done: ages from first sight, and a new done: re-arms the reminder"
}

test_nm_validation_watcher_loop() {
  local dir="$TMP_ROOT/nm-watcher-loop" pid i=0
  mkdir -p "$dir/state" "$dir/config" "$dir/stub"
  fm_test_track_watcher_state "$dir/state"
  touch "$dir/state/home-summary.json"
  printf 'kind=ship\nmode=no-mistakes\nbranch=fm/worker\n' > "$dir/state/worker.meta"
  printf 'done [at=1000]: committed, ready to validate\n' > "$dir/state/worker.status"
  printf 'state: blocked · source: status-log · %s · steer the worker\n' \
    "$FM_NM_VALIDATION_NOT_STARTED" > "$dir/stub/verdict"
  printf '#!/usr/bin/env bash\ncat %q\n' "$dir/stub/verdict" > "$dir/stub/fm-crew-state.sh"
  chmod +x "$dir/stub/fm-crew-state.sh"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_CREW_STATE_BIN="$dir/stub/fm-crew-state.sh" \
    bash "$ROOT/bin/fm-watch.sh" > "$dir/out" 2> "$dir/err" &
  pid=$!
  while [ "$i" -lt 100 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "real watcher failed to wake on a done: no run validated"
  fi
  wait "$pid" || fail "real watcher exited unsuccessfully: $(cat "$dir/err")"
  grep -F 'check: no-mistakes validation not started: worker ' "$dir/out" >/dev/null \
    || fail "real watcher did not print the validation-start reminder: $(cat "$dir/out")"
  [ "$(wc -l < "$dir/state/.wake-queue" | tr -d ' ')" = 1 ] \
    || fail "real watcher did not durably queue exactly one reminder"
  pass "the actual watcher wakes and exits on a no-mistakes done: no run validated"
}

fm_test_run test_disabled test_oldest_and_backoff test_numeric_keys_are_distinct \
  test_numeric_tasks_are_distinct test_resolution_and_reopen \
  test_wait_exemptions test_relayed_captain_hold_is_exempt_by_key \
  test_relayed_captain_hold_until_rearms test_unchanged_republish_keeps_backoff \
  test_resolved_same_text_reopen_starts_fresh test_republish_updates_until_date \
  test_unknown_times_and_keyless test_timed_fold_is_incremental \
  test_invalid_settings test_timed_cursor_retirement test_watcher_loop \
  test_nm_validation_reminder_fires_once test_nm_validation_reminder_exemptions \
  test_nm_validation_reminder_rearms test_nm_validation_watcher_loop
