#!/usr/bin/env bash
# Behavior tests for bin/fm-claude-token.sh: loading a pinned Claude account's
# long-lived OAuth token from a Keychain source reference or a credential-source
# declaration file into one process's environment, checking a source, and
# storing a token read from standard input.
#
# A fake `security` on PATH (tests/lib.sh fm_fake_security) plays the macOS
# Keychain tool with the exit codes the real one gives, backed by a plain
# directory, so every case runs on Linux too. On macOS one case repeats the
# store, check, exec, locked and missing round trip against the real
# /usr/bin/security with a throwaway keychain file created and deleted under
# the test root. Every token here is a fake fixture.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOKEN_SH="$ROOT/bin/fm-claude-token.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-token)
STORE="$TMP_ROOT/fake-keychain"
CALLS="$TMP_ROOT/security-calls"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
fm_fake_security "$FAKEBIN" "$STORE" "$CALLS"
FAKE_TOKEN=fm-test-not-a-secret-token-0123456789
BASE_PATH=$PATH
unset CLAUDE_CODE_OAUTH_TOKEN

# run_token [args...]: the helper with the fake security first on PATH; stdout
# and stderr are merged so a case can assert on both at once.
run_token() {
  PATH="$FAKEBIN:$BASE_PATH" "$TOKEN_SH" "$@" 2>&1
}

# item <name> <value>: a generic-password item in the fake store.
item() {
  printf '%s\n' "$2" > "$STORE/$1"
}

# assert_token_nowhere <msg>: the fake token appears in no file under the test
# root except the store's own items.
assert_token_nowhere() {
  local hits
  hits=$(grep -rlF -- "$FAKE_TOKEN" "$TMP_ROOT" 2>/dev/null | grep -v "^$STORE/" || true)
  [ -z "$hits" ] || fail "$1: $hits"
}

test_usage_errors_refuse_before_touching_the_keychain() {
  local out rc bad
  out=$(run_token); rc=$?
  expect_code 2 "$rc" "no arguments is a usage error"
  assert_contains "$out" "usage:" "no arguments should print the usage"
  out=$(run_token --help); rc=$?
  expect_code 0 "$rc" "--help should succeed"
  assert_contains "$out" "fm-claude-token.sh exec <source> -- <command>" "--help should print the usage"
  for bad in 'keychain:fm-svc' 'keychain:/cm' 'keychain:fm-svc/' 'file:/tmp/x' 'keychain:fm svc/cm' \
    'keychain:fm-svc/cm@relative.keychain-db' 'keychain:fm-svc/cm@/tmp/with space.keychain-db' 'keychain:-svc/cm' ''; do
    out=$(run_token check "$bad"); rc=$?
    expect_code 2 "$rc" "source '$bad' must be a usage error"
    assert_contains "$out" "keychain:<service>/<account>[@<keychain-file>]" "the refusal of '$bad' should state the grammar"
  done
  out=$(run_token exec keychain:fm-svc/cm); rc=$?
  expect_code 2 "$rc" "exec without a command is a usage error"
  out=$(run_token exec keychain:fm-svc/cm --); rc=$?
  expect_code 2 "$rc" "exec with an empty command is a usage error"
  out=$(run_token exec keychain:fm-svc/cm sh -c true); rc=$?
  expect_code 2 "$rc" "exec needs the -- separator"
  out=$(run_token exec keychain:fm-svc/cm -- -i sh -c true); rc=$?
  expect_code 2 "$rc" "a command that starts with an option is a usage error"
  assert_contains "$out" "must not start with" "the refusal should say the command cannot start with an option"
  out=$(run_token frobnicate keychain:fm-svc/cm); rc=$?
  expect_code 2 "$rc" "an unknown subcommand is a usage error"
  out=$(run_token check keychain:fm-svc/cm extra); rc=$?
  expect_code 2 "$rc" "an extra argument is a usage error"
  assert_absent "$CALLS" "no usage error may consult the keychain"
  pass "usage errors refuse before the keychain is consulted"
}

