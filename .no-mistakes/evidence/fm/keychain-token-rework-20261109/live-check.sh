#!/usr/bin/env bash
set -eu
ROOT=$PWD
LAB="$ROOT/.local-test-tmp/live"
mkdir -p "$LAB/config" "$LAB/account" "$LAB/user"
export HOME="$LAB/user" TMPDIR="$ROOT/.local-test-tmp" CLAUDE_CONFIG_DIR="$LAB/account"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN
printf '{"apiKeyHelper":"echo sk-ant-fm-live-synthetic"}\n' > "$LAB/account/settings.json"
printf '%s\t%s\n' "$LAB/account" claude-account-credential-source-lab.json > "$LAB/config/claude-accounts"
printf '{"claude":{"source":"macos-keychain","service":"fm-gate-missing-01M77CJD9DBE1FEVRVFCA8N11F","account":"disposable-lab-nonexistent"}}\n' > "$LAB/config/claude-account-credential-source-lab.json"
. "$ROOT/bin/fm-worker-account-lib.sh"
printf 'Real Claude: '
claude --version
printf '\nBaseline: selected root has a working synthetic apiKeyHelper auth method\n'
env -i HOME="$HOME" PATH="$PATH" TMPDIR="$TMPDIR" CLAUDE_CONFIG_DIR="$LAB/account" claude auth status </dev/null
check_refusal() {
  local expected=$1 out rc
  shift
  set +e
  out=$("$@" 2>&1)
  rc=$?
  set -e
  printf '\n%s\nexit=%s\n%s\n' "$expected" "$rc" "$out"
  [ "$rc" -ne 0 ]
  case "$out" in *"$expected"*) ;; *) exit 1 ;; esac
}
check_refusal 'must name one with --account' fm_worker_account_select claude "$LAB/config" default claude '' '' ''
check_refusal 'not declared' fm_worker_account_select claude "$LAB/config" default claude '' '' "$LAB/undeclared"
check_refusal 'token could not be loaded' fm_worker_account_select claude "$LAB/config" default claude '' '' "$LAB/account"
check_refusal 'is unavailable' "$ROOT/bin/fm-claude-token.sh" exec "$LAB/config/claude-account-credential-source-lab.json" -- /usr/bin/printf 'FORBIDDEN_FALLBACK_COMMAND_RAN\n'
printf '\nAll real-tool refusal checks passed; no worker or session was started.\n'
