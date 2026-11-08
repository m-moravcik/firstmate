#!/usr/bin/env bash
# Live drive: real child home `fm-captain-hold.sh hold [--until]` publishing to a
# real parent home's channel, then the real parent `fm-watch.sh` process and its
# reminder tick (with explicit clocks) against that persisted state.
set -u
ROOT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
P="$LAB/parent"; M="$LAB/mate"
for h in "$P" "$M"; do
  mkdir -p "$h/data" "$h/state" "$h/config" "$h/projects" "$h/fakebin"
  printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n' > "$h/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$h/data/backlog.md"
  for t in tmux treehouse no-mistakes gh gh-axi; do printf '#!/usr/bin/env bash\nexit 0\n' > "$h/fakebin/$t"; chmod +x "$h/fakebin/$t"; done
done
printf '# Synthetic secondmate home\n' > "$M/AGENTS.md"
printf 'labmate\n' > "$M/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$P" > "$M/.fm-secondmate-parent"
captain() { PATH="$M/fakebin:$PATH" REAL_TASKS_AXI="$(command -v tasks-axi)" FM_HOME="$M" \
  FM_STATE_OVERRIDE="$M/state" FM_DATA_OVERRIDE="$M/data" FM_CONFIG_OVERRIDE="$M/config" \
  "$ROOT/bin/fm-captain-hold.sh" "$@"; }
TOMORROW=$(date -u -v+1d +%F 2>/dev/null || date -u -d tomorrow +%F)
echo "== S1/S2: child holds published to parent channel"
captain hold plain-call --title "Choose plain" --reason "plain choice pending" --repo sample >/dev/null; echo "hold plain rc=$?"
captain hold dated-call --title "Choose dated" --reason "dated choice pending" --repo sample --until "$TOMORROW" >/dev/null; echo "hold --until $TOMORROW rc=$?"
echo "-- parent channel $P/state/labmate.status:"; cat "$P/state/labmate.status"
touch "$P/config/open-decision-reminders" "$P/state/home-summary.json"
watch_env() { env FM_HOME="$P" FM_STATE_OVERRIDE="$P/state" FM_CONFIG_OVERRIDE="$P/config" \
  FM_OPEN_DECISION_OVERDUE_SECS=1 FM_OPEN_DECISION_BACKOFF_MAX_SECS=86400 "$@"; }
sleep 2
echo "== S1: real watcher with only relayed captain holds overdue (6s window)"
set -m; watch_env bash "$ROOT/bin/fm-watch.sh" > "$LAB/w1.out" 2> "$LAB/w1.err" & pid=$!; set +m
i=0; while [ $i -lt 60 ] && kill -0 $pid 2>/dev/null; do sleep 0.1; i=$((i+1)); done
if kill -0 $pid 2>/dev/null; then echo "watcher still waiting after 6s (no reminder) -> PASS"; kill -- -$pid; wait $pid 2>/dev/null
  # the watcher's own subshells exit asynchronously; let its lock become reclaimable
  j=0; while [ $j -lt 100 ] && ps -ax -o pgid= | grep -qw "$pid"; do sleep 0.1; j=$((j+1)); done; echo "watcher processes gone after $j polls"; ls -la "$P/state/.watch.lock" 2>&1 | head -3
else wait $pid; echo "watcher EXITED rc=$? -> FAIL"; cat "$LAB/w1.out"; fi
echo "wake queue lines: $( [ -f "$P/state/.wake-queue" ] && wc -l < "$P/state/.wake-queue" || echo 0)"
echo "== S1b: an ordinary overdue key in the same parent still wakes the real watcher"
printf 'needs-decision [key=rollout] [at=%s]: captain-hold-plain-call-1 is waiting on the captain\n' "$(( $(date +%s) - 10 ))" > "$P/state/worker.status"
watch_env bash "$ROOT/bin/fm-watch.sh" > "$LAB/w2.out" 2> "$LAB/w2.err" & pid=$!
i=0; while [ $i -lt 100 ] && kill -0 $pid 2>/dev/null; do sleep 0.1; i=$((i+1)); done
if kill -0 $pid 2>/dev/null; then kill $pid; wait $pid 2>/dev/null; echo "watcher did not wake -> FAIL"; else wait $pid; echo "watcher exit rc=$?"; fi
echo "watcher stdout:"; cat "$LAB/w2.out"; echo "wake queue:"; cat "$P/state/.wake-queue" 2>/dev/null
rm -f "$P/state/worker.status"
tick() { watch_env bash -c '. "$1/bin/fm-watch.sh"; open_decision_reminder_tick "$2"; echo "  tick now=$2 -> ${OPEN_DECISION_REMINDER:-<none>}"' _ "$ROOT" "$1"; }
REARM=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "${TOMORROW}T00:00:00Z" +%s)
echo "== S2: dated relayed hold re-arms at 00:00 UTC $TOMORROW (epoch $REARM); plain hold never"
: > "$P/state/.wake-queue"
tick $((REARM - 1)); tick "$REARM"; tick $((REARM + 100000))
echo "== S3: malformed [until=] on a relayed hold re-arms at once (adversarial)"
printf 'needs-decision [key=captain-hold-bad-1] [until=next-week] [at=%s]: captain hold bad: choose\n' "$(date +%s)" > "$P/state/bad.status"
tick $(( $(date +%s) + 5 )); rm -f "$P/state/bad.status"
echo "== S4: unchanged republish keeps backoff; resolve+same-text reopen is fresh (threshold 100, cap 400)"
S="$P/state/w.status"; rm -f "$P/state/.open-decision-reminders"
tick4() { env FM_HOME="$P" FM_STATE_OVERRIDE="$P/state" FM_CONFIG_OVERRIDE="$P/config" FM_OPEN_DECISION_OVERDUE_SECS=100 FM_OPEN_DECISION_BACKOFF_MAX_SECS=400 \
  bash -c '. "$1/bin/fm-watch.sh"; open_decision_reminder_tick "$2"; echo "  tick now=$2 -> ${OPEN_DECISION_REMINDER:-<none>}"' _ "$ROOT" "$1"; }
mv "$P/state/labmate.status" "$LAB/labmate.status.bak"
printf 'needs-decision [at=1000] [key=api]: choose\n' > "$S"
tick4 1200; tick4 1300
echo "  + republish same text [at=1310]"; printf 'needs-decision [at=1310] [key=api]: choose\n' >> "$S"
tick4 1410; tick4 1450; tick4 1500
echo "  ledger: $(cat "$P/state/.open-decision-reminders")"
echo "  + resolved, then same-text reopen [at=5000] between ticks (separate processes)"
printf 'resolved [at=1600] [key=api]: answered\nneeds-decision [at=5000] [key=api]: choose\n' >> "$S"
tick4 5001; tick4 5099; tick4 5100; tick4 5199; tick4 5200
echo "  + changed note [at=5210]"; printf 'needs-decision [at=5210] [key=api]: choose B\n' >> "$S"
tick4 5309; tick4 5310
