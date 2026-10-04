#!/usr/bin/env bash
# Behavior tests for bin/fm-telegram-check.sh, the standing Telegram sync.
#
# Two surfaces are exercised through their executable interfaces:
#
#   * arming/disarming state/telegram.check.sh with its trust binding, including
#     the refusal paths (symlink at the shim path, missing Telegram plane);
#
#   * the `check` action itself, which runs the real fm-telegram.sh sync against
#     a scratch home whose .env and fake python3 decide the outcome. The cases
#     that matter are the reporting contract: a successful sync that surfaces a
#     new message emits one wake line, a failing sync reports one line, a proven
#     no-op stays silent, and a fail-closed sync that queued a message still
#     doorbells.
#
# No case ever contacts Telegram.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-telegram-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-telegram-check)
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"

cat > "$FAKEBIN/python3" <<'SH'
#!/usr/bin/env bash
case "${2:-}" in
  poll_list)
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
    exit "${FM_TELEGRAM_FAKE_SEND_RC:-0}"
    ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/python3"

# run_check <home> <out> <check> [env...]
run_check() {
  local home=$1 out=$2 check=$3
  shift 3
  local status=0
  env -u FM_TELEGRAM_BOT_TOKEN -u FM_TELEGRAM_CHAT_ID -u FM_TELEGRAM_ALLOWED_USERS \
    -u FM_TELEGRAM_CHECK_BUDGET \
    FM_CHECK_TIMEOUT=30 \
    "$@" FM_HOME="$home" PATH="$FAKEBIN:$PATH" \
    "$check" check >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "check exit"
}

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

record() {
  local file=$1
  shift
  printf '%s\t%s\t%s\t%s\t%s\t%s\0' "$@" >> "$file"
}

test_help_and_usage() {
  local out rc=0
  out=$("$CHECK" --help 2>&1) || rc=$?
  expect_code 0 "$rc" "--help must exit 0"
  assert_contains "$out" "check" "--help lists the check action"
  assert_contains "$out" "arm" "--help lists the arm action"
  assert_contains "$out" "disarm" "--help lists the disarm action"
  rc=0
  out=$("$CHECK" bogus 2>&1) || rc=$?
  expect_code 2 "$rc" "unknown action must exit 2"
  assert_contains "$out" "unknown action" "unknown action is refused loudly"
  pass "fm-telegram-check: help and usage plumbing"
}

test_arm_writes_and_binds_the_check_and_disarm_removes_it() {
  local home out
  home=$(make_home arm)
  write_env "$home"
  out=$(FM_HOME="$home" "$CHECK" arm 2>&1) || fail "arm must succeed: $out"
  assert_contains "$out" "armed: state/telegram.check.sh" "arm names the shim it wrote"
  assert_present "$home/state/telegram.check.sh" "arm writes the check shim"
  assert_present "$home/state/telegram.check-trust" "arm binds the shim for the watcher"
  assert_contains "$(cat "$home/state/telegram.check.sh")" "fm-telegram-check.sh check" "shim dispatches the check action"
  assert_contains "$(cat "$home/state/telegram.check.sh")" "FM_HOME=$home" "shim pins the absolute home"

  out=$(FM_HOME="$home" "$CHECK" arm 2>&1) || fail "re-arm must succeed: $out"
  assert_contains "$out" "armed" "re-arm stays armed"

  out=$(FM_HOME="$home" "$CHECK" disarm 2>&1) || fail "disarm must succeed: $out"
  assert_absent "$home/state/telegram.check.sh" "disarm removes the check shim"
  assert_absent "$home/state/telegram.check-trust" "disarm removes the trust binding"
  assert_absent "$home/state/.telegram-check" "disarm removes the report record"
  pass "fm-telegram-check: arm writes and binds, re-arm is idempotent, disarm removes"
}

test_arm_resolves_a_relative_home_into_the_shim() {
  local home rel out
  home=$(make_home relative)
  write_env "$home"
  rel="$(basename "$home")"
  out=$(cd "$TMP_ROOT" && env FM_HOME="$rel" "$CHECK" arm 2>&1) || fail "arm with a relative FM_HOME must succeed: $out"
  assert_contains "$(cat "$home/state/telegram.check.sh")" "export FM_HOME=$home" "the shim pins the resolved absolute home"
  pass "fm-telegram-check: arm resolves a relative home into the shim"
}

