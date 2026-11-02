#!/usr/bin/env bash
# Lab ssh: stands in for the network hop only. It decodes fm-on.sh's remote
# entrypoint argv and runs the REAL host-local command against the lab's
# remote-secondmate home. FM_LAB_SSH_DELAY seconds of latency come first (a
# slow remote lane); the remote leg still runs to completion afterwards.
set -u
n=$(( $(cat "$FM_LAB_SSH_COUNT" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$n" > "$FM_LAB_SSH_COUNT"
stdin_file="$FM_LAB_SSH_LOG.stdin.$n"
cat > "$stdin_file"
printf "%s start t=%s pid=%s pgid=%s\n" "$n" "$(date +%s)" "$$" "$(ps -o pgid= -p $$ | tr -d ' ')" >> "$FM_LAB_SSH_LOG"
if [ -n "${FM_LAB_SSH_DELAY:-}" ]; then
  printf '%s\n' "$$" > "$FM_LAB_SSH_LOG.inflight"
  /bin/sleep "$FM_LAB_SSH_DELAY"
fi
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
shift 2
home_b64=$3
argv_b64=$4
remote_home=$(perl -MMIME::Base64=decode_base64 -e 'print decode_base64($ARGV[0])' "$home_b64")
rargs=()
while IFS= read -r -d '' a; do rargs+=("$a"); done \
  < <(perl -MMIME::Base64=decode_base64 -e 'print decode_base64($ARGV[0])' "$argv_b64")
cmd=${rargs[0]}
rc=0
env FM_HOME="$remote_home" FM_ROOT_OVERRIDE="$FM_REMOTE_CODE_ROOT" \
  "$FM_REMOTE_CODE_ROOT/bin/$cmd" "${rargs[@]:1}" < "$stdin_file" >> "$FM_LAB_SSH_LOG.remote-out" 2>&1 || rc=$?
printf "%s remote leg %s finished t=%s rc=%s\n" "$n" "$cmd" "$(date +%s)" "$rc" >> "$FM_LAB_SSH_LOG"
exit "$rc"
