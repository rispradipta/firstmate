#!/usr/bin/env bash
# Behavior tests for bin/fm-telegram.sh, the Telegram captain channel.
#
# The Telegram API is stubbed with a fake `python3` on PATH, exactly the way
# tests/fm-mail.test.sh stubs its mail engine, so no case needs a network or a
# live bot token. Every case goes through the executable public interface of
# bin/fm-telegram.sh and never asserts internal source bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TELEGRAM="$ROOT/bin/fm-telegram.sh"
TMP_ROOT=$(fm_test_tmproot fm-telegram)
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"

# The fake python3 handles the two subcommands the channel issues. poll_list
# cats a caller-prepared NUL-terminated response file; send_message records the
# message body it read from stdin. Both record control evidence the test reads.
write_fake_python() {
  cat > "$FAKEBIN/python3" <<'SH'
#!/usr/bin/env bash
case "${2:-}" in
  poll_list)
    [ -z "${FM_TELEGRAM_FAKE_OFFSETS:-}" ] || printf '%s\n' "${FM_TELEGRAM_OFFSET:-}" >> "$FM_TELEGRAM_FAKE_OFFSETS"
    if [ -n "${FM_TELEGRAM_FAKE_RESPONSE:-}" ] && [ -f "$FM_TELEGRAM_FAKE_RESPONSE" ]; then
      cat "$FM_TELEGRAM_FAKE_RESPONSE"
    fi
    exit "${FM_TELEGRAM_FAKE_POLL_RC:-0}"
    ;;
  send_message)
    if [ -n "${FM_TELEGRAM_FAKE_SENT:-}" ]; then
      cat >> "$FM_TELEGRAM_FAKE_SENT"
      printf '\n-----\n' >> "$FM_TELEGRAM_FAKE_SENT"
    fi
    if [ -n "${FM_TELEGRAM_FAKE_START:-}" ]; then
      printf '%s\n' "${4:-0}" >> "$FM_TELEGRAM_FAKE_START"
    fi
    if [ -n "${FM_TELEGRAM_FAKE_PROGRESS_WRITE:-}" ] && [ -n "${FM_TELEGRAM_SEND_PROGRESS:-}" ]; then
      printf '%s\n' "$FM_TELEGRAM_FAKE_PROGRESS_WRITE" > "$FM_TELEGRAM_SEND_PROGRESS"
    fi
    exit "${FM_TELEGRAM_FAKE_SEND_RC:-0}"
    ;;
esac
exit 0
SH
  chmod +x "$FAKEBIN/python3"
}
write_fake_python

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

write_env() {
  local home=$1
  printf '%s\n' \
    'FM_TELEGRAM_BOT_TOKEN=123456:fake-token-value' \
    'FM_TELEGRAM_CHAT_ID=900900' > "$home/.env"
}

# run_telegram <home> <args...>: run the channel with the fake python, no
# ambient Telegram configuration, and the fixture home.
run_telegram() {
  local home=$1
  shift
  env -u FM_TELEGRAM_BOT_TOKEN -u FM_TELEGRAM_CHAT_ID \
    -u FM_TELEGRAM_API_BASE \
    -u FM_TELEGRAM_POLL_TIMEOUT -u FM_TELEGRAM_CURSOR \
    FM_HOME="$home" PATH="$FAKEBIN:$PATH" \
    "$TELEGRAM" "$@"
}

# record <uid> <chat> <type> <user> <name> <text>: append one NUL-terminated
# poll record to <file>.
record() {
  local file=$1
  shift
  printf '%s\t%s\t%s\t%s\t%s\t%s\0' "$@" >> "$file"
}

