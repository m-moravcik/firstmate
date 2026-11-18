#!/usr/bin/env bash
# fm-claude-token.sh - load a pinned Claude account's long-lived OAuth token
# from a declared source into one process's environment, check that a source
# is readable, or store a token read from standard input.
#
# Usage:
#   fm-claude-token.sh exec <source> -- <command> [args...]
#   fm-claude-token.sh check <source>
#   fm-claude-token.sh store <source>        (the token arrives on stdin)
#   fm-claude-token.sh --help
#
# <source> names where the token lives, never the token, in one of two forms:
#   keychain:<service>/<account>[@<keychain-file>]
#       a config/claude-account-tokens reference: a generic password in the
#       macOS Keychain, read with `security find-generic-password -s <service>
#       -a <account> -w [<keychain-file>]` from the default search list or
#       from the one named keychain file. bin/fm-worker-account-lib.sh owns
#       the grammar (fm_worker_account_token_source_parse).
#   <absolute path of a credential-source declaration file>
#       a JSON file in bin/fm-credential-source-lib.sh's declaration schema
#       with a `claude` entry, read through that library's adapter.
# Anything else is a usage error. The operator contract for both is
# docs/configuration.md "Claude token source".
#
# The token exists only in this process's memory and then in the environment
# of the command `exec` replaces itself with, as CLAUDE_CODE_OAUTH_TOKEN,
# Claude Code's documented environment credential. It is never an argument of
# any process, never written to a file, never logged, and never printed: check
# and store print the source and "token: readable" only, and exec prints
# nothing of its own. exec runs the command through `env`, so a leading
# NAME=value word applies the way a raw launch command carries one; the
# command may not start with an option. A caller's own CLAUDE_CODE_OAUTH_TOKEN
# is replaced, never kept.
#
# A token is one line of 1 to 4096 characters from [A-Za-z0-9._~:/+=-], the
# alphabet of `claude setup-token` output plus URL-safe punctuation. Anything
# else in the item is refused as malformed rather than passed on. Shell tracing
# is switched off for as long as the token is handled, so an inherited xtrace
# (SHELLOPTS or set -x) cannot print it, and exec restores it for the command.
#
# store takes a keychain: reference only; an item behind a declaration file is
# stored with `security add-generic-password -s <service> [-a <account>] -w`.
# It reads all of standard input, strips trailing newlines, refuses a
# terminal, and writes the item with `security -i`, whose add-generic-password
# line travels on the tool's standard input, so the value is never an argument
# of any process; it then reads the item back and reports it readable. The
# item is created by `security` itself, so the same tool reads it later without
# a prompt in any session where that keychain is unlocked.
#
# Exit status: 0 success (for exec, the command's own status), 2 usage, and 3
# when the source refuses. A keychain: reference refuses when the item is
# missing (security exit 44), its keychain is locked or needs an interactive
# unlock (36), the read timed out (FM_CLAUDE_TOKEN_READ_SECONDS, default 15),
# or security failed otherwise. A declaration file refuses when it is
# malformed, names a source this host cannot run, or its source is unavailable
# or does not answer within the adapter's own bound. Either form refuses a
# value that is not one token. Every refusal is one `error:` line on stderr
# naming the source and the reason, never the value, and exec never runs the
# command after a refusal.
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-worker-account-lib.sh
. "$SCRIPT_DIR/fm-worker-account-lib.sh"

FM_CLAUDE_TOKEN_READ_SECONDS=${FM_CLAUDE_TOKEN_READ_SECONDS:-15}
USAGE='usage: fm-claude-token.sh exec <source> -- <command> [args...]
       fm-claude-token.sh check <source>
       fm-claude-token.sh store <source>     (token on standard input)
<source>: keychain:<service>/<account>[@<keychain-file>]
          or the absolute path of a credential-source declaration file'
GRAMMAR="keychain:<service>/<account>[@<keychain-file>] (service and account: letters, digits, . _ -; the file: an absolute path without whitespace)"

usage_error() {
  printf 'error: %s\n%s\n' "$1" "$USAGE" >&2
  exit 2
}

refuse() {
  printf 'error: %s\n' "$1" >&2
  exit 3
}

