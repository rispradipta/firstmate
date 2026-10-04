#!/usr/bin/env bash
# fm-telegram.sh - Telegram captain channel: inbound notes and outbound replies.
#
# This mirrors the mail plane (bin/fm-mail.sh) rather than inventing an
# architecture, but with two halves:
#
#   poll     Call the Telegram Bot API getUpdates once with a durable offset
#            cursor. Each new message from the allowlisted chat becomes a
#            durable captain note through `bin/fm-inbox.sh note --request-id
#            tg:<update_id>`, so a replayed update never creates a second note,
#            and a durable `check: telegram <update_id>` wake is queued so the
#            fm-telegram-respond skill loads. A malformed, non-text, or
#            non-allowlisted update is ignored with a one-line diagnostic and is
#            never queued as the captain's words. The offset advances only past
#            updates that were actually recorded, so an interrupted poll
#            re-fetches the rest and request-id dedup keeps that safe.
#   flush    Deliver recorded answers back to the configured chat. Records
#            written by `bin/fm-inbox.sh reply` stay the single owner of the
#            reply; flush reads those records, delivers only the ones whose note
#            came from Telegram, and advances its own durable reply cursor so an
#            answer is posted once. A delivered reply is journaled before the
#            cursor moves, so a crash between send and journal can repeat a
#            message but never lose one.
#   sync     poll then flush; this is what the standing check runs.
#   send     Send one message to the configured chat (text argument, or `-` to
#            read stdin).
#   status   Print configuration and both cursors. No network, no token value.
#
# This surface is a full command channel, not read-only: a message from the
# allowlisted chat is the captain's own words for ordinary work, for answering a
# held decision, and for approving a merge. Destructive, irreversible, and
# security-sensitive actions still require explicit confirmation and are never
# authorized by a Telegram message alone. Anything from another chat or user is
# untrusted input and never authority. That rule is owned by the
# fm-telegram-respond skill; this script only carries the words durably.
#
# Deployment - credentials and endpoints are read from the environment, filling
# missing keys from the gitignored $FM_HOME/.env (same convention as the mail
# plane and Relay; env wins). Add these values:
#   FM_TELEGRAM_BOT_TOKEN=<bot token>          required, never printed or logged
#   FM_TELEGRAM_CHAT_ID=<chat id>              required, the one allowlisted chat
#   FM_TELEGRAM_ALLOWED_USERS=<id,id>          optional sender restriction; empty
#                                              means any sender in the chat
#   FM_TELEGRAM_API_BASE=<url>                 optional, default https://api.telegram.org
#   FM_TELEGRAM_POLL_TIMEOUT=<seconds>         optional getUpdates long-poll, default 0
#   FM_TELEGRAM_CURSOR=<path>                  optional offset-cursor path
# FM_HOME falls back to the repo root when unset. FM_TELEGRAM_BOT_TOKEN and
# FM_TELEGRAM_CHAT_ID are always required; the token is never logged, and the
# API URL (which embeds it) never appears in a diagnostic. Network work is
# delegated to bin/fm-telegram.py; cursor and reply ledger stay under
# $FM_HOME/state.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-}"
if [ -z "$FM_HOME" ]; then
  FM_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
export FM_HOME
ENV_FILE="$FM_HOME/.env"
# Load the home .env for keys not already set, so a direct invocation's
# environment overrides .env exactly like the Relay/FMX contract (fmx_env_get:
# "env wins over .env"). Tolerates a leading "export ", surrounding whitespace,
# one layer of matching quotes, comments, and blank lines.
if [ -f "$ENV_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in
      ''|\#*) continue ;;
      export\ *) line="${line#export }" ;;
    esac
    case "$line" in
      *=*) ;;
      *) continue ;;
    esac
    key="${line%%=*}"
    key="${key#"${key%%[![:space:]]*}"}"
    val="${line#*=}"
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    case "$val" in
      \"*\") val=${val#\"}; val=${val%\"} ;;
      \'*\') val=${val#\'}; val=${val%\'} ;;
    esac
    if [ -n "$key" ] && [ -z "${!key:-}" ]; then
      export "$key=$val"
    fi
  done < "$ENV_FILE"
fi

usage() {
  cat <<'EOF'
fm-telegram.sh poll
fm-telegram.sh flush
fm-telegram.sh sync
fm-telegram.sh send <text | ->
fm-telegram.sh status
EOF
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  poll|flush|sync|send|status) ;;
  '')
    usage
    exit 1
    ;;
  *)
    usage
    exit 1
    ;;
esac

