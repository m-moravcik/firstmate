#!/usr/bin/env bash
# fm-secondmate-digest.sh - read the routine child events this home's
# secondmates reported without waking it.
#
# Usage:
#   fm-secondmate-digest.sh [--peek] [--max <n>] [<secondmate-id>...]
#   fm-secondmate-digest.sh --all [<secondmate-id>...]
#
# bin/fm-parent-channel-lib.sh owns which secondmate lines are routine and
# routes them to state/<mate-id>.digest beside each mate's status stream, where
# no watcher scan, heartbeat backstop, or decision fold reads them. This is how
# firstmate reads them: bin/fm-wake-drain.sh runs it on a drain that presents a
# heartbeat, and firstmate runs it on demand.
#
# By default it prints every unread complete line under one SECONDMATE DIGEST
# header, grouped by secondmate id and oldest first within each, then marks it
# read. --peek prints the same and marks nothing. --max <n> prints at most n
# lines across every digest, leaves the rest unread, and says how many remain.
# --all prints every retained line and marks nothing. With no id it reads every
# state/*.digest in this home, in id order. It prints nothing when there is
# nothing to show.
#
# The read position lives in state/.<id>.digest-read: the digest's file
# identity and the byte offset already shown. A line still being appended (no
# trailing newline yet) stays unread. A replaced or truncated digest is read
# again from its start, preferring a repeated line over a lost one.
#
# Exit codes: 0 success, 1 a digest or its read position is unsafe or could not
# be read or recorded, 2 usage.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