test_arm_refuses_a_symlink_at_the_shim_path() {
  local home target out rc=0
  home=$(make_home symlink)
  write_env "$home"
  target="$TMP_ROOT/outside"
  mkdir -p "$target"
  printf '#!/usr/bin/env bash\n' > "$target/telegram.check.sh"
  ln -s "$target/telegram.check.sh" "$home/state/telegram.check.sh"
  out=$(FM_HOME="$home" "$CHECK" arm 2>&1) || rc=$?
  expect_code 1 "$rc" "arm must refuse a symlink at the shim path"
  assert_contains "$out" "could not write" "arm reports the shim write failure"
  assert_absent "$home/state/telegram.check-trust" "no trust binding is left behind by a refused arm"
  pass "fm-telegram-check: arm refuses a symlink at the shim path"
}

test_arm_refuses_without_the_telegram_plane() {
  local tmpbin home out rc=0
  tmpbin="$TMP_ROOT/plane/bin"
  home="$TMP_ROOT/plane/home"
  mkdir -p "$tmpbin" "$home/state"
  cp "$ROOT/bin/fm-telegram-check.sh" "$tmpbin/"
  for lib in fm-timeout-lib.sh fm-pr-lib.sh fm-line-cap-lib.sh fm-check-lib.sh; do
    [ -e "$tmpbin/$lib" ] || ln -s "$ROOT/bin/$lib" "$tmpbin/$lib"
  done
  out=$(FM_HOME="$home" "$tmpbin/fm-telegram-check.sh" arm 2>&1) || rc=$?
  expect_code 1 "$rc" "arm must refuse when the Telegram plane is missing"
  assert_contains "$out" "Telegram plane is missing" "arm names the missing plane"
  assert_absent "$home/state/telegram.check.sh" "a refused arm writes no shim"
  pass "fm-telegram-check: arm refuses without the Telegram plane"
}

test_successful_sync_with_a_new_message_emits_one_wake_line() {
  local home response out wakeq
  home=$(make_home success)
  write_env "$home"
  response="$TMP_ROOT/success.response"
  record "$response" 5 900900 private 42 alice "hello captain"
  out="$home/out.txt"
  run_check "$home" "$out" "$CHECK" FM_TELEGRAM_FAKE_RESPONSE="$response"
  assert_contains "$(cat "$out")" "telegram: new message: queued update 5" "a successful sync that queued a message emits one wake line"
  [ "$(wc -l < "$out" | tr -d '[:space:]')" = 1 ] || fail "a successful new-message sync reports exactly one line: $(cat "$out")"
  assert_present "$home/state/.telegram-check" "a successful sync records its outcome"
  assert_contains "$(cat "$home/state/.telegram-check")" "fm-telegram-check-v1" "the record carries its schema"
  wakeq="$home/state/.wake-queue"
  assert_contains "$(cat "$wakeq" 2>/dev/null)" "check: telegram 5" "the check-run poll still queues the telegram wake"
  pass "fm-telegram-check: a sync that surfaces a message emits one wake line"
}

test_unconfigured_home_is_reported_once() {
  local home out
  home=$(make_home unconfigured)
  out="$home/out.txt"
  run_check "$home" "$out" "$CHECK"
  assert_contains "$(cat "$out")" "telegram: missing required" "an unconfigured home reports the missing setup"
  assert_contains "$(cat "$out")" "FM_TELEGRAM_BOT_TOKEN" "the report names the missing variable"
  out="$home/out2.txt"
  run_check "$home" "$out" "$CHECK"
  [ ! -s "$out" ] || fail "the unconfigured state must not repeat: $(cat "$out")"
  pass "fm-telegram-check: an unconfigured home is reported once, not every poll"
}

test_proven_no_op_stays_silent() {
  local home response out
  home=$(make_home noop)
  write_env "$home"
  response="$TMP_ROOT/noop.response"
  : > "$response"
  out="$home/out.txt"
  run_check "$home" "$out" "$CHECK" FM_TELEGRAM_FAKE_RESPONSE="$response"
  [ ! -s "$out" ] || fail "a sync with no new updates must stay silent: $(cat "$out")"
  out="$home/out2.txt"
  run_check "$home" "$out" "$CHECK" FM_TELEGRAM_FAKE_RESPONSE="$response"
  [ ! -s "$out" ] || fail "a repeated no-op must stay silent: $(cat "$out")"
  pass "fm-telegram-check: a proven no-op stays silent"
}