# The shared credential-source adapter runs only on Darwin with `security` on
# PATH, so the declaration-file cases report Darwin to `uname -s` everywhere.
fake_darwin() {
  local real
  real=$(command -v uname)
  cat > "$FAKEBIN/uname" <<SH
#!/usr/bin/env bash
[ "\$*" != -s ] || { printf '%s\n' Darwin; exit 0; }
exec '$real' "\$@"
SH
  chmod +x "$FAKEBIN/uname"
}

test_a_declaration_file_source_checks_loads_and_refuses() {
  local out rc decl="$TMP_ROOT/claude-account-credential-source.json"
  fake_darwin
  item fm-decl.worker "$FAKE_TOKEN"
  printf '%s\n' '{"claude":{"source":"macos-keychain","service":"fm-decl","account":"worker"}}' > "$decl"
  out=$(run_token check "$decl"); rc=$?
  expect_code 0 "$rc" "check should accept a readable declaration file: $out"
  assert_contains "$out" "token: readable" "check should report the declaration file readable"
  assert_not_contains "$out" "$FAKE_TOKEN" "check must never print the token"
  # shellcheck disable=SC2016 # the child shell, not this test, must expand the variable in the single-quoted body
  out=$(run_token exec "$decl" -- sh -c 'printf "%s" "${CLAUDE_CODE_OAUTH_TOKEN:+present}"'); rc=$?
  expect_code 0 "$rc" "exec should load a declaration file's token: $out"
  assert_equals present "$out" "the command should receive the token in its environment"
  out=$(printf '%s\n' "$FAKE_TOKEN" | run_token store "$decl"); rc=$?
  expect_code 2 "$rc" "store takes a keychain: reference only"
  assert_contains "$out" "store takes a keychain: reference" "the refusal should say which form store takes"
  out=$(run_token check claude-account-credential-source.json); rc=$?
  expect_code 2 "$rc" "a relative declaration path is a usage error"
  rm "$STORE/fm-decl.worker"
  out=$(run_token exec "$decl" -- sh -c 'echo launched'); rc=$?
  expect_code 3 "$rc" "a declaration file whose item is missing must refuse"
  assert_contains "$out" "is unavailable" "the refusal should say the source is unavailable"
  assert_not_contains "$out" "launched" "exec must never run the command after a refusal"
  printf '{\n' > "$decl"
  out=$(run_token check "$decl"); rc=$?
  expect_code 3 "$rc" "a malformed declaration file must refuse"
  assert_contains "$out" "malformed declaration" "the refusal should name the malformed declaration"
  rm -f "$decl" "$FAKEBIN/uname"
  pass "a declaration file is checked and loaded like a keychain reference, refuses without running the command, and store keeps to references"
}

test_an_inherited_xtrace_never_prints_the_token() {
  local out rc
  item fm-svc.cm "$FAKE_TOKEN"
  out=$(PATH="$FAKEBIN:$BASE_PATH" bash -x "$TOKEN_SH" exec keychain:fm-svc/cm -- true 2>&1); rc=$?
  expect_code 0 "$rc" "exec under an inherited xtrace should still run the command: $out"
  assert_not_contains "$out" "$FAKE_TOKEN" "an inherited xtrace must never print the token"
  assert_contains "$out" "exec env true" "tracing should be restored for the command the helper runs"
  out=$(PATH="$FAKEBIN:$BASE_PATH" bash -x "$TOKEN_SH" check keychain:fm-svc/cm 2>&1); rc=$?
  expect_code 0 "$rc" "check under an inherited xtrace should succeed"
  assert_not_contains "$out" "$FAKE_TOKEN" "check under an inherited xtrace must never print the token"
  rm "$STORE/fm-svc.cm"
  pass "an inherited xtrace never prints the token, and exec restores tracing for its command"
}

