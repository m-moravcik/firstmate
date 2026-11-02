# Lab driver helpers for the fm-send interruption scenarios. Sourced.
ROOT={run-worktree}
LAB=$(cat /tmp/fm-intr-lab-path.txt)
SESSION=$(cat "$LAB/session")
PH="$LAB/parent"
RH="$LAB/rsm-home"
E=~/.no-mistakes/evidence/01M6F11XX4K2F14N2ZSE62WH6B
SEND="$ROOT/bin/fm-send.sh"

# A local task t<id> on the lab Herdr pane.
make_task() {  # <task-id>
  cat > "$PH/state/$1.meta" <<EOF
window=$SESSION:w1:p1
endpoint_task_id=$1
harness=claude
kind=ship
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=w1
herdr_tab_id=w1:t1
herdr_pane_id=w1:p1
spawn_gen=1
EOF
}

# Start the REAL fm-send in its own process group with INT/QUIT at default,
# exactly as a harness tool call runs it, so the caller's timeout signal can be
# delivered to the whole tree. Sets BG_PID.
start_send() {  # <scen-dir> [env...] -- <fm-send args...>
  local d=$1 envs=()
  shift
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  mkdir -p "$d"
  : > "$d/ssh.log"
  {
    printf '$ FM_HOME=%q %q' "$PH" "$SEND"
    printf ' %q' "$@"
    printf '\n'
  } > "$d/cmd.txt"
  perl -e '$SIG{INT} = $SIG{QUIT} = "DEFAULT"; setpgrp(0, 0); exec @ARGV or die "exec: $!\n"' \
    env -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
    -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    PATH="$LAB/bin:$PATH" FM_HOME="$PH" \
    FM_SSH_BIN="$LAB/bin/lab-ssh" FM_LAB_SSH_LOG="$d/ssh.log" FM_LAB_SSH_COUNT="$d/ssh.count" \
    FM_REMOTE_CODE_ROOT="$ROOT" \
    ${envs[@]+"${envs[@]}"} "$SEND" "$@" >"$d/out" 2>"$d/err" &
  BG_PID=$!
  echo "$BG_PID" > "$d/pid"
}

wait_for() {  # <seconds> <cmd...>  poll until cmd succeeds
  local limit=$1 i=0
  shift
  while ! "$@"; do
    i=$((i + 1))
    [ "$i" -le $((limit * 10)) ] || return 1
    /bin/sleep 0.1
  done
}

has_text() { grep -qF -- "$2" "$1" 2>/dev/null; }
nonempty() { [ -s "$1" ]; }

# Signal the sender's whole process group like a caller timeout and reap it.
interrupt() {  # <scen-dir> <SIG>
  local d=$1 sig=$2 rc=0
  printf '%s caller sends SIG%s to process group -%s\n' "$(date +%T)" "$sig" "$BG_PID" >> "$d/timeline"
  kill -s "$sig" -- "-$BG_PID"
  wait "$BG_PID" || rc=$?
  echo "$rc" > "$d/rc"
  printf '%s fm-send exited rc=%s\n' "$(date +%T)" "$rc" >> "$d/timeline"
}

pending_file() { find "$PH/state/pending-replies" -maxdepth 1 -type f ! -name '.*' 2>/dev/null | sort; }
pending_field() {  # <file> <key>
  sed -n "s/^$2=//p" "$1" | head -1
}
inbox_list() { find "$1" -name '*.msg' 2>/dev/null | sort; }