test_repeated_failure_that_queued_a_message_still_wakes() {
  # A sync can queue a wake and then fail with the same cause as the last
  # check. Difference-record silence would leave that wake queued and unacted;
  # the check must print again so the watcher wakes firstmate to drain it.
  local tmpbin home out check_bin
  tmpbin="$TMP_ROOT/repeat-wake/bin"
  home="$TMP_ROOT/repeat-wake/home"
  mkdir -p "$tmpbin" "$home/state"
  check_bin="$tmpbin/fm-telegram-check.sh"
  cp "$ROOT/bin/fm-telegram-check.sh" "$tmpbin/"
  for lib in fm-timeout-lib.sh fm-pr-lib.sh fm-line-cap-lib.sh fm-check-lib.sh; do
    [ -e "$tmpbin/$lib" ] || ln -s "$ROOT/bin/$lib" "$tmpbin/$lib"
  done
  cat > "$tmpbin/fm-telegram.sh" <<'SH'
#!/usr/bin/env bash
printf '5\n' >> "$FM_HOME/state/.telegram-woken"
echo "fm-telegram: connection refused" >&2
exit 1
SH
  chmod +x "$tmpbin/fm-telegram.sh"

  out="$home/out1.txt"
  run_check "$home" "$out" "$check_bin"
  assert_contains "$(cat "$out")" "telegram: connection refused" "the first failed sync reports the failure"
  [ "$(wc -l < "$out" | tr -d '[:space:]')" = 1 ] || fail "the first report is exactly one line: $(cat "$out")"

  out="$home/out2.txt"
  run_check "$home" "$out" "$check_bin"
  assert_contains "$(cat "$out")" "telegram: connection refused" "the same failure must still print when that sync queued a message"
  [ "$(wc -l < "$out" | tr -d '[:space:]')" = 1 ] || fail "the repeat report is exactly one line: $(cat "$out")"
  pass "fm-telegram-check: a repeated failure that queued a message still wakes"
}

test_failure_is_reported_once_until_it_changes() {
  local home response out
  home=$(make_home failure)
  write_env "$home"
  response="$TMP_ROOT/failure.response"
  : > "$response"

  # First, a healthy no-op clears the record.
  out="$home/out0.txt"
  run_check "$home" "$out" "$CHECK" FM_TELEGRAM_FAKE_RESPONSE="$response"
  [ ! -s "$out" ] || fail "the healthy poll must be silent: $(cat "$out")"

  # A poll API failure names itself, and a repeat is silent.
  out="$home/out1.txt"
  run_check "$home" "$out" "$CHECK" FM_TELEGRAM_FAKE_RESPONSE="$response" FM_TELEGRAM_FAKE_POLL_RC=1
  assert_contains "$(cat "$out")" "telegram: sync failed" "a failing sync reports one line"
  [ "$(wc -l < "$out" | tr -d '[:space:]')" = 1 ] || fail "a failing sync reports exactly one line: $(cat "$out")"

  out="$home/out2.txt"
  run_check "$home" "$out" "$CHECK" FM_TELEGRAM_FAKE_RESPONSE="$response" FM_TELEGRAM_FAKE_POLL_RC=1
  [ ! -s "$out" ] || fail "the same failure must not be reported again: $(cat "$out")"
  pass "fm-telegram-check: a sync failure is reported once and re-reported after recovery"
}

test_missing_telegram_plane_is_reported() {
  local tmpbin home out check_bin
  tmpbin="$TMP_ROOT/plane2/bin"
  home="$TMP_ROOT/plane2/home"
  mkdir -p "$tmpbin" "$home/state"
  check_bin="$tmpbin/fm-telegram-check.sh"
  cp "$ROOT/bin/fm-telegram-check.sh" "$tmpbin/"
  for lib in fm-timeout-lib.sh fm-pr-lib.sh fm-line-cap-lib.sh fm-check-lib.sh; do
    [ -e "$tmpbin/$lib" ] || ln -s "$ROOT/bin/$lib" "$tmpbin/$lib"
  done
  out="$home/out.txt"
  run_check "$home" "$out" "$check_bin"
  assert_contains "$(cat "$out")" "telegram: fm-telegram.sh is missing next to this check" "a home lacking the Telegram plane reports it"
  pass "fm-telegram-check: a missing Telegram plane is reported, not assumed"
}

test_help_and_usage
test_arm_writes_and_binds_the_check_and_disarm_removes_it
test_arm_resolves_a_relative_home_into_the_shim
test_arm_refuses_a_symlink_at_the_shim_path
test_arm_refuses_without_the_telegram_plane
test_successful_sync_with_a_new_message_emits_one_wake_line
test_unconfigured_home_is_reported_once
test_proven_no_op_stays_silent
test_repeated_failure_that_queued_a_message_still_wakes
test_failure_is_reported_once_until_it_changes
test_missing_telegram_plane_is_reported