test_exec_loads_the_token_into_the_child_environment_and_never_into_argv() {
  local out rc first rest
  item fm-svc.cm "$FAKE_TOKEN"
  # shellcheck disable=SC2016 # the child shell, not this test, must expand the variables in the single-quoted body
  out=$(run_token exec keychain:fm-svc/cm -- sh -c 'printf "%s\n" "${CLAUDE_CODE_OAUTH_TOKEN-unset}"; ps -o args= -p "$$,$PPID"'); rc=$?
  expect_code 0 "$rc" "exec should run the command: $out"
  first=$(printf '%s\n' "$out" | head -1)
  rest=$(printf '%s\n' "$out" | tail -n +2)
  assert_equals "$FAKE_TOKEN" "$first" "the command should receive the token in its environment"
  assert_contains "$rest" "ps -o args=" "the process listing should show the launched command's own arguments"
  assert_not_contains "$rest" "$FAKE_TOKEN" "no process argument list may hold the token"
  out=$(run_token exec keychain:fm-svc/cm -- true); rc=$?
  expect_code 0 "$rc" "exec should pass a silent command's success through"
  assert_equals "" "$out" "the helper itself must print nothing on success"
  out=$(run_token exec keychain:fm-svc/cm -- sh -c 'exit 7'); rc=$?
  expect_code 7 "$rc" "exec should pass the command's exit status through"
  # shellcheck disable=SC2016 # the child shell, not this test, must expand the variables in the single-quoted body
  out=$(run_token exec keychain:fm-svc/cm -- FM_PROBE=bar sh -c 'printf "%s %s\n" "$FM_PROBE" "$CLAUDE_CODE_OAUTH_TOKEN"'); rc=$?
  expect_code 0 "$rc" "exec should accept leading assignments the way a raw launch command carries them"
  assert_equals "bar $FAKE_TOKEN" "$out" "leading assignments should apply beside the token"
  # shellcheck disable=SC2016 # the child shell, not this test, must expand the variables in the single-quoted body
  out=$(CLAUDE_CODE_OAUTH_TOKEN=ambient-caller-token run_token exec keychain:fm-svc/cm -- sh -c 'printf "%s" "$CLAUDE_CODE_OAUTH_TOKEN"')
  assert_equals "$FAKE_TOKEN" "$out" "the source's token must replace a token already in the caller's environment"
  item 'fleet.keychain-db@fm-svc.cm' "$FAKE_TOKEN"
  : > "$CALLS"
  # shellcheck disable=SC2016 # the child shell, not this test, must expand the variables in the single-quoted body
  out=$(run_token exec keychain:fm-svc/cm@/Users/nobody/fleet.keychain-db -- sh -c 'printf "%s" "$CLAUDE_CODE_OAUTH_TOKEN"'); rc=$?
  expect_code 0 "$rc" "a source naming a keychain file should read from that file: $out"
  assert_equals "$FAKE_TOKEN" "$out" "the keychain-file source should load its own item"
  assert_equals "find-generic-password -s fm-svc -a cm /Users/nobody/fleet.keychain-db" "$(cat "$CALLS")" \
    "the read should name the service, the account and the keychain file, and nothing else"
  assert_token_nowhere "exec must leave the token in no file"
  pass "exec loads the token into the command's environment only, with the command's own status, assignments and keychain file honored"
}

