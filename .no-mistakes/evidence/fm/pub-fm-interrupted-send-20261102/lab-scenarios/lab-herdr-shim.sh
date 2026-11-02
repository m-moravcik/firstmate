#!/usr/bin/env bash
# Lab shim: every product Herdr call goes through the guarded lab helper,
# bound to the one lab session; an optional FM_LAB_HERDR_DELAY makes a
# pane input call slow (a wedged multiplexer) for the doorbell-window scenario.
set -euo pipefail
helper='{run-worktree}/bin/fm-herdr-lab.sh'
session='fm-lab-intr-21185-28119'
real_path='/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/System/Cryptexes/App/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin:/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/local/bin:/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/bin:/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/appleinternal/bin:/pkg/env/global/bin:/Library/Apple/usr/bin:/opt/homebrew/bin:/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home/bin:~/Library/Android/sdk/platform-tools:~/Library/Android/sdk/emulator:~/Library/Android/sdk/cmdline-tools/latest/bin:/opt/homebrew/sbin:~/.local/bin:~/.local/share/mise/shims:~/.bun/bin:~/go/bin:~/.cargo/bin:~/bin:/usr/local/sbin:~/.docker/bin:/Applications/Obsidian.app/Contents/MacOS:~/.docker/bin:~/.local/bin:/Applications/Obsidian.app/Contents/MacOS:~/.docker/bin'
args=("$@")
n=${#args[@]}
if [ "$n" -ge 2 ] && [ "${args[$((n-2))]}" = --session ]; then
  [ "${args[$((n-1))]}" = "$session" ] || { echo "lab shim refused foreign session" >&2; exit 97; }
  args=("${args[@]:0:$((n-2))}")
else
  [ "${HERDR_SESSION:-}" = "$session" ] || { echo "lab shim requires the lab session" >&2; exit 98; }
  for arg in "${args[@]}"; do
    case "$arg" in --session|--session=*) echo "lab shim refused non-trailing session flag" >&2; exit 99 ;; esac
  done
fi
printf '%s\n' "${args[*]}" >> '/var/folders/tl/by9l0xps3l32hcp1fdnjk1080000gp/T/fm-lab.JFTdzI/logs/herdr-calls.log'
if [ -n "${FM_LAB_HERDR_DELAY:-}" ] && [ "${args[0]:-} ${args[1]:-}" = "${FM_LAB_HERDR_DELAY_ON:-pane send-text}" ]; then
  printf '%s\n' "$$" > "$FM_LAB_HERDR_DELAY_MARK"
  /bin/sleep "$FM_LAB_HERDR_DELAY"
fi
PATH="$real_path" exec "$helper" run "$session" "${args[@]}"