for r in FM_TELEGRAM_BOT_TOKEN FM_TELEGRAM_CHAT_ID; do
  if [ -z "${!r:-}" ]; then
    echo "fm-telegram: missing required \$FM_HOME/.env value: $r" >&2
    echo "fm-telegram: add $r (and the other FM_TELEGRAM_* values) to $ENV_FILE" >&2
    exit 1
  fi
done

CHAT_ID="$FM_TELEGRAM_CHAT_ID"
ALLOWED_USERS="${FM_TELEGRAM_ALLOWED_USERS:-}"
API_BASE="${FM_TELEGRAM_API_BASE:-https://api.telegram.org}"
API_BASE="${API_BASE%/}"
POLL_TIMEOUT="${FM_TELEGRAM_POLL_TIMEOUT:-0}"
case "$POLL_TIMEOUT" in
  ''|*[!0-9]*)
    echo "fm-telegram: FM_TELEGRAM_POLL_TIMEOUT must be a non-negative whole number, got: ${FM_TELEGRAM_POLL_TIMEOUT:-}" >&2
    exit 1
    ;;
esac

STATE="$FM_HOME/state"
INBOX="$STATE/inbox"
REPLIES="$INBOX/.replies"
CURSOR="${FM_TELEGRAM_CURSOR:-$STATE/.telegram-cursor}"
REPLY_CURSOR="$STATE/.telegram-reply-cursor"
REPLY_JOURNAL="$STATE/.telegram-reply-sent"
WOKEN="$STATE/.telegram-woken"

PY="$(command -v python3 || true)"
if [ -z "$PY" ]; then
  echo "fm-telegram: python3 required" >&2
  exit 1
fi
PY_BIN="$SCRIPT_DIR/fm-telegram.py"
if [ ! -f "$PY_BIN" ]; then
  echo "fm-telegram: $PY_BIN missing" >&2
  exit 1
fi

integer_or_zero() {
  case "${1:-}" in
    ''|*[!0-9]*) printf '0\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

telegram_offset_read() {
  local value=""
  [ -f "$CURSOR" ] && value=$(sed -n '1p' "$CURSOR" 2>/dev/null | tr -d '[:space:]')
  integer_or_zero "$value"
}

telegram_offset_write() {
  local value=$1 tmp
  tmp=$(mktemp "$CURSOR.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$value" > "$tmp" || ! mv -f -- "$tmp" "$CURSOR"; then
    rm -f -- "$tmp"
    return 1
  fi
  return 0
}

reply_cursor_read() {
  local value=""
  [ -f "$REPLY_CURSOR" ] && value=$(sed -n '1p' "$REPLY_CURSOR" 2>/dev/null | tr -d '[:space:]')
  integer_or_zero "$value"
}

reply_cursor_write() {
  local value=$1 tmp
  tmp=$(mktemp "$REPLY_CURSOR.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$value" > "$tmp" || ! mv -f -- "$tmp" "$REPLY_CURSOR"; then
    rm -f -- "$tmp"
    return 1
  fi
  return 0
}

user_allowed() {
  local wanted=$1 list=$2 token
  [ -n "$list" ] || return 0
  [ -n "$wanted" ] || return 1
  local IFS=', '
  for token in $list; do
    [ -n "$token" ] || continue
    [ "$token" = "$wanted" ] && return 0
  done
  return 1
}

note_request_id() {  # <note-id>
  local id=$1 path
  for path in "$INBOX/$id.note" "$INBOX/handled/$id.note"; do
    [ -f "$path" ] || continue
    if awk '/^--$/ { exit } /^request_id=/ { sub(/^request_id=/, ""); print; exit }' "$path"; then
      return 0
    fi
  done
  return 1
}

reply_seq_of() {  # <reply-file>
  awk '/^--$/ { exit } /^seq=/ { sub(/^seq=/, ""); print; exit }' "$1"
}

reply_body_of() {  # <reply-file>
  awk 'body { print; next } /^--$/ { body = 1 }' "$1"
}

compact_reply_list() {  # <cursor>
  local cursor=$1 file seq
  for file in "$REPLIES"/*; do
    [ -f "$file" ] || continue
    case "${file##*/}" in
      .*) continue ;;
    esac
    seq=$(reply_seq_of "$file")
    case "$seq" in
      ''|*[!0-9]*) continue ;;
    esac
    [ "$seq" -gt "$cursor" ] || continue
    printf '%s\t%s\n' "$seq" "$file"
  done | sort -n -k1,1
}

telegram_woken_has() {  # <update-id>
  [ -f "$WOKEN" ] && grep -qxF "$1" "$WOKEN" 2>/dev/null
}