test_exec_and_check_refuse_a_missing_locked_slow_or_malformed_item() {
  local out rc marker="$TMP_ROOT/child-ran" value
  item fm-svc.cm "$FAKE_TOKEN"
  out=$(run_token exec keychain:fm-svc/nope -- sh -c ": > '$marker'"); rc=$?
  expect_code 3 "$rc" "a missing item must refuse with the token status"
  assert_contains "$out" "keychain:fm-svc/nope has no item 'nope' under service 'fm-svc'" "the refusal should name the missing item"
  assert_absent "$marker" "the command must not run when the token cannot be loaded"
  out=$(run_token check keychain:fm-svc/nope); rc=$?
  expect_code 3 "$rc" "check must report a missing item with the token status"
  : > "$STORE/.locked"
  out=$(run_token exec keychain:fm-svc/cm -- sh -c ": > '$marker'"); rc=$?
  expect_code 3 "$rc" "a locked keychain must refuse"
  assert_contains "$out" "keychain is locked in this session" "the refusal should say the keychain is locked"
  assert_absent "$marker" "the command must not run while the keychain is locked"
  out=$(run_token check keychain:fm-svc/cm); rc=$?
  expect_code 3 "$rc" "check must report a locked keychain with the token status"
  rm -f "$STORE/.locked"
  : > "$STORE/.slow"
  out=$(FM_CLAUDE_TOKEN_READ_SECONDS=1 run_token check keychain:fm-svc/cm); rc=$?
  expect_code 3 "$rc" "a keychain read that hangs must refuse at the bound"
  assert_contains "$out" "timed out after 1s" "the refusal should name the bound"
  rm -f "$STORE/.slow"
  for value in '' $'two\nlines' 'has space' 'quote"inside' 'back\slash' "$(printf 'x%.0s' $(seq 1 4097))"; do
    item fm-svc.bad "$value"
    out=$(run_token check keychain:fm-svc/bad); rc=$?
    expect_code 3 "$rc" "a value that is not one token must refuse: '$(printf '%s' "$value" | head -c 20)'"
    assert_contains "$out" "is not a single-line token" "the refusal should say what a token looks like"
  done
  assert_token_nowhere "refusals must leave the token in no file"
  pass "exec and check refuse a missing item, a locked keychain, a hung read and a malformed value, and the command never runs"
}

test_check_reports_a_readable_source_without_the_value() {
  local out rc
  item fm-svc.cm "$FAKE_TOKEN"
  out=$(run_token check keychain:fm-svc/cm); rc=$?
  expect_code 0 "$rc" "check should succeed on a readable item: $out"
  assert_equals "source: keychain:fm-svc/cm"$'\n'"token: readable" "$out" "check should report the source and readability only"
  pass "check reports a readable source and never its value"
}

test_store_reads_the_token_from_standard_input() {
  local out rc
  out=$(printf '%s\n' "$FAKE_TOKEN" | run_token store keychain:fm-svc/cm2); rc=$?
  expect_code 0 "$rc" "store should succeed: $out"
  assert_contains "$out" "stored: keychain:fm-svc/cm2" "store should report the source it wrote"
  assert_contains "$out" "token: readable" "store should verify the item by reading it back"
  assert_equals "$FAKE_TOKEN" "$(cat "$STORE/fm-svc.cm2")" "the item should hold the token without its trailing newline"
  assert_grep 'add-generic-password -s fm-svc -a cm2' "$CALLS" "store should add the item under the source's service and account"
  out=$(printf '%s' "$FAKE_TOKEN" | run_token store keychain:fm-svc/cm3@/Users/nobody/fleet.keychain-db); rc=$?
  expect_code 0 "$rc" "store into a named keychain file should succeed: $out"
  assert_equals "$FAKE_TOKEN" "$(cat "$STORE/fleet.keychain-db@fm-svc.cm3")" "the item should land in the named keychain"
  assert_grep 'add-generic-password -s fm-svc -a cm3 /Users/nobody/fleet.keychain-db' "$CALLS" "the add should name the keychain file"
  out=$(printf '' | run_token store keychain:fm-svc/cm4); rc=$?
  expect_code 3 "$rc" "empty input must refuse"
  assert_contains "$out" "is not a single-line token" "the refusal should say what a token looks like"
  assert_absent "$STORE/fm-svc.cm4" "a refused store must write nothing"
  out=$(printf 'two\nlines\n' | run_token store keychain:fm-svc/cm4); rc=$?
  expect_code 3 "$rc" "two lines must refuse"
  assert_absent "$STORE/fm-svc.cm4" "a refused store must write nothing"
  : > "$STORE/.locked"
  out=$(printf '%s\n' "$FAKE_TOKEN" | run_token store keychain:fm-svc/cm5); rc=$?
  expect_code 3 "$rc" "a locked keychain must refuse the store"
  assert_contains "$out" "keychain is locked in this session" "the refusal should name the locked keychain"
  assert_contains "$out" "a session where that keychain is unlocked" "the refusal should say where the import can run"
  rm -f "$STORE/.locked"
  assert_token_nowhere "store must leave the token nowhere but the item"
  pass "store reads one token from standard input, verifies it, and refuses empty, multi-line and locked cases"
}

