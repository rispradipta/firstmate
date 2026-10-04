#!/usr/bin/env bash
# fm-dispatch-cap.sh - the one owner of this home's standing dispatch
# concurrency cap: how many ordinary crewmates and scouts one home may have
# live at once.
#
# Usage:
#   fm-dispatch-cap.sh cap                Print the resolved cap (default 2).
#   fm-dispatch-cap.sh live               Print this home's live ordinary task count.
#   fm-dispatch-cap.sh check [--exclude <id>]   Verdict for one dispatch.
#   fm-dispatch-cap.sh --help
#
# `--exclude <id>` drops that task's own state/<id>.meta from the count, so a
# redispatch or relaunch of an existing task is measured against the OTHER busy
# slots rather than against itself.
#
# WHY. A treehouse pool enforces a physical `max_trees` by FAILING a spawn that
# cannot get a slot. Firstmate wants the opposite: work above its own cap stays
# queued and dispatches later, when a slot frees. The cap is a firstmate-side
# value (config/max-concurrent-workers, default 2 per home) that binds while
# attended as well as away, unlike the away-only spend cap owned by
# bin/fm-afk-contract.sh.
#
# INTAKE GATE. Firstmate runs `check` before it calls bin/fm-spawn.sh for a
# fresh ship or scout. `check` exits 0 when the dispatch is admitted and exits 10
# (FM_DISPATCH_CAP_AT_CAP_EXIT) when this home is at cap, printing
# `live=<n> cap=<c>` on stdout either way. At cap is a distinct outcome, not an
# error: firstmate leaves the backlog item queued and re-checks when a task
# finishes rather than dispatching a spawn that would fail for want of a slot.
# bin/fm-spawn.sh consults the same verdict as a deterministic backstop, so a
# spawn that reaches it directly also declines with the at-cap code before any
# endpoint, worktree, or backlog transition exists.
#
# EXEMPT. A --relaunch replaces a worker that already counts, and a secondmate is
# a persistent home rather than a parallel work slot, so neither is counted or
# gated. `live` counts only this home's own state/*.meta records whose kind is
# not secondmate; it never sweeps another home's endpoints or metadata.
#
# CONFIG (config/max-concurrent-workers under FM_CONFIG_OVERRIDE, else
# $FM_HOME/config): one positive base-10 integer, optionally followed by exactly
# one newline, in a regular, non-symlinked file. An absent file means the default
# of 2. A malformed, multi-line, symlinked, or otherwise unsafe value exits 2
# with a diagnostic rather than being silently defaulted; only an absent file
# takes the default.
#
# Exit status: 0 admitted, 10 at cap, 2 invalid configuration or usage.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

FM_DISPATCH_CAP_FILE="max-concurrent-workers"
FM_DISPATCH_CAP_DEFAULT=2
FM_DISPATCH_CAP_AT_CAP_EXIT=10
FM_DISPATCH_CAP_CONFIG_EXIT=2

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

fail_config() {
  printf 'fm-dispatch-cap: %s\n' "$*" >&2
  exit "$FM_DISPATCH_CAP_CONFIG_EXIT"
}

# Print the resolved cap, or a diagnostic and exit 2 for an unsafe value.
resolve_cap() {
  local path="$CONFIG/$FM_DISPATCH_CAP_FILE" value links rendered
  if [ -L "$path" ]; then
    fail_config "config/$FM_DISPATCH_CAP_FILE is a symlink; use a regular file"
  fi
  if [ ! -e "$path" ]; then
    printf '%s\n' "$FM_DISPATCH_CAP_DEFAULT"
    return 0
  fi
  if [ ! -f "$path" ]; then
    fail_config "config/$FM_DISPATCH_CAP_FILE is not a regular file"
  fi
  if [ "$(uname)" = Darwin ]; then
    links=$(/usr/bin/stat -f %l "$path" 2>/dev/null || true)
  else
    links=$(stat -c %h "$path" 2>/dev/null || true)
  fi
  if [ "$links" != 1 ]; then
    fail_config "config/$FM_DISPATCH_CAP_FILE is hardlinked"
  fi
  value=$(<"$path") || fail_config "config/$FM_DISPATCH_CAP_FILE could not be read"
  case "$value" in
  '' | *[!0-9]* | 0*)
    fail_config "config/$FM_DISPATCH_CAP_FILE must be one positive base-10 integer"
    ;;
  esac
  rendered="$value"$'\n'
  # Accept the value with exactly one terminating newline, or with none.
  if ! printf '%s' "$value" | cmp -s - "$path" \
    && ! printf '%s' "$rendered" | cmp -s - "$path"; then
    fail_config "config/$FM_DISPATCH_CAP_FILE must hold only the integer and at most one newline"
  fi
  printf '%s\n' "$value"
}

# Print this home's live ordinary task count. A missing state directory is empty.
# An optional exclude id omits that task's own record from the count.
live_count() {
  local exclude=${1:-} meta id kind live=0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    [ -z "$exclude" ] || [ "$id" != "$exclude" ] || continue
    kind=$(grep '^kind=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ "$kind" != secondmate ] || continue
    live=$((live + 1))
  done
  printf '%s\n' "$live"
}

CMD="${1:-}"
case "$CMD" in
-h | --help)
  usage
  exit 0
  ;;
cap)
  resolve_cap
  ;;
live)
  live_count "${2:-}"
  ;;
check)
  EXCLUDE=
  if [ "$#" -ge 1 ]; then
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
      --exclude)
        [ "$#" -ge 2 ] || fail_config "--exclude needs a task id"
        EXCLUDE=$2
        shift 2
        ;;
      --exclude=*)
        EXCLUDE=${1#--exclude=}
        shift
        ;;
      *)
        fail_config "unexpected argument for check: $1"
        ;;
      esac
    done
  fi
  cap=$(resolve_cap)
  live=$(live_count "$EXCLUDE")
  printf 'live=%s cap=%s\n' "$live" "$cap"
  if [ "$live" -ge "$cap" ]; then
    exit "$FM_DISPATCH_CAP_AT_CAP_EXIT"
  fi
  exit 0
  ;;
*)
  echo "usage: fm-dispatch-cap.sh cap | live | check [--exclude <id>] | --help" >&2
  exit "$FM_DISPATCH_CAP_CONFIG_EXIT"
  ;;
esac
