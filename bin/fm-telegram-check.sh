#!/usr/bin/env bash
# fm-telegram-check.sh - recurring Telegram sync as a standing watcher check.
#
# Usage:
#   fm-telegram-check.sh [check]
#   fm-telegram-check.sh arm
#   fm-telegram-check.sh disarm
#   fm-telegram-check.sh --help
#
# `check` runs `fm-telegram.sh sync` (poll then flush) from this home, sourcing
# the same .env and using the same state as fm-telegram.sh itself. It composes
# with the existing watcher state-check contract instead of needing a schedule
# of its own: a printed line becomes a `check:` wake so firstmate can drain the
# durable `check: telegram <update_id>` and inbox-note rows the poll queued.
#
# `arm` writes state/telegram.check.sh and binds its bytes with
# fm-check-register.sh, so the watcher dispatches it on its normal
# FM_CHECK_INTERVAL cadence and turns its one line into a `check:` wake.
# `disarm` removes the shim, its trust binding, and the report record.
#
# Telegram configuration is read from the home's own .env by the sync, so
# arming needs no configuration of its own. A home that is armed before its
# .env has FM_TELEGRAM_BOT_TOKEN and FM_TELEGRAM_CHAT_ID is reported once for
# the missing value until the .env is fixed, which makes a partially configured
# channel a wake instead of a silent gap.
#
# Reporting keeps state/.telegram-check as the news key, but prints whenever
# the sync is not a proven no-op. A proven no-op is a repeated identical line,
# not a timeout, with no publication evidence. Publication evidence is a
# timeout, queued-update output, a queued `telegram:` check key, or growth of
# state/.telegram-woken. Same-line silence is only for a proven no-op: a
# successful sync with no new updates, or a repeated pre-wake failure (missing
# env, connection failure before any note was queued) that cannot have queued a
# wake. A poll that queued a wake and then failed always doorbells.
#
# The sync must finish inside the watcher's per-check bound (FM_CHECK_TIMEOUT,
# default 30, read from this check's own environment because the watcher runs it
# as a direct child). The internal budget FM_TELEGRAM_CHECK_BUDGET (default 15,
# valid 5..25) is cut down to whatever fits inside that bound before the sync
# starts, and a sync that does not finish reports one line naming the budget.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
RECORD="$STATE/.telegram-check"
CHECK_ID=telegram
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
TELEGRAM_BIN="$SCRIPT_DIR/fm-telegram.sh"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
RECORD_SCHEMA=fm-telegram-check-v1
MAX_LINE=240

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-telegram-check.sh [check]   run the Telegram sync; wake line unless the sync is a proven no-op
  fm-telegram-check.sh arm       write and register state/telegram.check.sh
  fm-telegram-check.sh disarm    remove the check shim, its trust binding, and the record
  fm-telegram-check.sh --help    print this help

Telegram configuration (FM_TELEGRAM_BOT_TOKEN, FM_TELEGRAM_CHAT_ID,
FM_TELEGRAM_ALLOWED_USERS, FM_TELEGRAM_API_BASE, FM_TELEGRAM_POLL_TIMEOUT,
FM_TELEGRAM_CURSOR) is read from <FM_HOME>/.env by fm-telegram.sh.
See docs/configuration.md "Telegram plane" for the schema.
EOF
}

die_usage() {
  printf 'fm-telegram-check: %s\n' "$1" >&2
  usage >&2
  exit 2
}

record_epoch_now() {
  case "${FM_TELEGRAM_CHECK_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_TELEGRAM_CHECK_NOW" ;;
  esac
}

CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}
case "$CHECK_TIMEOUT" in
  ''|*[!0-9]*|0) CHECK_TIMEOUT=30 ;;
esac

BUDGET_SECS=${FM_TELEGRAM_CHECK_BUDGET:-15}
case "$BUDGET_SECS" in
  ''|*[!0-9]*|0)
    printf 'fm-telegram-check: FM_TELEGRAM_CHECK_BUDGET must be a whole number from 5 to 25\n' >&2
    exit 2
    ;;