telegram_woken_add() {  # <update-id>
  printf '%s\n' "$1" >> "$WOKEN" 2>/dev/null || true
}

telegram_wake_append() {  # <update-id> <summary>
  local uid=$1 summary=$2
  telegram_woken_has "$uid" && return 0
  if fm_wake_append check "telegram:$uid" "check: telegram $uid - $summary"; then
    telegram_woken_add "$uid"
    return 0
  fi
  return 1
}

telegram_summary() {  # <name> <text>
  local name=$1 text=$2 head
  head=$(printf '%s' "$text" | tr '\n\t' '  ' | cut -c1-80)
  if [ -n "$name" ]; then
    printf 'from %s: %s' "$name" "$head"
  else
    printf '%s' "$head"
  fi
}

POLL_LOCK=
poll_release() {
  [ -n "$POLL_LOCK" ] || return 0
  fm_lock_release "$POLL_LOCK" 2>/dev/null || true
  POLL_LOCK=
}

FLUSH_LOCK=
flush_release() {
  [ -n "$FLUSH_LOCK" ] || return 0
  fm_lock_release "$FLUSH_LOCK" 2>/dev/null || true
  FLUSH_LOCK=
}

action_poll() {
  local raw offset last_ok=-1 rec rest uid chat user name text
  local note_out note_rc=0 summary captured=0 failed=0
  mkdir -p "$STATE" || return 1
  [ -r "$SCRIPT_DIR/fm-wake-lib.sh" ] || {
    echo "fm-telegram: $SCRIPT_DIR/fm-wake-lib.sh missing; cannot poll" >&2
    return 1
  }
  # shellcheck source=bin/fm-wake-lib.sh
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  POLL_LOCK="$STATE/.telegram-poll.lock"
  fm_lock_acquire_wait "$POLL_LOCK" || return 1
  trap poll_release EXIT

  offset=$(telegram_offset_read)
  raw=$(mktemp "$STATE/.telegram-poll.XXXXXX") || {
    poll_release
    return 1
  }
  if ! FM_TELEGRAM_OFFSET="$offset" FM_TELEGRAM_POLL_TIMEOUT="$POLL_TIMEOUT" \
      "$PY" "$PY_BIN" poll_list > "$raw"; then
    rm -f -- "$raw"
    poll_release
    return 1
  fi

  while IFS= read -r -d '' rec; do
    uid=${rec%%$'\t'*}
    rest=${rec#*$'\t'}
    chat=${rest%%$'\t'*}
    rest=${rest#*$'\t'}
    rest=${rest#*$'\t'}
    user=${rest%%$'\t'*}
    rest=${rest#*$'\t'}
    name=${rest%%$'\t'*}
    text=${rest#*$'\t'}
    case "$uid" in
      ''|*[!0-9]*) continue ;;
    esac
    if [ "$chat" != "$CHAT_ID" ]; then
      echo "fm-telegram: ignored update $uid: chat $chat is not the allowlisted chat" >&2
      last_ok=$uid
      continue
    fi
    if [ -z "${text//[[:space:]]/}" ]; then
      echo "fm-telegram: ignored update $uid: not a text message" >&2
      last_ok=$uid
      continue
    fi
    if ! user_allowed "$user" "$ALLOWED_USERS"; then
      echo "fm-telegram: ignored update $uid: sender $user is not in FM_TELEGRAM_ALLOWED_USERS" >&2
      last_ok=$uid
      continue
    fi

    note_rc=0
    note_out=$(printf '%s' "$text" | "$SCRIPT_DIR/fm-inbox.sh" note --request-id "tg:$uid" - 2>&1) || note_rc=$?
    if [ "$note_rc" -ne 0 ]; then
      printf '%s\n' "$note_out" >&2
      echo "fm-telegram: update $uid was not recorded; it stays pending" >&2
      failed=1
      break
    fi
    case "$note_out" in
      queued\ *)
        captured=$((captured + 1))
        printf 'fm-telegram: queued update %s\n' "$uid"
        ;;
      *)
        echo "fm-telegram: update $uid was already recorded" >&2
        ;;
    esac
    summary=$(telegram_summary "$name" "$text")
    if ! telegram_wake_append "$uid" "$summary"; then
      echo "fm-telegram: update $uid was recorded but its telegram wake could not be appended; it stays pending" >&2
      failed=1
      break
    fi
    last_ok=$uid
  done < "$raw"
  rm -f -- "$raw"

  if [ "$last_ok" -ge 0 ]; then
    if ! telegram_offset_write "$((last_ok + 1))"; then
      echo "fm-telegram: could not record the update cursor; the next poll re-fetches from $offset" >&2
      poll_release
      return 1
    fi
  fi
  poll_release
  trap - EXIT
  if [ "$captured" -eq 0 ] && [ "$failed" -eq 0 ]; then
    printf 'fm-telegram: no new updates\n'
  fi
  [ "$failed" -eq 0 ]
}

action_flush() {
  local cursor jmax seq file origin body delivered=0 failed=0
  mkdir -p "$STATE" || return 1
  [ -r "$SCRIPT_DIR/fm-wake-lib.sh" ] || {
    echo "fm-telegram: $SCRIPT_DIR/fm-wake-lib.sh missing; cannot flush" >&2
    return 1
  }
  # shellcheck source=bin/fm-wake-lib.sh
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  FLUSH_LOCK="$STATE/.telegram-reply.lock"
  fm_lock_acquire_wait "$FLUSH_LOCK" || return 1
  trap flush_release EXIT
  cursor=$(reply_cursor_read)
  if [ -f "$REPLY_JOURNAL" ]; then
    jmax=$(awk 'NF && $1 + 0 > m { m = $1 + 0 } END { print m + 0 }' "$REPLY_JOURNAL")
    case "$jmax" in
      ''|*[!0-9]*) jmax=0 ;;
    esac
    if [ "$jmax" -gt "$cursor" ]; then
      cursor=$jmax
      reply_cursor_write "$cursor" || true
    fi
    : > "$REPLY_JOURNAL"
  fi
  [ -d "$REPLIES" ] || {
    printf 'fm-telegram: nothing to flush\n'
    flush_release
    trap - EXIT
    return 0
  }

  while IFS=$'\t' read -r seq file; do
    [ -n "$seq" ] || continue
    if ! origin=$(note_request_id "${file##*/}"); then
      echo "fm-telegram: skipped reply ${file##*/} with no note record" >&2
      cursor=$seq
      reply_cursor_write "$cursor" || true
      continue
    fi
    case "$origin" in
      tg:*) ;;
      *)
        # A reply to a non-Telegram note belongs to another surface.
        cursor=$seq
        reply_cursor_write "$cursor" || true
        continue
        ;;
    esac
    body=$(reply_body_of "$file")
    if printf '%s' "$body" | "$PY" "$PY_BIN" send_message "$CHAT_ID"; then
      printf '%s\n' "$seq" >> "$REPLY_JOURNAL"
      if reply_cursor_write "$seq"; then
        : > "$REPLY_JOURNAL"
        cursor=$seq
        delivered=$((delivered + 1))
      else
        echo "fm-telegram: delivered reply ${file##*/} but could not record it; it may repeat" >&2
        failed=1
        break
      fi
    else
      echo "fm-telegram: reply ${file##*/} could not be delivered; it stays pending" >&2
      failed=1
      break
    fi
  done < <(compact_reply_list "$cursor")

  if [ "$delivered" -gt 0 ]; then
    printf 'fm-telegram: delivered %s reply/replies\n' "$delivered" >&2
  elif [ "$failed" -eq 0 ]; then
    printf 'fm-telegram: nothing to flush\n'
  fi
  flush_release
  trap - EXIT
  [ "$failed" -eq 0 ]
}

