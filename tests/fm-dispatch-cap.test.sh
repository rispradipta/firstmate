#!/usr/bin/env bash
# Behavior tests for the standing dispatch concurrency cap:
# bin/fm-dispatch-cap.sh (the owner) and its enforcement in bin/fm-spawn.sh.
#
# The cap is firstmate-side, default 2 per home, and binds while attended as
# well as away. A fresh dispatch at cap must be a distinct at-cap outcome
# (exit 10), not an error, and must leave the backlog item queued; freeing a
# slot must admit the next queued item.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CAP="$ROOT/bin/fm-dispatch-cap.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-dispatch-cap)

# --- the cap owner ----------------------------------------------------------

make_cap_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config" "$home/data"
  printf '%s\n' "$home"
}

run_cap() {  # <home> <args...>
  local home=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    "$CAP" "$@"
}

write_meta() {  # <home> <id> <kind>
  fm_write_meta "$1/state/$2.meta" "window=firstmate:fm-$2" "kind=$3"
}

test_absent_config_resolves_the_default_cap_of_two() {
  local home rc out
  home=$(make_cap_home default)
  assert_equals 2 "$(run_cap "$home" cap)" "an absent config should resolve the default cap"
  rc=0
  out=$(run_cap "$home" check) || rc=$?
  expect_code 0 "$rc" "an empty home should admit a dispatch"
  assert_equals "live=0 cap=2" "$out" "check status line for an empty home"
  pass "absent config resolves the default cap 2 and an empty home admits"
}

test_config_value_overrides_the_default() {
  local home
  home=$(make_cap_home override)
  printf '3\n' > "$home/config/max-concurrent-workers"
  assert_equals 3 "$(run_cap "$home" cap)" "config value should override the default"
  write_meta "$home" a ship
  write_meta "$home" b scout
  assert_equals 2 "$(run_cap "$home" live)" "live should count both tasks"
  pass "config/max-concurrent-workers overrides the default cap"
}

test_invalid_config_is_refused_not_defaulted() {
  local home rc out
  home=$(make_cap_home invalid)
  printf 'abc\n' > "$home/config/max-concurrent-workers"
  rc=0
  out=$(run_cap "$home" cap 2>&1) || rc=$?
  expect_code 2 "$rc" "a malformed cap must be refused"
  assert_contains "$out" "max-concurrent-workers" "diagnostic did not name the config file"
  printf '0\n' > "$home/config/max-concurrent-workers"
  rc=0
  run_cap "$home" cap >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "zero is not a positive cap"
  printf '2\n3\n' > "$home/config/max-concurrent-workers"
  rc=0
  run_cap "$home" cap >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "a multi-line cap must be refused"
  rm -f "$home/config/max-concurrent-workers"
  ln -s /dev/null "$home/config/max-concurrent-workers"
  rc=0
  run_cap "$home" cap >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "a symlinked cap must be refused"
  pass "malformed, zero, multi-line, and symlinked caps are refused rather than defaulted"
}

test_live_counts_only_ordinary_tasks() {
  local home
  home=$(make_cap_home live)
  write_meta "$home" a ship
  write_meta "$home" b scout
  write_meta "$home" sm secondmate
  assert_equals 2 "$(run_cap "$home" live)" "a secondmate record must not count against the cap"
  pass "live counts ordinary ship and scout records only"
}

test_check_declines_at_cap_and_admits_after_a_slot_frees() {
  local home rc out
  home=$(make_cap_home atcap)
  write_meta "$home" a ship
  rc=0
  out=$(run_cap "$home" check) || rc=$?
  expect_code 0 "$rc" "one live task is below the cap of 2"
  write_meta "$home" b scout
  rc=0
  out=$(run_cap "$home" check) || rc=$?
  expect_code 10 "$rc" "two live tasks reach the cap of 2"
  assert_equals "live=2 cap=2" "$out" "at-cap status line"
  # Re-dispatching a task that already holds a record measures it against the
  # OTHER busy slots rather than against itself.
  rc=0
  out=$(run_cap "$home" check --exclude a) || rc=$?
  expect_code 0 "$rc" "a redispatch of an existing task should not count its own record"
  assert_equals "live=1 cap=2" "$out" "excluded status line"
  rm -f "$home/state/a.meta"
  rc=0
  out=$(run_cap "$home" check) || rc=$?
  expect_code 0 "$rc" "a freed slot should admit the next dispatch"
  pass "check declines at cap with the at-cap code, exempts the task's own record, and admits once a slot frees"
}

# --- the dispatch path ------------------------------------------------------

# A home with a real backlog, a real project clone with an origin, a pooled
# worktree, and stubs for every tool the spawn path shells out to. Layout and
# stubs mirror tests/fm-backlog-atomicity.test.sh so the spawn reaches its
# backlog transition for real.
make_dispatch_home() {  # <name> <id...>
  local name=$1 case_dir home fakebin id
  shift
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  fakebin=$(fm_fakebin "$case_dir")
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  printf 'claude\n' > "$home/config/crew-harness"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
    > "$home/data/backlog.md"
  cat > "$home/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
EOF
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise the standing dispatch cap for $id.

## Firstmate spec
Keep the item queued while this home is at cap.

# Definition of done
Delivery contract: mode=no-mistakes
EOF
  done
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;; esac
case "${1:-}" in display-message) printf 'firstmate\n'; exit 0 ;; esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh gh-axi no-mistakes
  fm_git_init_commit "$case_dir/project"
  fm_git_add_origin "$case_dir/project" "$case_dir/project.origin.git"
  git -C "$case_dir/project" worktree add --quiet -b pooled "$case_dir/wt"
  printf '%s\n' "$case_dir"
}

