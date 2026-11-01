#!/usr/bin/env bash
# Drive the real fm-watch.sh against disposable homes. Usage: drive.sh <repo-root> <work-dir>
set -u
ROOT=$1; W=$2; mkdir -p "$W/drain-root"
export FM_PROCEVENT_CLAIM_ROOT="$W/claims"
unset FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS TMUX
say() { printf '%s\n' "$*"; }
watch_once() {  # <dir> <out> [extra env...]
  local dir=$1 out=$2 pid i=0; shift 2
  env FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_OPEN_DECISION_OVERDUE_SECS=100 FM_OPEN_DECISION_BACKOFF_MAX_SECS=400 FM_SIGNAL_GRACE=1 "$@" \
    bash "$ROOT/bin/fm-watch.sh" > "$out" 2> "$out.err" &
  pid=$!
  while [ "$i" -lt "${WAIT_TICKS:-300}" ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then kill "$pid"; wait "$pid" 2>/dev/null; return 124; fi
  wait "$pid"
}
drain() { local dir=$1; shift; FM_ROOT_OVERRIDE="$W/drain-root" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" "$ROOT/bin/fm-wake-drain.sh" "$@"; }
ack_all() {
  local dir=$1 s g
  drain "$dir" >/dev/null 2> "$dir/d.err" || return 1
  s=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*$/\1/p' "$dir/d.err")
  g=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$dir/d.err")
  drain "$dir" --ack-through "$s" --recovery-generation "$g" >/dev/null 2>&1
}
# Surface + acknowledge an aged decision with reminders still off.
setup() {
  local dir=$1; mkdir -p "$dir/state" "$dir/config"; touch "$dir/state/home-summary.json"
  printf 'needs-decision [at=1000] [key=api]: choose\n' > "$dir/state/worker.status"
  watch_once "$dir" "$dir/surface.out" || return 1
  ack_all "$dir" || return 1
  [ ! -s "$dir/state/.wake-queue" ]
}
queue() { cut -f3- "$1/state/.wake-queue" 2>/dev/null; }
mt() { stat -f %m "$1" 2>/dev/null || echo none; }
old() { touch -t 202001010000 "$1"; }

case_custom_check() {
  local d="$W/custom"; setup "$d" || { say "SETUP FAILED"; return; }
  printf '#!/bin/sh\necho ping-from-custom-check\n' > "$d/state/probe.check.sh"; chmod 700 "$d/state/probe.check.sh"
  FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" "$ROOT/bin/fm-check-register.sh" probe || say "register failed"
  old "$d/state/.last-check"; touch "$d/config/open-decision-reminders"
  say "before: .last-check mtime=$(mt "$d/state/.last-check")"
  watch_once "$d" "$d/out"; say "watcher exit=$?"
  say "watcher stdout (the delivered wake):"; sed 's/^/  | /' "$d/out"
  say "after: .last-check mtime=$(mt "$d/state/.last-check")"
  say "durable wake queue (kind, key, reason):"; queue "$d" | sed 's/^/  | /'
  say "drain presents:"; drain "$d" 2>/dev/null | grep -E 'open decision overdue|ping-from' | sed 's/^/  | /'
}
case_signal_scan() {
  local d="$W/signal"; setup "$d" || { say "SETUP FAILED"; return; }
  touch "$d/config/open-decision-reminders"
  printf 'done: shipped the fix PR\n' > "$d/state/worker2.status"
  watch_once "$d" "$d/out"; say "watcher exit=$?"
  say "watcher stdout (the delivered wake):"; sed 's/^/  | /' "$d/out"
  say "durable wake queue:"; queue "$d" | sed 's/^/  | /'
  say "drain presents:"; drain "$d" 2>/dev/null | grep -E 'open decision overdue|worker2' | sed 's/^/  | /'
}
case_heartbeat() {
  local d="$W/heartbeat"; setup "$d" || { say "SETUP FAILED"; return; }
  touch "$d/config/open-decision-reminders"; old "$d/state/.last-heartbeat"
  : > "$d/state/.watch-triage.log"
  say "before: .last-heartbeat mtime=$(mt "$d/state/.last-heartbeat") streak=$(cat "$d/state/.heartbeat-streak" 2>/dev/null)"
  watch_once "$d" "$d/out" FM_HEARTBEAT=1; say "watcher exit=$?"
  say "watcher stdout:"; sed 's/^/  | /' "$d/out"
  say "after: .last-heartbeat mtime=$(mt "$d/state/.last-heartbeat")"
  say "triage log:"; sed 's/^/  | /' "$d/state/.watch-triage.log"
  say "durable wake queue:"; queue "$d" | sed 's/^/  | /'
}
case_backoff() {
  local d="$W/backoff"; setup "$d" || { say "SETUP FAILED"; return; }
  touch "$d/config/open-decision-reminders"
  watch_once "$d" "$d/out1"; say "run 1 exit=$?"; sed 's/^/  | /' "$d/out1"
  say "ledger after run 1 (task key opened last delay):"; sed 's/^/  | /' "$d/state/.open-decision-reminders"
  ack_all "$d" || say "ack failed"
  WAIT_TICKS=60 watch_once "$d" "$d/out2"; say "run 2 (6s window, within backoff) exit=$? (124 = still polling, no wake)"
  say "run 2 stdout:"; sed 's/^/  | /' "$d/out2"
  say "queue after run 2 (expect empty):"; queue "$d" | sed 's/^/  | /'
  say "ledger after run 2:"; sed 's/^/  | /' "$d/state/.open-decision-reminders"
  # Age the ledger's last-sent stamp past the 100s backoff and run again: delay must double to 200.
  awk -F '\t' -v OFS='\t' '{ $4 = $4 - 150 } 1' "$d/state/.open-decision-reminders" > "$d/l.tmp" && mv "$d/l.tmp" "$d/state/.open-decision-reminders"
  watch_once "$d" "$d/out3"; say "run 3 (backoff elapsed) exit=$?"; sed 's/^/  | /' "$d/out3"
  say "ledger after run 3 (expect delay 200):"; sed 's/^/  | /' "$d/state/.open-decision-reminders"
}
case_downtime() {
  local d="$W/downtime"; setup "$d" || { say "SETUP FAILED"; return; }
  touch "$d/config/open-decision-reminders"
  # An undelivered row left behind by a prior watcher episode.
  FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" bash -c ". '$ROOT/bin/fm-wake-lib.sh'; fm_wake_append check leftover 'check: leftover row from before downtime'" || say "append failed"
  watch_once "$d" "$d/out"; say "watcher exit=$?"
  say "watcher stdout:"; sed 's/^/  | /' "$d/out"
  say "durable wake queue:"; queue "$d" | sed 's/^/  | /'
  say "drain presents:"; drain "$d" 2>/dev/null | grep -E 'open decision overdue|leftover' | sed 's/^/  | /'
}
for c in ${CASES:-custom_check signal_scan heartbeat backoff downtime}; do say "=== $c ($ROOT) ==="; "case_$c"; done