esac
if [ "$BUDGET_SECS" -lt 5 ] || [ "$BUDGET_SECS" -gt 25 ]; then
  printf 'fm-telegram-check: FM_TELEGRAM_CHECK_BUDGET must be a whole number from 5 to 25\n' >&2
  exit 2
fi

# fm_run_timed counts a whole second before it alarms, so the budget has to fit
# inside the watcher's own bound with the alarm and kill margins left over.
BUDGET_MAX=$((CHECK_TIMEOUT - 3))
[ "$BUDGET_MAX" -ge 1 ] || BUDGET_MAX=1
if [ "$BUDGET_SECS" -gt "$BUDGET_MAX" ]; then
  BUDGET_SECS=$BUDGET_MAX
fi

# One sync summary, built only from the sync's own combined output. The sync's
# own "fm-telegram: ..." diagnostics name the missing setup value or the failure
# precisely, so they are preferred to a raw python backtrace; queued-update and
# delivered lines are skipped because a fail-closed sync may already have
# printed them; anything else is summarized rather than dropped, and an empty
# failure gets a truth-stating fallback.
sync_summary() {
  local rc=$1 out=$2 line
  line=$(printf '%s\n' "$out" | sed -n '/^fm-telegram: queued update /d; /^fm-telegram: delivered /d; s/^fm-telegram: //p' | sed -n '1p')
  if [ -z "$line" ]; then
    line=$(printf '%s\n' "$out" | sed -n '/^fm-telegram: queued update /d; /^fm-telegram: delivered /d; /^$/d; p' | sed -n '1p')
  fi
  if [ -z "$line" ]; then
    line="sync failed (rc=$rc)"
  fi
  printf '%s\n' "$line"
}

record_read() {
  local line first=1
  RECORD_REPORTED=
  [ -f "$RECORD" ] || return 0
  while IFS= read -r line; do
    if [ "$first" = 1 ]; then
      first=0
      [ "$line" = "$RECORD_SCHEMA" ] || return 0
      continue
    fi
    case "$line" in
      reported=*) RECORD_REPORTED=${line#reported=} ;;
    esac
  done < "$RECORD"
  return 0
}

record_write() {
  local reported=$1 tmp
  tmp=$(mktemp "$RECORD.XXXXXX" 2>/dev/null) || return 1
  chmod 0600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  {
    printf '%s\n' "$RECORD_SCHEMA"
    printf 'epoch=%s\n' "$(record_epoch_now)"
    printf 'reported=%s\n' "$reported"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$RECORD" || { rm -f -- "$tmp"; return 1; }
  return 0
}

# True when this sync has publication evidence, so a repeated diagnostic is not
# a proven no-op. Stdout is a side channel; the durable ledger is the queued
# `telegram:` check keys and growth of state/.telegram-woken, the same records
# the poll writes when it queues a message.
sync_has_publication_evidence() {
  local rc=${1:-0} out=$2 woken_before=$3
  [ "$rc" -eq 124 ] && return 0
  if [ -n "$out" ] && printf '%s\n' "$out" | grep -q '^fm-telegram: queued update '; then
    return 0
  fi
  if [ -s "$STATE/.wake-queue" ] && grep -q $'\ttelegram:' "$STATE/.wake-queue"; then
    return 0
  fi
  if [ -f "$STATE/.telegram-woken" ]; then
    if [ -z "$woken_before" ] || [ ! -f "$woken_before" ] \
      || ! cmp -s "$woken_before" "$STATE/.telegram-woken"; then
      return 0
    fi
  fi
  return 1
}

action_check() {
  local out rc line woken_before queued=0
  mkdir -p "$STATE" || return 1
  woken_before=$(mktemp) || woken_before=
  if [ -n "$woken_before" ]; then
    if [ -f "$STATE/.telegram-woken" ]; then
      cp "$STATE/.telegram-woken" "$woken_before" 2>/dev/null || : > "$woken_before"
    else
      : > "$woken_before"
    fi
  fi
  if [ ! -x "$TELEGRAM_BIN" ]; then
    line="fm-telegram.sh is missing next to this check ($TELEGRAM_BIN)"
  else
    out=$(fm_run_timed "$BUDGET_SECS" "$TELEGRAM_BIN" sync 2>&1) || rc=$?
    if [ "${rc:-0}" -eq 124 ]; then
      line="sync did not finish within the ${BUDGET_SECS}s budget"
    elif [ "${rc:-0}" -ne 0 ]; then
      line=$(sync_summary "$rc" "$out")
    elif printf '%s\n' "$out" | grep '^fm-telegram: queued update ' >/dev/null; then
      # The poll already queued the durable telegram and inbox wakes; emit one
      # line naming the last surfaced update so the watcher wakes firstmate to
      # drain them even when the summary would otherwise be silent.
      line=$(printf '%s\n' "$out" | grep '^fm-telegram: queued update ' | tail -n 1 | sed 's/^fm-telegram: /new message: /')
    else
      line=
    fi
  fi
  record_read
  if sync_has_publication_evidence "${rc:-0}" "${out:-}" "$woken_before"; then
    queued=1
  fi
  [ -n "$woken_before" ] && rm -f -- "$woken_before"
  if [ -n "$line" ] && { [ "$line" != "$RECORD_REPORTED" ] || [ "$queued" -eq 1 ]; }; then
    fm_cap_line_var "telegram: $line" "$MAX_LINE"
    printf '%s\n' "$FM_LINE_CAP_LINE"
  fi
  record_write "$line" || true
  return 0
}

# The home is embedded already resolved, because the watcher runs the shim from
# its own working directory and a relative spelling would send the check to a
# different home, or to none at all.
shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-telegram-check.sh - Telegram sync shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-telegram-check.sh") check"
}