action_sync() {
  action_poll || return $?
  action_flush || return $?
  return 0
}

action_send() {
  local text
  if [ "$#" -ge 1 ] && [ "$1" != "-" ]; then
    text="$*"
  else
    text=$(cat)
  fi
  [ -n "${text//[[:space:]]/}" ] || {
    echo "fm-telegram: refusing to send empty text" >&2
    return 1
  }
  if printf '%s' "$text" | "$PY" "$PY_BIN" send_message "$CHAT_ID"; then
    printf 'fm-telegram: sent\n'
    return 0
  fi
  echo "fm-telegram: send failed" >&2
  return 1
}

action_status() {
  printf 'telegram chat: %s\n' "$CHAT_ID"
  printf 'api: %s\n' "$API_BASE"
  if [ -n "$ALLOWED_USERS" ]; then
    printf 'allowed users: %s\n' "$ALLOWED_USERS"
  else
    printf 'allowed users: any sender in the chat\n'
  fi
  printf 'cursor: %s (next update id)\n' "$(telegram_offset_read)"
  printf 'reply cursor: %s\n' "$(reply_cursor_read)"
  printf 'token: configured (value hidden)\n'
}

case "${1:-}" in
  poll) action_poll ;;
  flush) action_flush ;;
  sync) action_sync ;;
  send) shift; action_send "$@" ;;
  status) action_status ;;
  -h|--help) usage ;;
  *)
    usage
    exit 1
    ;;
esac