# parse_source <source>: sets FORM to keychain (with SERVICE, ACCOUNT and
# KEYCHAIN) or to file, or exits 2.
parse_source() {
  local parsed
  case "$1" in
  keychain:*) ;;
  /*)
    FORM='file'
    return 0
    ;;
  *) usage_error "'$1' is neither $GRAMMAR nor the absolute path of a credential-source declaration file" ;;
  esac
  parsed=$(fm_worker_account_token_source_parse "$1") || usage_error "'$1' is not $GRAMMAR"
  FORM=keychain
  SERVICE=${parsed%%$'\t'*}
  parsed=${parsed#*$'\t'}
  ACCOUNT=${parsed%%$'\t'*}
  KEYCHAIN=${parsed#*$'\t'}
}

# token_valid <value>: one line of the token alphabet, 1 to 4096 characters.
token_valid() {
  [ "${#1}" -ge 1 ] && [ "${#1}" -le 4096 ] && [[ $1 =~ ^[A-Za-z0-9._~:/+=-]+$ ]]
}

# read_file_token: loads a declaration file's token into TOKEN, or refuses.
read_file_token() {
  local problem adapter rc
  problem=$(fm_credsrc_check "$SOURCE" claude) || refuse "Claude token source $SOURCE: malformed declaration: $problem"
  adapter=$(fm_credsrc_field "$SOURCE" claude source)
  fm_credsrc_supported "$adapter" || refuse "Claude token source $SOURCE: source $adapter is not supported on this host"
  TOKEN=$(fm_credsrc_read "$SOURCE" claude)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    if fm_timed_out "$rc"; then
      refuse "Claude token source $SOURCE: source $adapter did not answer in time"
    fi
    refuse "Claude token source $SOURCE: source $adapter is unavailable"
  fi
  token_valid "$TOKEN" || refuse "Claude token source $SOURCE: does not contain one valid OAuth token"
}

# read_token: loads the item into TOKEN, or refuses with the classified reason.
read_token() {
  local rc
  if [ "$FORM" = file ]; then
    read_file_token
    return 0
  fi
  command -v security >/dev/null 2>&1 || refuse "$SOURCE cannot be read: the macOS Keychain tool 'security' is not on PATH"
  if [ -n "$KEYCHAIN" ]; then
    TOKEN=$(fm_run_timed "$FM_CLAUDE_TOKEN_READ_SECONDS" security find-generic-password -s "$SERVICE" -a "$ACCOUNT" -w "$KEYCHAIN" </dev/null)
  else
    TOKEN=$(fm_run_timed "$FM_CLAUDE_TOKEN_READ_SECONDS" security find-generic-password -s "$SERVICE" -a "$ACCOUNT" -w </dev/null)
  fi
  rc=$?
  case "$rc" in
  0) ;;
  44) refuse "$SOURCE has no item '$ACCOUNT' under service '$SERVICE'${KEYCHAIN:+ in $KEYCHAIN}; import the token into that item, or fix the mapping" ;;
  36) refuse "$SOURCE cannot be read because its keychain is locked in this session, or needs an interactive unlock; unlock it in this session, or run from a session where that keychain is unlocked" ;;
  124) refuse "$SOURCE read timed out after ${FM_CLAUDE_TOKEN_READ_SECONDS}s; security did not answer (a keychain waiting for a dialog, or a hung securityd)" ;;
  *) refuse "$SOURCE cannot be read: security find-generic-password exited $rc" ;;
  esac
  token_valid "$TOKEN" || refuse "$SOURCE holds a value that is not a single-line token (1-4096 characters from letters, digits and . _ ~ : / + = -); re-import the token"
}

cmd_check() {
  read_token
  printf 'source: %s\ntoken: readable\n' "$SOURCE"
}

cmd_exec() {
  read_token
  export CLAUDE_CODE_OAUTH_TOKEN="$TOKEN"
  unset TOKEN
  [ -z "$XTRACE" ] || set -x
  exec env "$@"
}

cmd_store() {
  local stored rc
  [ "$FORM" = keychain ] || usage_error "store takes a keychain: reference; store an item behind a declaration file with security add-generic-password -s <service> [-a <account>] -w"
  [ ! -t 0 ] || refuse "store reads the token from standard input, not from a terminal; pipe it in from your password manager's read command"
  stored=$(cat)
  token_valid "$stored" || refuse "standard input is not a single-line token (1-4096 characters from letters, digits and . _ ~ : / + = -); nothing was stored"
  command -v security >/dev/null 2>&1 || refuse "$SOURCE cannot be stored: the macOS Keychain tool 'security' is not on PATH"
  {
    printf 'add-generic-password -U -s %s -a %s -w "%s"' "$SERVICE" "$ACCOUNT" "$stored"
    [ -z "$KEYCHAIN" ] || printf ' %s' "$KEYCHAIN"
    printf '\n'
  } | fm_run_timed "$FM_CLAUDE_TOKEN_READ_SECONDS" security -i
  rc=$?
  case "$rc" in
  0) ;;
  36) refuse "$SOURCE was not stored because its keychain is locked in this session; run the import from a session where that keychain is unlocked" ;;
  124) refuse "$SOURCE was not stored: security -i timed out after ${FM_CLAUDE_TOKEN_READ_SECONDS}s" ;;
  *) refuse "$SOURCE was not stored: security -i exited $rc" ;;
  esac
  read_token
  [ "$TOKEN" = "$stored" ] || refuse "$SOURCE was stored but reads back as a different value; inspect the item"
  printf 'stored: %s\ntoken: readable\n' "$SOURCE"
}

case "${1:-}" in
--help | -h)
  printf '%s\n' "$USAGE"
  exit 0
  ;;
'') usage_error "a subcommand is required" ;;
exec | check | store)
  CMD=$1
  shift
  ;;
*) usage_error "unknown subcommand '$1'" ;;
esac
[ $# -ge 1 ] || usage_error "$CMD needs a <source>"
SOURCE=$1
shift
parse_source "$SOURCE"
# An inherited xtrace would print every expansion of the token, so tracing
# stays off from here on; exec restores it for the command it runs.
case $- in *x*) XTRACE=1 ;; *) XTRACE= ;; esac
set +x
case "$CMD" in
check)
  [ $# -eq 0 ] || usage_error "check takes only a <source>"
  cmd_check
  ;;
store)
  [ $# -eq 0 ] || usage_error "store takes only a <source>"
  cmd_store
  ;;
exec)
  [ "${1:-}" = -- ] || usage_error "exec needs -- between the <source> and the command"
  shift
  [ $# -ge 1 ] || usage_error "exec needs a command after --"
  case "$1" in
  -*) usage_error "the command must not start with an option ('$1'); name the program, or a NAME=value assignment, first" ;;
  esac
  cmd_exec "$@"
  ;;
esac