SHIM_WRITE_TMP=

shim_write() {
  local want=$1 device tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  if [ -e "$CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  tmp=$(umask 077; mktemp "$STATE/.fm-telegram-check.XXXXXX" 2>/dev/null) || return 1
  SHIM_WRITE_TMP=$tmp
  if ! printf '%s\n' "$want" > "$tmp" \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  if ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  SHIM_WRITE_TMP=
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

shim_backup() {
  local device tmp
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-telegram-check.XXXXXX" 2>/dev/null) || return 1
  if ! cat "$CHECK_SHIM" > "$tmp" 2>/dev/null \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

ARM_BACKUP=

arm_rollback() {
  [ -z "$SHIM_WRITE_TMP" ] || rm -f -- "$SHIM_WRITE_TMP"
  SHIM_WRITE_TMP=
  if [ -n "$ARM_BACKUP" ]; then
    mv -f -- "$ARM_BACKUP" "$CHECK_SHIM" 2>/dev/null || rm -f -- "$ARM_BACKUP"
    ARM_BACKUP=
    if fm_custom_check_registered "$STATE" "$CHECK_ID"; then
      return 0
    fi
  fi
  rm -f -- "$CHECK_SHIM"
}

# shellcheck disable=SC2329  # Registered by action_arm's signal trap.
arm_interrupted() {
  arm_rollback
  printf 'fm-telegram-check: arming was interrupted, so state/%s.check.sh is not armed\n' "$CHECK_ID" >&2
  exit 1
}

action_arm() {
  local want home
  if [ ! -x "$TELEGRAM_BIN" ]; then
    printf 'fm-telegram-check: the Telegram plane is missing at %s; cannot arm\n' "$TELEGRAM_BIN" >&2
    return 1
  fi
  mkdir -p "$STATE" || return 1
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *)
      home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
        printf 'fm-telegram-check: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
        return 1
      }
      ;;
  esac
  want=$(shim_content "$home")
  ARM_BACKUP=
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ]; then
    ARM_BACKUP=$(shim_backup) || {
      printf 'fm-telegram-check: could not save the existing %s\n' "$CHECK_SHIM" >&2
      return 1
    }
  fi
  trap arm_interrupted HUP INT TERM
  if ! shim_write "$want"; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-telegram-check: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  if ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-telegram-check: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  trap - HUP INT TERM
  [ -z "$ARM_BACKUP" ] || rm -f -- "$ARM_BACKUP"
  ARM_BACKUP=
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

action_disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST" "$RECORD"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

case "${1:-check}" in
  check) action_check ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  -h|--help) usage ;;
  *) die_usage "unknown action: $1" ;;
esac