test_help_and_usage() {
  local out rc=0
  out=$("$TELEGRAM" --help 2>&1) || rc=$?
  expect_code 0 "$rc" "--help must exit 0"
  assert_contains "$out" "poll" "--help lists poll"
  assert_contains "$out" "flush" "--help lists flush"
  assert_contains "$out" "send" "--help lists send"
  assert_contains "$out" "status" "--help lists status"
  rc=0
  out=$("$TELEGRAM" bogus 2>&1) || rc=$?
  expect_code 1 "$rc" "unknown subcommand must exit 1"
  assert_contains "$out" "poll" "unknown subcommand prints usage"
  pass "fm-telegram: help and usage plumbing"
}

test_missing_config_names_the_missing_value() {
  local home out rc=0
  home=$(make_home missing)
  out=$(run_telegram "$home" status 2>&1) || rc=$?
  expect_code 1 "$rc" "status without configuration must fail"
  assert_contains "$out" "FM_TELEGRAM_BOT_TOKEN" "missing-config error names the missing variable"
  assert_contains "$out" "FM_TELEGRAM_*" "missing-config error names the configuration family"
  assert_not_contains "$out" "fake-token-value" "missing-config error never leaks a token"
  pass "fm-telegram: missing configuration fails cleanly naming the variable"
}

test_env_overrides_env_file() {
  local home out
  home=$(make_home envfile)
  write_env "$home"
  out=$(FM_TELEGRAM_CHAT_ID=111222 FM_HOME="$home" PATH="$FAKEBIN:$PATH" \
    "$TELEGRAM" status 2>&1)
  assert_contains "$out" "telegram chat: 111222" "environment overrides .env for a direct invocation"
  out=$(FM_HOME="$home" PATH="$FAKEBIN:$PATH" "$TELEGRAM" status 2>&1)
  assert_contains "$out" "telegram chat: 900900" "status uses .env when the environment is unset"
  pass "fm-telegram: environment values override the .env file"
}

test_status_without_network_and_without_token() {
  local home out cursor
  home=$(make_home status)
  write_env "$home"
  cursor="$home/state/.telegram-cursor"
  printf '7\n' > "$cursor"
  out=$(run_telegram "$home" status 2>&1)
  assert_contains "$out" "telegram chat: 900900" "status prints the configured chat"
  assert_contains "$out" "cursor: 7" "status prints the offset cursor"
  assert_contains "$out" "reply cursor: 0" "status prints the reply cursor"
  assert_contains "$out" "value hidden" "status says the token is hidden"
  assert_not_contains "$out" "fake-token-value" "status never prints the token"
  pass "fm-telegram: status is network-free and never prints the token"
}

test_poll_queues_a_note_and_a_telegram_wake() {
  local home response offsets out wakeq notes
  home=$(make_home poll)
  write_env "$home"
  response="$TMP_ROOT/poll.response"
  record "$response" 5 900900 private 42 alice "hello captain"
  offsets="$TMP_ROOT/poll.offsets"
  : > "$offsets"

  out=$(FM_TELEGRAM_FAKE_RESPONSE="$response" FM_TELEGRAM_FAKE_OFFSETS="$offsets" \
    run_telegram "$home" poll 2>&1)
  assert_contains "$out" "queued update 5" "poll reports the queued update"
  assert_equals "0" "$(cat "$offsets")" "the first poll starts at offset 0"
  assert_equals "6" "$(cat "$home/state/.telegram-cursor")" "the cursor advances past the update"

  notes=$(find "$home/state/inbox" -maxdepth 1 -name '*.note' | wc -l | tr -d ' ')
  assert_equals "1" "$notes" "poll creates exactly one inbox note"
  assert_grep "request_id=tg:5" "$home/state/inbox/"*.note "the note carries the telegram request id"
  assert_grep "hello captain" "$home/state/inbox/"*.note "the note carries the captain's words"

  wakeq=$(cat "$home/state/.wake-queue" 2>/dev/null)
  assert_contains "$wakeq" "telegram:5" "poll queues a telegram check wake"
  assert_contains "$wakeq" "check: telegram 5" "the telegram wake payload names the update"
  assert_contains "$wakeq" "captain inbox note" "the durable note also queues its ordinary inbox wake"
  pass "fm-telegram: poll queues one durable note and a telegram wake"
}

