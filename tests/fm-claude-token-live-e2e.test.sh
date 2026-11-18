#!/usr/bin/env bash
# Default-on live guard for the Claude token source (bin/fm-claude-token.sh and
# the token branch of bin/fm-worker-account-lib.sh's sign-in check) against the
# real macOS `security` tool and the real installed `claude`.
#
# Both verdicts come from vendor output - security's exit codes for a missing
# item and a locked keychain, and the JSON of `claude auth status`, whose
# authMethod is what proves the launch spends the token rather than the root's
# stored login - so a fake can only restate the assumption written into it.
# The guard stores a fake token in a throwaway keychain file under the test
# root, deletes it at the end, and never touches the login keychain.
#
# It submits no prompt and spends no tokens, so the shared live gate runs it by
# default wherever both tools are installed. Run it after every Claude upgrade
# and before trusting the "Claude token source" entry in
# docs/verification/runtime-backends.md.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_CLAUDE_TOKEN_LIVE_E2E security claude jq
# shellcheck source=bin/fm-worker-account-lib.sh
. "$ROOT/bin/fm-worker-account-lib.sh"

if [ "$(uname -s)" != Darwin ]; then
  echo "skip: live: security is not the macOS Keychain tool on this host"
  exit 0
fi

TMP_ROOT=$(fm_test_tmproot fm-claude-token-live)
export HOME="$TMP_ROOT/home"
mkdir -p "$HOME"
unset CLAUDE_CONFIG_DIR ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN
FAKE_TOKEN=fm-test-not-a-secret-live-token-7
KC="$TMP_ROOT/fm-test.keychain-db"
SOURCE="keychain:fm-live-svc/cm@$KC"
EMPTY="$TMP_ROOT/claude-empty"
mkdir -p "$EMPTY"
version=$(claude --version 2>/dev/null | head -1)

security create-keychain -p fm-test-keychain-pw "$KC" || fail "could not create the throwaway test keychain"
printf '%s\n' "$FAKE_TOKEN" | "$ROOT/bin/fm-claude-token.sh" store "$SOURCE" >/dev/null ||
  fail "security: storing a fake token into the throwaway keychain through stdin failed"

if fm_worker_account_check claude "$EMPTY" "$EMPTY" claude "" "" 2>/dev/null; then
  fail "claude $version: the pin check accepted an empty root with no token, so the token case below proves nothing"
fi
fm_worker_account_check claude "$EMPTY" "$EMPTY" claude "" "$SOURCE" ||
  fail "claude $version: the pin check refused an empty root whose account maps to a readable token"
out=$(env -i HOME="$HOME" PATH="$PATH" CLAUDE_CONFIG_DIR="$EMPTY" "$ROOT/bin/fm-claude-token.sh" exec "$SOURCE" -- claude auth status </dev/null 2>/dev/null)
method=$(printf '%s\n' "$out" | jq -r '.authMethod // empty' 2>/dev/null)
[ "$method" = oauth_token ] ||
  fail "claude $version: auth status under the loaded token reports authMethod '${method:-none}' rather than oauth_token; revisit the token branch of fm_worker_account_check"

# shellcheck disable=SC2016 # the child shell, not this test, must expand the variables in the single-quoted body
snap=$("$ROOT/bin/fm-claude-token.sh" exec "$SOURCE" -- sh -c 'ps -axww -o args=; printf "env:%s\n" "${CLAUDE_CODE_OAUTH_TOKEN:+present}"')
case "$snap" in
  *"$FAKE_TOKEN"*) fail "the token appeared in a process argument list" ;;
esac
case "$snap" in
  *"ps -axww -o args="*) ;;
  *) fail "the process snapshot did not capture even the launched command, so the argument-list proof is vacuous" ;;
esac
case "$snap" in
  *"env:present"*) ;;
  *) fail "the launched command did not receive the token in its environment" ;;
esac

security lock-keychain "$KC"
if fm_worker_account_check claude "$EMPTY" "$EMPTY" claude "" "$SOURCE" 2>"$TMP_ROOT/locked.err"; then
  fail "security: a locked keychain must refuse the pin check"
fi
grep -q "keychain is locked in this session" "$TMP_ROOT/locked.err" ||
  fail "security: the locked refusal was not classified: $(cat "$TMP_ROOT/locked.err")"
security unlock-keychain -p fm-test-keychain-pw "$KC"
if fm_worker_account_check claude "$EMPTY" "$EMPTY" claude "" "keychain:fm-live-svc/nobody@$KC" 2>"$TMP_ROOT/missing.err"; then
  fail "security: a missing item must refuse the pin check"
fi
grep -q "has no item 'nobody'" "$TMP_ROOT/missing.err" ||
  fail "security: the missing-item refusal was not classified: $(cat "$TMP_ROOT/missing.err")"
security delete-keychain "$KC" || fail "could not delete the throwaway test keychain"

pass "claude $version + macOS security: a mapped token signs an empty root in as oauth_token, never reaches argv, and a locked or missing item refuses"
echo "# claude token live guard checked: claude security"