add_item() {  # <case-dir> <id>
  tasks-axi add "$2" "item for $2" --kind ship --file "$1/home/data/backlog.md" >/dev/null
}

row_state() {  # <case-dir> <id>
  tasks-axi show "$2" --file "$1/home/data/backlog.md" 2>/dev/null |
    sed -n 's/^  state: *//p' | head -1
}

run_dispatch_spawn() {  # <case-dir> <id>
  local case_dir=$1 id=$2
  mkdir -p "$case_dir/user-home"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir/home" HOME="$case_dir/user-home" \
    FM_STATE_OVERRIDE="$case_dir/home/state" FM_DATA_OVERRIDE="$case_dir/home/data" \
    FM_CONFIG_OVERRIDE="$case_dir/home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$case_dir/wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' \
    PATH="$case_dir/fakebin:$PATH" \
    "$SPAWN" "$id" "$case_dir/project" --mode no-mistakes --yolo off 2>&1
}

run_dispatch_batch() {  # <case-dir> <id> <id>
  local case_dir=$1 id_a=$2 id_b=$3
  mkdir -p "$case_dir/user-home"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir/home" HOME="$case_dir/user-home" \
    FM_STATE_OVERRIDE="$case_dir/home/state" FM_DATA_OVERRIDE="$case_dir/home/data" \
    FM_CONFIG_OVERRIDE="$case_dir/home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$case_dir/wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' \
    PATH="$case_dir/fakebin:$PATH" \
    "$SPAWN" "$id_a=$case_dir/project" "$id_b=$case_dir/project" --mode no-mistakes --yolo off 2>&1
}

# The end-to-end guarantee: two live tasks reach the default cap, a third fresh
# dispatch declines with the distinct at-cap code and leaves its backlog item
# queued, and freeing a slot lets that same item dispatch for real.
test_dispatch_at_cap_stays_queued_and_a_freed_slot_dispatches() {
  local case_dir home out rc
  case_dir=$(make_dispatch_home at-cap-dispatch cap-a cap-b cap-c)
  home="$case_dir/home"
  add_item "$case_dir" cap-a
  add_item "$case_dir" cap-b
  add_item "$case_dir" cap-c

  out=$(run_dispatch_spawn "$case_dir" cap-a) || fail "first dispatch should succeed: $out"
  out=$(run_dispatch_spawn "$case_dir" cap-b) || fail "second dispatch should succeed: $out"
  assert_equals in_flight "$(row_state "$case_dir" cap-a)" "first item should be In flight"
  assert_equals in_flight "$(row_state "$case_dir" cap-b)" "second item should be In flight"

  rc=0
  out=$(run_dispatch_spawn "$case_dir" cap-c) || rc=$?
  expect_code 10 "$rc" "a third fresh dispatch should exit with the at-cap code"
  assert_contains "$out" "at cap" "the at-cap refusal did not say it is at cap"
  assert_equals queued "$(row_state "$case_dir" cap-c)" "an at-cap item must stay queued"
  assert_absent "$home/state/cap-c.meta" "an at-cap dispatch must not publish a task record"

  # A finished worker releases its record, which is what frees the slot.
  rm -f "$home/state/cap-a.meta"
  out=$(run_dispatch_spawn "$case_dir" cap-c) || fail "the freed-slot dispatch should succeed: $out"
  assert_equals in_flight "$(row_state "$case_dir" cap-c)" "the queued item should dispatch once a slot frees"
  pass "an at-cap dispatch stays queued and dispatches after a slot frees"
}

# A batch is a dispatch surface too, so an over-cap pair must read as held rather
# than failed and must keep its row queued.
test_batch_held_at_cap_is_not_reported_as_failure() {
  local case_dir home out rc
  case_dir=$(make_dispatch_home batch-at-cap batch-a batch-b)
  home="$case_dir/home"
  printf '1\n' > "$home/config/max-concurrent-workers"
  add_item "$case_dir" batch-a
  add_item "$case_dir" batch-b

  rc=0
  out=$(run_dispatch_batch "$case_dir" batch-a batch-b) || rc=$?
  expect_code 10 "$rc" "a batch whose later pair is at cap should exit at-cap"
  assert_contains "$out" "batch: HELD at cap batch-b" "the over-cap pair was not reported as held"
  assert_not_contains "$out" "FAILED to spawn batch-b" "an at-cap pair must not be reported as a failure"
  assert_equals queued "$(row_state "$case_dir" batch-b)" "an at-cap batch pair must stay queued"
  assert_absent "$home/state/batch-b.meta" "an at-cap batch pair must not publish a task record"
  pass "a batch reports an over-cap pair as held, not failed, and keeps it queued"
}

test_absent_config_resolves_the_default_cap_of_two
test_config_value_overrides_the_default
test_invalid_config_is_refused_not_defaulted
test_live_counts_only_ordinary_tasks
test_check_declines_at_cap_and_admits_after_a_slot_frees
if command -v tasks-axi >/dev/null 2>&1; then
  test_dispatch_at_cap_stays_queued_and_a_freed_slot_dispatches
  test_batch_held_at_cap_is_not_reported_as_failure
else
  printf 'ok - skipped (tasks-axi is not installed; the dispatch-path case needs a real backlog)\n'
fi
