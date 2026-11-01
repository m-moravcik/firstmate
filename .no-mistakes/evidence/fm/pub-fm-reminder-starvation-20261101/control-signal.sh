#!/usr/bin/env bash
set -u; ROOT=$1; W=$2
. /dev/stdin <<<"$(sed -n '/^watch_once()/,/^queue()/p' /tmp/fm-scen-scripts/drive.sh)"
export FM_PROCEVENT_CLAIM_ROOT="$W/claims"; mkdir -p "$W/drain-root"
d="$W/ctl"; setup "$d" || { echo SETUP FAILED; exit 1; }
printf 'done: shipped the fix PR\n' > "$d/state/worker2.status"
watch_once "$d" "$d/out"; echo "exit=$?"; sed 's/^/  | /' "$d/out"; echo queue:; queue "$d" | sed 's/^/  | /'