test_cursor_continuity_across_restart() {
  local home response offsets out
  home=$(make_home continuity)
  write_env "$home"
  response="$TMP_ROOT/continuity.response"
  offsets="$TMP_ROOT/continuity.offsets"
  : > "$offsets"

  record "$response" 1 900900 private 42 alice "first"
  out=$(FM_TELEGRAM_FAKE_RESPONSE="$response" FM_TELEGRAM_FAKE_OFFSETS="$offsets" \
    run_telegram "$home" poll 2>&1)
  assert_contains "$out" "queued update 1" "first run queues update 1"

  # A restart resumes from the durable cursor, so the next getUpdates is asked
  # for offset 2 and only the new update is queued.
  : > "$response"
  record "$response" 2 900900 private 42 alice "second"
  out=$(FM_TELEGRAM_FAKE_RESPONSE="$response" FM_TELEGRAM_FAKE_OFFSETS="$offsets" \
    run_telegram "$home" poll 2>&1)
  assert_contains "$out" "queued update 2" "restart queues update 2"
  assert_equals $'0\n2' "$(cat "$offsets")" "the restart poll resumes at offset 2"
  assert_equals "3" "$(cat "$home/state/.telegram-cursor")" "the cursor advances to 3"
  assert_equals "2" "$(find "$home/state/inbox" -maxdepth 1 -name '*.note' | wc -l | tr -d ' ')" \
    "each update is captured once across the restart"
  pass "fm-telegram: the offset cursor carries continuity across a restart"
}

test_replayed_update_dedupes_by_request_id() {
  local home response out notes telegram_wakes
  home=$(make_home replay)
  write_env "$home"
  response="$TMP_ROOT/replay.response"
  record "$response" 5 900900 private 42 alice "hello captain"

  out=$(FM_TELEGRAM_FAKE_RESPONSE="$response" run_telegram "$home" poll 2>&1)
  assert_contains "$out" "queued update 5" "the first poll queues update 5"

  # Simulate a crash before the cursor was persisted: reset it and replay the
  # same update. The request id must return the original note, not a second one.
  printf '0\n' > "$home/state/.telegram-cursor"
  out=$(FM_TELEGRAM_FAKE_RESPONSE="$response" run_telegram "$home" poll 2>&1)
  assert_contains "$out" "update 5 was already recorded" "the replay is recognized as already recorded"
  assert_not_contains "$out" "queued update 5" "the replay must not surface a second wake line"
  notes=$(find "$home/state/inbox" -maxdepth 1 -name '*.note' | wc -l | tr -d ' ')
  assert_equals "1" "$notes" "a replayed update never creates a second note"
  telegram_wakes=$(grep -c "check	telegram:5" "$home/state/.wake-queue" 2>/dev/null || true)
  assert_equals "1" "$telegram_wakes" "a replayed update never duplicates its telegram wake"
  pass "fm-telegram: a replayed update dedupes through its request id"
}

