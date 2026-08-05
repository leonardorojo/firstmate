#!/usr/bin/env bash
# Regression coverage for canonical task-root identity and WSL dual-path conversion.
# Portable cases prove containment and legacy metadata handling; mounted-drive cases
# run only when FM_WSL_E2E=1 is explicitly enabled by a WSL test runner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-worktree-lib.sh
. "$ROOT/bin/fm-worktree-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-worktree-path)
fm_git_identity fmtest fmtest@example.invalid

test_registered_root_is_authoritative() {
  local project="$TMP_ROOT/project" task="$TMP_ROOT/task" unrelated="$TMP_ROOT/unrelated" out
  fm_git_worktree "$project" "$task" fm/task-root
  fm_git_init_commit "$unrelated"

  fm_worktree_validate_pair "$project" "$task" \
    || fail "registered task worktree was rejected: ${FM_WORKTREE_PATH_ERROR:-unknown}"
  [ "$FM_WORKTREE_WSL" = "$(cd "$task" && pwd -P)" ] \
    || fail "task root was not canonicalized"
  [ "$FM_WORKTREE_COMMON" = "$(fm_worktree_common_dir "$project")" ] \
    || fail "task root common-dir identity was not preserved"

  if fm_worktree_validate_pair "$project" "$project"; then
    fail "primary checkout was accepted as a task root"
  fi
  out=$FM_WORKTREE_PATH_ERROR
  assert_contains "$out" "primary checkout" "primary-checkout refusal lacked a concrete reason"

  if fm_worktree_validate_pair "$project" "$unrelated"; then
    fail "unrelated repository was accepted as a task root"
  fi
  out=$FM_WORKTREE_PATH_ERROR
  assert_contains "$out" "unrelated repository" "unrelated-repository refusal lacked a concrete reason"
  pass "canonical root validation accepts only the registered worktree"
}

test_concurrent_task_roots_remain_distinct() {
  local project="$TMP_ROOT/concurrent-project" first="$TMP_ROOT/concurrent-one" second="$TMP_ROOT/concurrent-two"
  fm_git_worktree "$project" "$first" fm/concurrent-one
  git -C "$project" worktree add --quiet -b fm/concurrent-two "$second"
  fm_worktree_validate_pair "$project" "$first" || fail "first concurrent task root was rejected"
  first=$FM_WORKTREE_WSL
  first_windows=$FM_WORKTREE_WINDOWS
  fm_worktree_validate_pair "$project" "$second" || fail "second concurrent task root was rejected"
  second=$FM_WORKTREE_WSL
  second_windows=$FM_WORKTREE_WINDOWS
  [ "$first" != "$second" ] || fail "concurrent task roots collapsed to one WSL path"
  if [ -n "$first_windows" ] && [ "$first_windows" = "$second_windows" ]; then
    fail "concurrent task roots collapsed to one Windows path"
  fi
  pass "concurrent task roots retain distinct Linux and optional Windows identities"
}

test_legacy_metadata_is_canonicalized_without_windows_inference() {
  local project="$TMP_ROOT/legacy-project" task="$TMP_ROOT/legacy-task" link="$TMP_ROOT/legacy-link" meta
  fm_git_worktree "$project" "$task" fm/legacy-root
  ln -s "$task" "$link"
  meta="$TMP_ROOT/legacy.meta"
  fm_write_meta "$meta" "worktree=$link" "project=$project"

  fm_worktree_validate_meta_identity "$meta" legacy \
    || fail "legacy metadata was rejected despite a readable registered root"
  [ "$FM_WORKTREE_META_WSL" = "$(cd "$task" && pwd -P)" ] \
    || fail "legacy metadata did not canonicalize to the acquired root"
  [ -z "$(fm_worktree_meta_optional_exact "$meta" worktree_windows)" ] \
    || fail "legacy metadata inferred an unsupported Windows path"
  pass "legacy metadata remains usable without inventing a Windows representation"
}

