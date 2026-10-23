#!/usr/bin/env bash
# Drain and acknowledge every queued wake the way the primary does after handling it.
cd ~/.no-mistakes/worktrees/38ab7cb04e39/01M5M5NXPGRYZC4CSDVTA3CPA6 || exit 1
out=$("/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.mjVst0/harness/labenv.sh" bin/fm-wake-drain.sh 2>&1)
ack=$(printf '%s\n' "$out" | sed -n 's/^WAKE_ACK_REQUIRED: after handling completes run bin\/fm-wake-drain.sh //p' | tail -1)
[ -z "$ack" ] || "/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.mjVst0/harness/labenv.sh" bin/fm-wake-drain.sh $ack >/dev/null 2>&1
printf 'drained; ack: %s\n' "${ack:-none needed}"
