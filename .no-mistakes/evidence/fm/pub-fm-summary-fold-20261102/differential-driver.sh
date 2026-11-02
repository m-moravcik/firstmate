#!/bin/bash
# drive-case.sh <tree> <case-dir> <out-dir> <mode:old|new>
# Drives the REAL fm-classify-lib.sh functions of <tree> over one synthetic case.
set -u
tree=$1 case=$2 out=$3 mode=$4
. "$tree/bin/fm-classify-lib.sh"
mkdir -p "$out"
f="$case/task.status"
for kindarg in '' ship scout secondmate; do
  o=$(status_open_decisions "$f" "$kindarg"); rc=$?
  printf '%s\n--rc=%s\n' "$o" "$rc" > "$out/fold.${kindarg:-meta}"
done
o=$(FM_CLASSIFY_RESOLVE_VERB=answered FM_CLASSIFY_CAPTAIN_HELD_VERB=held status_open_decisions "$f"); rc=$?
printf '%s\n--rc=%s\n' "$o" "$rc" > "$out/fold.envverbs"
# Incremental (cursor-backed) fold, which still routes through _fm_decision_fold_line.
scratch="$out/scratch"; mkdir -p "$scratch"
for timed in '' timed; do
  rm -rf "$scratch"/* "$scratch"/.[!.]* 2>/dev/null
  cp "$f" "$scratch/task.status"; [ -f "$case/task.meta" ] && cp "$case/task.meta" "$scratch/task.meta"
  o1=$(status_open_decisions_incremental "$scratch/task.status" '' $timed); r1=$?
  o2=$(status_open_decisions_incremental "$scratch/task.status" '' $timed); r2=$?
  # split append: fold the first half, then append the rest and fold again
  rm -rf "$scratch"/* "$scratch"/.[!.]* 2>/dev/null
  [ -f "$case/task.meta" ] && cp "$case/task.meta" "$scratch/task.meta"
  total=$(wc -l < "$f" | tr -d ' '); half=$(( (total + 1) / 2 ))
  head -n "$half" "$f" > "$scratch/task.status"
  o3=$(status_open_decisions_incremental "$scratch/task.status" '' $timed); r3=$?
  tail -n +"$((half + 1))" "$f" >> "$scratch/task.status"
  o4=$(status_open_decisions_incremental "$scratch/task.status" '' $timed); r4=$?
  printf '%s\n--rc=%s\n%s\n--rc=%s\n%s\n--rc=%s\n%s\n--rc=%s\n' "$o1" "$r1" "$o2" "$r2" "$o3" "$r3" "$o4" "$r4" > "$out/incr.${timed:-plain}"
done
rm -rf "$scratch"
# Per-line printed readers (the API every other caller uses).
n=0
: > "$out/lines"; : > "$out/outvar"
while IFS= read -r line || [ -n "$line" ]; do
  n=$((n + 1))
  a=$(status_line_note "$line"); ra=$?
  b=$(_fm_decision_key "$line"); rb=$?
  c=$(_fm_decision_key "$line" ''); rc=$?
  d=$(_fm_key_at_note_head "$line"); rd=$?
  printf 'L%d note rc=%d [%s]\nL%d key rc=%d [%s]\nL%d keyless rc=%d [%s]\nL%d head rc=%d [%s]\n' \
    "$n" "$ra" "$a" "$n" "$rb" "$b" "$n" "$rc" "$c" "$n" "$rd" "$d" >> "$out/lines"
  if [ "$mode" = new ]; then
    # out-var forms must agree with the printed forms, including with caller-ish names.
    n2=__unset; k=__unset; unstamped=__unset; rest=__unset
    status_line_note "$line" n2; ra2=$?
    _fm_decision_key "$line" default k; rb2=$?
    _fm_decision_key "$line" '' unstamped; rc2=$?
    _fm_key_at_note_head "$line" rest; rd2=$?
    [ "$ra2" = "$ra" ] && [ "$n2" = "$a" ] || printf 'L%d note outvar mismatch rc=%s/%s [%s] vs [%s]\n' "$n" "$ra2" "$ra" "$n2" "$a" >> "$out/outvar"
    if [ "$rb" = 0 ]; then [ "$rb2" = 0 ] && [ "$k" = "$b" ] || printf 'L%d key outvar mismatch\n' "$n" >> "$out/outvar"
    else [ "$rb2" = "$rb" ] && [ "$k" = __unset ] || printf 'L%d key failing outvar mismatch rc=%s k=[%s]\n' "$n" "$rb2" "$k" >> "$out/outvar"; fi
    if [ "$rc" = 0 ]; then [ "$rc2" = 0 ] && [ "$unstamped" = "$c" ] || printf 'L%d keyless outvar mismatch\n' "$n" >> "$out/outvar"
    else [ "$rc2" = "$rc" ] || printf 'L%d keyless failing rc mismatch\n' "$n" >> "$out/outvar"; fi
    if [ "$rd" = 0 ]; then [ "$rd2" = 0 ] && [ "$rest" = "$d" ] || printf 'L%d head outvar mismatch\n' "$n" >> "$out/outvar"
    else [ "$rd2" = "$rd" ] || printf 'L%d head failing rc mismatch\n' "$n" >> "$out/outvar"; fi
  fi
done < "$f"