test_malformed_and_disallowed_updates_are_ignored() {
  local home response out notes
  home=$(make_home ignore)
  write_env "$home"
  response="$TMP_ROOT/ignore.response"
  # A text message from another chat, a non-text message from the right chat,
  # and a text message from a sender that is not on the optional user allowlist.
  record "$response" 1 555 private 42 alice "other chat"
  record "$response" 2 900900 private 42 alice ""
  record "$response" 3 900900 private 42 alice "not allowed sender"

  out=$(FM_TELEGRAM_ALLOWED_USERS="77" FM_TELEGRAM_FAKE_RESPONSE="$response" \
    run_telegram "$home" poll 2>&1)
  assert_contains "$out" "ignored update 1" "a non-allowlisted chat is ignored"
  assert_contains "$out" "not the allowlisted chat" "the chat diagnostic says why"
  assert_contains "$out" "ignored update 2" "a non-text update is ignored"
  assert_contains "$out" "not a text message" "the non-text diagnostic says why"
  assert_contains "$out" "ignored update 3" "a non-allowlisted sender is ignored"
  assert_contains "$out" "FM_TELEGRAM_ALLOWED_USERS" "the sender diagnostic names the allowlist"
  assert_contains "$out" "no new updates" "an all-ignored poll reports no new updates"

  notes=$(find "$home/state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' ')
  assert_equals "0" "$notes" "ignored updates are never queued as the captain's words"
  assert_equals "4" "$(cat "$home/state/.telegram-cursor")" "the cursor still advances past ignored updates"
  pass "fm-telegram: malformed, non-text, and non-allowlisted updates are ignored"
}

test_allowed_user_is_accepted() {
  local home response out
  home=$(make_home allowed)
  write_env "$home"
  response="$TMP_ROOT/allowed.response"
  record "$response" 9 900900 private 77 bob "on the list"
  out=$(FM_TELEGRAM_ALLOWED_USERS="12, 77" FM_TELEGRAM_FAKE_RESPONSE="$response" \
    run_telegram "$home" poll 2>&1)
  assert_contains "$out" "queued update 9" "a sender on the allowlist is accepted"
  assert_equals "1" "$(find "$home/state/inbox" -maxdepth 1 -name '*.note' | wc -l | tr -d ' ')" \
    "the allowed message is queued once"
  pass "fm-telegram: a sender on FM_TELEGRAM_ALLOWED_USERS is accepted"
}

test_flush_delivers_each_reply_once() {
  local home note_out note_id out sent
  home=$(make_home flush)
  write_env "$home"
  note_out=$(FM_HOME="$home" "$ROOT/bin/fm-inbox.sh" note --request-id tg:7 - <<< "question")
  note_id=${note_out%%$'\n'*}
  note_id=${note_id#queued }
  [ -n "$note_id" ] || fail "fixture could not create the telegram note: $note_out"
  FM_HOME="$home" "$ROOT/bin/fm-inbox.sh" reply "$note_id" "the answer" >/dev/null

  sent="$TMP_ROOT/flush.sent"
  : > "$sent"
  out=$(FM_TELEGRAM_FAKE_SENT="$sent" run_telegram "$home" flush 2>&1)
  assert_contains "$out" "delivered 1 reply" "flush reports one delivered reply"
  assert_equals "1" "$(grep -c 'the answer' "$sent" || true)" "the reply is sent exactly once"
  assert_equals "1" "$(cat "$home/state/.telegram-reply-cursor")" "the reply cursor records the sequence"

  out=$(FM_TELEGRAM_FAKE_SENT="$sent" run_telegram "$home" flush 2>&1)
  assert_equals "1" "$(grep -c 'the answer' "$sent" || true)" "a second flush must not re-send the reply"
  pass "fm-telegram: a recorded reply is delivered exactly once"
}

test_flush_skips_replies_that_are_not_telegram() {
  local home note_out note_id out sent
  home=$(make_home flush-other)
  write_env "$home"
  note_out=$(FM_HOME="$home" "$ROOT/bin/fm-inbox.sh" note - <<< "an email-ish note")
  note_id=${note_out%%$'\n'*}
  note_id=${note_id#queued }
  [ -n "$note_id" ] || fail "fixture could not create the note: $note_out"
  FM_HOME="$home" "$ROOT/bin/fm-inbox.sh" reply "$note_id" "not for telegram" >/dev/null

  sent="$TMP_ROOT/flush-other.sent"
  : > "$sent"
  out=$(FM_TELEGRAM_FAKE_SENT="$sent" run_telegram "$home" flush 2>&1)
  assert_contains "$out" "nothing to flush" "a non-telegram reply is not delivered by telegram"
  assert_equals "0" "$(grep -c 'not for telegram' "$sent" || true)" "the telegram plane must not post another surface's reply"
  pass "fm-telegram: flush delivers only replies whose note came from Telegram"
}

test_send_requires_configuration() {
  local home out rc=0
  home=$(make_home send-missing)
  out=$(run_telegram "$home" send "hello" 2>&1) || rc=$?
  expect_code 1 "$rc" "send without configuration must fail"
  assert_contains "$out" "FM_TELEGRAM_BOT_TOKEN" "send names the missing configuration"
  pass "fm-telegram: send refuses without configuration"
}

test_whitespace_only_message_is_ignored_without_wedging() {
  local home response out notes
  home=$(make_home whitespace)
  write_env "$home"
  response="$TMP_ROOT/whitespace.response"
  record "$response" 5 900900 private 42 alice "   "
  record "$response" 6 900900 private 42 alice "real message"

  out=$(FM_TELEGRAM_FAKE_RESPONSE="$response" run_telegram "$home" poll 2>&1)
  assert_contains "$out" "ignored update 5" "a whitespace-only message is ignored, not captured"
  assert_contains "$out" "queued update 6" "later updates still process after a whitespace-only message"
  assert_equals "7" "$(cat "$home/state/.telegram-cursor")" "the cursor advances past the whitespace-only message"
  notes=$(find "$home/state/inbox" -maxdepth 1 -name '*.note' | wc -l | tr -d ' ')
  assert_equals "1" "$notes" "only the real message becomes a note"
  pass "fm-telegram: a whitespace-only message does not wedge the poll cursor"
}

test_replayed_update_repairs_a_missing_telegram_wake() {
  local home response out wakeq
  home=$(make_home wake-repair)
  write_env "$home"
  # The note was recorded but the run died before its telegram wake landed.
  FM_HOME="$home" "$ROOT/bin/fm-inbox.sh" note --request-id tg:5 - <<< "hello captain" >/dev/null
  response="$TMP_ROOT/wake-repair.response"
  record "$response" 5 900900 private 42 alice "hello captain"

  out=$(FM_TELEGRAM_FAKE_RESPONSE="$response" run_telegram "$home" poll 2>&1)
  assert_contains "$out" "update 5 was already recorded" "the replay is recognized"
  wakeq=$(cat "$home/state/.wake-queue" 2>/dev/null)
  assert_contains "$wakeq" "check: telegram 5" "the replay appends the missing telegram wake"
  pass "fm-telegram: a replayed update repairs a missing telegram wake"
}

test_unparseable_api_base_never_leaks_the_token() {
  local out rc=0
  out=$(FM_TELEGRAM_BOT_TOKEN=123456:fake-token-value \
    FM_TELEGRAM_API_BASE=api.telegram.org \
    python3 "$ROOT/bin/fm-telegram.py" poll_list 2>&1) || rc=$?
  expect_code 1 "$rc" "an unparseable API base fails the poll cleanly"
  assert_not_contains "$out" "fake-token-value" "the token never reaches the diagnostic"
  assert_contains "$out" "getUpdates request failed" "the failure is reported token-free"
  pass "fm-telegram.py: an unparseable API base never leaks the token"
}

test_flush_delivers_a_reply_to_an_acknowledged_note() {
  local home note_out note_id out sent
  home=$(make_home flush-handled)
  write_env "$home"
  note_out=$(FM_HOME="$home" "$ROOT/bin/fm-inbox.sh" note --request-id tg:7 - <<< "question")
  note_id=${note_out%%$'\n'*}
  note_id=${note_id#queued }
  [ -n "$note_id" ] || fail "fixture could not create the telegram note: $note_out"
  FM_HOME="$home" "$ROOT/bin/fm-inbox.sh" reply "$note_id" "the answer" >/dev/null
  FM_HOME="$home" "$ROOT/bin/fm-inbox.sh" drain --ack "$note_id" >/dev/null

  sent="$TMP_ROOT/flush-handled.sent"
  : > "$sent"
  out=$(FM_TELEGRAM_FAKE_SENT="$sent" run_telegram "$home" flush 2>&1)
  assert_contains "$out" "delivered 1 reply" "a reply to an acknowledged note still delivers"
  assert_equals "1" "$(grep -c 'the answer' "$sent" || true)" "the acknowledged note's reply is sent once"
  pass "fm-telegram: a reply to an acknowledged note is still delivered"
}

test_concurrent_flushes_deliver_each_reply_once() {
  local home note_out note_id sent
  home=$(make_home flush-race)
  write_env "$home"
  note_out=$(FM_HOME="$home" "$ROOT/bin/fm-inbox.sh" note --request-id tg:8 - <<< "question")
  note_id=${note_out%%$'\n'*}
  note_id=${note_id#queued }
  [ -n "$note_id" ] || fail "fixture could not create the telegram note: $note_out"
  FM_HOME="$home" "$ROOT/bin/fm-inbox.sh" reply "$note_id" "the race answer" >/dev/null

  sent="$TMP_ROOT/flush-race.sent"
  : > "$sent"
  FM_TELEGRAM_FAKE_SENT="$sent" run_telegram "$home" flush >/dev/null 2>&1 &
  FM_TELEGRAM_FAKE_SENT="$sent" run_telegram "$home" flush >/dev/null 2>&1 &
  wait
  assert_equals "1" "$(grep -c 'the race answer' "$sent" || true)" "two concurrent flushes deliver the reply once"
  pass "fm-telegram: concurrent flushes cannot double-deliver a reply"
}

test_flush_resumes_a_partial_reply_at_its_recorded_chunk() {
  local home note_out note_id seq out sent starts
  home=$(make_home flush-resume)
  write_env "$home"
  note_out=$(FM_HOME="$home" "$ROOT/bin/fm-inbox.sh" note --request-id tg:9 - <<< "question")
  note_id=${note_out%%$'\n'*}
  note_id=${note_id#queued }
  [ -n "$note_id" ] || fail "fixture could not create the telegram note: $note_out"
  FM_HOME="$home" "$ROOT/bin/fm-inbox.sh" reply "$note_id" "the long answer" >/dev/null
  seq=$(awk '/^--$/ { exit } /^seq=/ { sub(/^seq=/, ""); print; exit }' "$home/state/inbox/.replies/$note_id")
  printf '1\n' > "$home/state/.telegram-reply-progress.$seq"

  sent="$TMP_ROOT/flush-resume.sent"
  starts="$TMP_ROOT/flush-resume.starts"
  : > "$sent"
  : > "$starts"
  out=$(FM_TELEGRAM_FAKE_SENT="$sent" FM_TELEGRAM_FAKE_START="$starts" run_telegram "$home" flush 2>&1)
  assert_contains "$out" "delivered 1 reply" "the pending reply is delivered"
  assert_equals "1" "$(cat "$starts")" "flush resumes at the recorded chunk, not the start"
  assert_absent "$home/state/.telegram-reply-progress.$seq" "the chunk progress is removed once delivered"
  assert_equals "$seq" "$(cat "$home/state/.telegram-reply-cursor")" "the reply cursor advances after full delivery"
  pass "fm-telegram: flush resumes a partially delivered reply at its recorded chunk"
}

test_flush_keeps_chunk_progress_when_a_send_fails() {
  local home note_out note_id seq out sent
  home=$(make_home flush-progress-fail)
  write_env "$home"
  note_out=$(FM_HOME="$home" "$ROOT/bin/fm-inbox.sh" note --request-id tg:10 - <<< "question")
  note_id=${note_out%%$'\n'*}
  note_id=${note_id#queued }
  [ -n "$note_id" ] || fail "fixture could not create the telegram note: $note_out"
  FM_HOME="$home" "$ROOT/bin/fm-inbox.sh" reply "$note_id" "a very long answer" >/dev/null
  seq=$(awk '/^--$/ { exit } /^seq=/ { sub(/^seq=/, ""); print; exit }' "$home/state/inbox/.replies/$note_id")

  sent="$TMP_ROOT/flush-progress-fail.sent"
  : > "$sent"
  out=$(FM_TELEGRAM_FAKE_SENT="$sent" FM_TELEGRAM_FAKE_PROGRESS_WRITE=2 \
    FM_TELEGRAM_FAKE_SEND_RC=1 run_telegram "$home" flush 2>&1)
  assert_contains "$out" "stays pending" "a failed reply stays pending"
  assert_equals "2" "$(cat "$home/state/.telegram-reply-progress.$seq")" "the partial chunk progress survives the failure"
  assert_absent "$home/state/.telegram-reply-cursor" "the reply cursor does not advance on a partial delivery"
  pass "fm-telegram: a failed send keeps the partial chunk progress"
}

test_send_message_resumes_after_a_midway_chunk_failure() {
  local rc=0
  python3 - "$ROOT/bin/fm-telegram.py" "$TMP_ROOT/send-message.progress" <<'PY' || rc=$?
import importlib.util
import io
import os
import sys

module_path, progress = sys.argv[1:3]
spec = importlib.util.spec_from_file_location("fm_telegram_under_test", module_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

text = "".join("line %04d\n" % i for i in range(1200))
chunks = mod._chunks(text)
assert len(chunks) == 3, ("expected three chunks", len(chunks))

os.environ["FM_TELEGRAM_SEND_PROGRESS"] = progress
first = []
calls = {"n": 0}

def first_call(method, params):
    calls["n"] += 1
    if calls["n"] == 2:
        return None
    first.append(params["text"])
    return {"message_id": calls["n"]}

mod.call = first_call
sys.stdin = io.StringIO(text)
rc = mod.cmd_send_message(["chat", "0"])
assert rc == 1, ("the first run must fail at the second chunk", rc)
assert first == [chunks[0]], ("only the first chunk was accepted", first)
with open(progress) as handle:
    start = int(handle.read().strip())
assert start == 1, ("progress records the one accepted chunk", start)

second = []

def second_call(method, params):
    second.append(params["text"])
    return {"message_id": len(second)}

mod.call = second_call
sys.stdin = io.StringIO(text)
rc = mod.cmd_send_message(["chat", str(start)])
assert rc == 0, ("the resume must succeed", rc)
assert second == chunks[1:], ("the resume sends only the remaining chunks", second)
assert chunks[0] not in second, "the accepted chunk is never posted twice"
PY
  expect_code 0 "$rc" "the chunk-resume driver must pass"
  pass "fm-telegram.py: a mid-way chunk failure resumes without reposting a chunk"
}

test_help_and_usage
test_missing_config_names_the_missing_value
test_env_overrides_env_file
test_status_without_network_and_without_token
test_poll_queues_a_note_and_a_telegram_wake
test_cursor_continuity_across_restart
test_replayed_update_dedupes_by_request_id
test_malformed_and_disallowed_updates_are_ignored
test_allowed_user_is_accepted
test_flush_delivers_each_reply_once
test_flush_skips_replies_that_are_not_telegram
test_send_requires_configuration
test_whitespace_only_message_is_ignored_without_wedging
test_replayed_update_repairs_a_missing_telegram_wake
test_unparseable_api_base_never_leaks_the_token
test_flush_delivers_a_reply_to_an_acknowledged_note
test_concurrent_flushes_deliver_each_reply_once
test_flush_resumes_a_partial_reply_at_its_recorded_chunk
test_flush_keeps_chunk_progress_when_a_send_fails
test_send_message_resumes_after_a_midway_chunk_failure