test_teardown_preserves_records_on_root_ambiguity() {
  local project="$TMP_ROOT/teardown-project" task="$TMP_ROOT/teardown-task" home="$TMP_ROOT/teardown-home" sha rc
  fm_git_worktree "$project" "$task" fm/teardown-root
  sha=$(fm_worktree_sha "$task")
  mkdir -p "$home/state" "$home/data" "$home/config"
  fm_write_meta "$home/state/teardown.meta" \
    "window=firstmate:fm-teardown" "endpoint_task_id=teardown" \
    "worktree=$task" "project=$project" "worktree_wsl=$task" \
    "worktree_common_dir=$(fm_worktree_common_dir "$task")" \
    "spawn_head_sha=$sha" "kind=ship" "mode=local-only"
  git -C "$project" worktree remove --force "$task"
  set +e
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-teardown.sh" teardown --force >/dev/null 2>"$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "teardown accepted a missing explicitly-bound task root"
  [ -f "$home/state/teardown.meta" ] || fail "teardown removed metadata after root ambiguity"
  assert_contains "$(cat "$home/teardown.err")" "preserving the task records" \
    "teardown ambiguity did not explain durable-record preservation"
  pass "teardown preserves task records when the explicitly bound root disappears"
}

test_snapshot_separates_task_root_and_pr_head() {
  local project="$TMP_ROOT/report-project" task="$TMP_ROOT/report-task" home="$TMP_ROOT/report-home" sha out
  fm_git_worktree "$project" "$task" fm/report-root
  sha=$(fm_worktree_sha "$task")
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$home/fakebin"
  cat > "$home/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$home/fakebin/tmux"
  fm_write_meta "$home/state/report.meta" \
    "window=firstmate:fm-report" "endpoint_task_id=report" \
    "worktree=$task" "project=$project" "worktree_wsl=$task" \
    "worktree_common_dir=$(fm_worktree_common_dir "$task")" \
    "spawn_head_sha=$sha" "current_head_sha=$sha" \
    "pr=https://github.com/example/repo/pull/9" \
    "pr_head=0123456789abcdef0123456789abcdef01234567" "kind=scout"
  printf 'done: report ready\n' > "$home/state/report.status"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" PATH="$home/fakebin:$PATH" \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  [ "$(printf '%s' "$out" | jq -r '.tasks[0].task_root.wsl')" = "$(cd "$task" && pwd -P)" ] \
    || fail "snapshot did not report the canonical task root"
  [ "$(printf '%s' "$out" | jq -r '.tasks[0].task_root.spawn_head_sha')" = "$sha" ] \
    || fail "snapshot did not report the task spawn SHA"
  [ "$(printf '%s' "$out" | jq -r '.tasks[0].pr.head_sha')" = 0123456789abcdef0123456789abcdef01234567 ] \
    || fail "snapshot conflated or omitted the forge PR head SHA"
  pass "fleet snapshot reports task-root and forge SHA identities separately"
}

test_mounted_drive_round_trip() {
  local base project task
  [ "${FM_WSL_E2E:-0}" = 1 ] || {
    echo "ok - WSL mounted-drive conversion test skipped (set FM_WSL_E2E=1)"
    return 0
  }
  command -v wslpath >/dev/null 2>&1 || {
    echo "ok - WSL mounted-drive conversion test skipped (wslpath unavailable)"
    return 0
  }
  base=${FM_WSL_TEST_ROOT:-/mnt/c/Temp/firstmate-fm-worktree-path-test}
  rm -rf -- "$base"
  mkdir -p "$base"
  project="$base/project"
  task="$base/task"
  fm_git_worktree "$project" "$task" fm/wsl-root
  fm_worktree_validate_pair "$project" "$task" \
    || fail "mounted-drive task root was rejected: ${FM_WORKTREE_PATH_ERROR:-unknown}"
  [ -n "$FM_WORKTREE_WINDOWS" ] || fail "mounted-drive task root did not receive a Windows path"
  [ "$FM_WORKTREE_WINDOWS" = "$(wslpath -w "$FM_WORKTREE_WSL")" ] \
    || fail "Windows representation was not the validated acquired root"
  rm -rf -- "$base"
  pass "mounted-drive task root receives a round-trip-validated Windows representation"
}

test_registered_root_is_authoritative
test_concurrent_task_roots_remain_distinct
test_legacy_metadata_is_canonicalized_without_windows_inference
test_teardown_preserves_records_on_root_ambiguity
test_snapshot_separates_task_root_and_pr_head
test_mounted_drive_round_trip
printf '# all fm-worktree-path tests passed\n'