usage() {
  sed -n '5,7p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

MODE=unread
MARK=1
MAX=
IDS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --peek) MARK=0 ;;
    --all) MODE=all; MARK=0 ;;
    --max)
      [ "$#" -ge 2 ] || usage
      case "$2" in ''|*[!0-9]*|0) usage ;; esac
      MAX=$2
      shift
      ;;
    -h|--help) usage ;;
    -*) usage ;;
    *)
      case "$1" in ''|.*|*/*|*[!A-Za-z0-9._-]*) usage ;; esac
      IDS+=("$1")
      ;;
  esac
  shift
done
[ "$MODE" = unread ] || [ -z "$MAX" ] || usage

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-secondmate-digest.XXXXXX") || exit 1
LOCK="$STATE/.secondmate-digest.lock"
LOCK_HELD=0
# shellcheck disable=SC2317,SC2329 # Invoked by the trap below.
cleanup() {
  [ "$LOCK_HELD" -eq 0 ] || fm_lock_release "$LOCK"
  rm -rf -- "$TMP"
}
trap cleanup EXIT

# Print the complete lines of <digest> from byte <offset> on, leaving a final
# line that has no newline yet unread.
complete_lines_from() {  # <digest> <offset>
  # shellcheck disable=SC2016 # Perl expands its own variables.
  perl -MFcntl=:DEFAULT -e '
    my ($path, $start) = @ARGV;
    sysopen(my $file, $path, O_RDONLY | O_NOFOLLOW) or exit 1;
    binmode $file;
    sysseek($file, $start, 0) == $start or exit 1;
    my ($data, $chunk) = ("", "");
    while (my $read = sysread($file, $chunk, 65536)) { $data .= $chunk; }
    my $end = rindex($data, "\n");
    print substr($data, 0, $end + 1) if $end >= 0;
  ' "$1" "$2"
}

# The byte offset already shown from <digest>, or 0 when nothing valid records
# one for this exact file. Returns 1 when the record itself is unsafe.
read_position() {  # <id> <digest>
  local record="$STATE/.$1.digest-read" version='' ident='' offset='' size current
  if [ ! -e "$record" ] && [ ! -L "$record" ]; then
    printf '0\n'
    return 0
  fi
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  { IFS= read -r version; IFS= read -r ident; IFS= read -r offset; } < "$record" || true
  current=$(_fm_open_decisions_file_ident "$2") || return 1
  size=$(_fm_status_file_size "$2") || return 1
  offset=${offset#offset=}
  if [ "$version" != v1 ] || [ "$ident" != "ident=$current" ]; then
    offset=0
  fi
  case "$offset" in ''|*[!0-9]*) offset=0 ;; esac
  [ "$offset" -le "$size" ] || offset=0
  printf '%s\n' "$offset"
}

write_position() {  # <id> <digest> <offset>
  local record="$STATE/.$1.digest-read" ident tmp
  ident=$(_fm_open_decisions_file_ident "$2") || return 1
  tmp=$(mktemp "$STATE/.$1.digest-read.XXXXXX") || return 1
  if ! printf 'v1\nident=%s\noffset=%s\n' "$ident" "$3" > "$tmp" \
    || ! mv -f -- "$tmp" "$record"; then
    rm -f -- "$tmp"
    return 1
  fi
}

if [ "${#IDS[@]}" -eq 0 ]; then
  for digest in "$STATE"/*.digest; do
    [ -e "$digest" ] || [ -L "$digest" ] || continue
    id=$(basename "$digest" .digest)
    case "$id" in ''|.*|*[!A-Za-z0-9._-]*) continue ;; esac
    IDS+=("$id")
  done
fi

fm_lock_acquire_wait "$LOCK" || exit 1
LOCK_HELD=1
rc=0
shown=0
remaining=0
header_done=0
for id in ${IDS[@]+"${IDS[@]}"}; do
  digest="$STATE/$id.digest"
  [ -e "$digest" ] || [ -L "$digest" ] || continue
  if [ ! -f "$digest" ] || [ -L "$digest" ]; then
    printf 'fm-secondmate-digest: %s is not a regular file\n' "$digest" >&2
    rc=1
    continue
  fi
  if [ "$MODE" = all ]; then
    offset=0
  elif ! offset=$(read_position "$id" "$digest"); then
    printf 'fm-secondmate-digest: the read position for %s is unusable\n' "$id" >&2
    rc=1
    continue
  fi
  if ! complete_lines_from "$digest" "$offset" > "$TMP/lines"; then
    printf 'fm-secondmate-digest: cannot read %s\n' "$digest" >&2
    rc=1
    continue
  fi
  count=$(LC_ALL=C awk 'END { print NR + 0 }' "$TMP/lines")
  [ "$count" -gt 0 ] || continue
  take=$count
  if [ -n "$MAX" ]; then
    take=$((MAX - shown))
    [ "$take" -le "$count" ] || take=$count
    [ "$take" -ge 0 ] || take=0
  fi
  remaining=$((remaining + count - take))
  [ "$take" -gt 0 ] || continue
  head -n "$take" "$TMP/lines" > "$TMP/take" || { rc=1; continue; }
  if [ "$header_done" -eq 0 ]; then
    if [ "$MODE" = all ]; then
      printf 'SECONDMATE DIGEST (every retained routine child event your secondmates reported without waking you, oldest first within each secondmate):\n'
    else
      printf 'SECONDMATE DIGEST (routine child events your secondmates reported without waking you, oldest first within each secondmate; relay only what the captain needs):\n'
    fi
    header_done=1
  fi
  LC_ALL=C sed "s/^/$id /" "$TMP/take" || { rc=1; continue; }
  shown=$((shown + take))
  if [ "$MARK" -eq 1 ]; then
    consumed=$(LC_ALL=C wc -c < "$TMP/take" | tr -d ' ')
    if ! write_position "$id" "$digest" "$((offset + consumed))"; then
      printf 'fm-secondmate-digest: cannot record the read position for %s\n' "$id" >&2
      rc=1
    fi
  fi
done
if [ "$remaining" -gt 0 ]; then
  printf 'SECONDMATE DIGEST: %s more unread; run bin/fm-secondmate-digest.sh to read them.\n' "$remaining"
fi
exit "$rc"