test_real_keychain_round_trip_on_macos() {
  local kc="$TMP_ROOT/fm-test.keychain-db" out rc first rest
  if [ "$(uname -s)" != Darwin ] || [ ! -x /usr/bin/security ]; then
    echo "note: the real-keychain round trip runs only on macOS; this host has no /usr/bin/security"
    return 0
  fi
  real() { PATH="$BASE_PATH" "$TOKEN_SH" "$@" 2>&1; }
  /usr/bin/security create-keychain -p fm-test-keychain-pw "$kc" || fail "could not create the throwaway test keychain"
  out=$(printf '%s\n' "$FAKE_TOKEN" | real store "keychain:fm-test-svc/cm@$kc"); rc=$?
  expect_code 0 "$rc" "store into the throwaway keychain should succeed: $out"
  out=$(real check "keychain:fm-test-svc/cm@$kc"); rc=$?
  expect_code 0 "$rc" "check should read the stored item back: $out"
  # shellcheck disable=SC2016 # the child shell, not this test, must expand the variables in the single-quoted body
  out=$(real exec "keychain:fm-test-svc/cm@$kc" -- sh -c 'printf "%s\n" "$CLAUDE_CODE_OAUTH_TOKEN"; ps -axww -o args='); rc=$?
  expect_code 0 "$rc" "exec should run with the real keychain: $out"
  first=$(printf '%s\n' "$out" | head -1)
  rest=$(printf '%s\n' "$out" | tail -n +2)
  assert_equals "$FAKE_TOKEN" "$first" "the command should receive the token from the real keychain"
  assert_contains "$rest" "ps -axww -o args=" "the process listing should capture at least the launched command itself"
  assert_not_contains "$rest" "$FAKE_TOKEN" "no process on the host may carry the token in its arguments"
  /usr/bin/security lock-keychain "$kc"
  out=$(real check "keychain:fm-test-svc/cm@$kc"); rc=$?
  expect_code 3 "$rc" "a locked real keychain must refuse"
  assert_contains "$out" "keychain is locked in this session" "the real locked refusal should be classified"
  /usr/bin/security unlock-keychain -p fm-test-keychain-pw "$kc"
  out=$(real check "keychain:fm-test-svc/nobody@$kc"); rc=$?
  expect_code 3 "$rc" "a missing item in the real keychain must refuse"
  assert_contains "$out" "has no item 'nobody'" "the real missing-item refusal should be classified"
  /usr/bin/security delete-keychain "$kc" || fail "could not delete the throwaway test keychain"
  pass "the real macOS security tool round-trips store, check, exec, locked and missing on a throwaway keychain"
}

test_usage_errors_refuse_before_touching_the_keychain
test_a_declaration_file_source_checks_loads_and_refuses
test_an_inherited_xtrace_never_prints_the_token
test_exec_loads_the_token_into_the_child_environment_and_never_into_argv
test_exec_and_check_refuse_a_missing_locked_slow_or_malformed_item
test_check_reports_a_readable_source_without_the_value
test_store_reads_the_token_from_standard_input
test_real_keychain_round_trip_on_macos

echo "# all fm-claude-token tests passed"
