#!/usr/bin/env bash
# Regression test for the fm-spawn.sh treehouse-get worktree-detection settle
# loop (bin/fm-spawn.sh, the `for _ in $(seq 1 60)` loop after `treehouse get`).
#
# On some tmux/WSL setups a brand-new window's pane_current_path transiently
# reports a stale, unrelated-but-real path on the very first poll, before the
# pane actually settles into the worktree treehouse get moved it to. That stale
# path still passes the loop's "differs from the project" check and
# validate_spawn_worktree's "is a real, distinct worktree" check (it IS a real
# git checkout, just the wrong one), so a naive single-read loop silently
# records the wrong worktree= in state/<id>.meta. This test simulates that
# transient-then-settled pane_current_path sequence with a fake tmux and
# asserts the recorded worktree resolves to the real, settled worktree, never
# the stale first read.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)

# make_settle_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query returns FM_FAKE_PANE_STALE for the first FM_FAKE_PANE_STALE_READS
# calls, then FM_FAKE_PANE_PATH forever after - reproducing a pane that
# transiently reports a stale cwd before settling into the real worktree.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse codex
  printf '%s\n' "$fakebin"
}

# make_windows_herdr_fakebin <dir> builds a small Herdr protocol fixture for
# the native-Windows fallback tests. The pane's structured cwd stays empty,
# while the fake shell emits the requested Git root only after the sentinel
# query is submitted. This is protocol/parser coverage only; the separate real
# cmd.exe regression below is the shell-syntax coverage.
make_windows_herdr_fakebin() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
capture=${FM_FAKE_HERDR_CAPTURE:?}
root=${FM_FAKE_HERDR_QUERY_ROOT:?}
printf '%s\n' "$*" >> "${FM_FAKE_HERDR_LOG:?}"
case "${1:-} ${2:-}" in
  "status --json")
    printf '%s\n' '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}'
    ;;
  "workspace list")
    printf '%s\n' '{"result":{"workspaces":[]}}'
    ;;
  "workspace create")
    printf '%s\n' '{"result":{"workspace":{"workspace_id":"w1"},"tab":{"tab_id":"w1:t1"},"root_pane":{"pane_id":"w1:p1"}}}'
    ;;
  "tab list")
    printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","label":"1","workspace_id":"w1","pane_id":"w1:p1"},{"tab_id":"w1:t2","label":"fm-test","workspace_id":"w1","pane_id":"w1:p2"}]}}'
    ;;
  "tab create")
    printf '%s\n' '{"result":{"tab":{"tab_id":"w1:t2"},"root_pane":{"pane_id":"w1:p2"}}}'
    ;;
  "pane list")
    printf '%s\n' '{"result":{"panes":[{"pane_id":"w1:p1","tab_id":"w1:t1"},{"pane_id":"w1:p2","tab_id":"w1:t2"}]}}'
    ;;
  "agent get")
    printf '%s\n' '{"error":{"code":"agent_not_found"}}'
    ;;
  "pane get")
    printf '%s\n' '{"result":{"pane":{"cwd":"C:\\primary","foreground_cwd":""}}}'
    ;;
  "pane run")
    command_text=${*:3}
    if [[ "$command_text" == *'cmd.exe /d /s /c'* ]] \
       && [[ "$command_text" == *'git rev-parse --show-toplevel'* ]]; then
      marker=$(printf '%s' "$command_text" | grep -oE 'FM_GIT_TOPLEVEL_[A-Za-z0-9_]+' | head -1 || true)
      case "${FM_FAKE_HERDR_QUERY_MODE:-valid}" in
        valid) printf '\n%s_BEGIN\n%s\n%s_END\n' "$marker" "$root" "$marker" >> "$capture" ;;
        primary) : > "$capture"; printf '\n%s_BEGIN\n%s\n%s_END\n' "$marker" "$FM_FAKE_HERDR_PRIMARY" "$marker" >> "$capture" ;;
        wrong-repo) : > "$capture"; printf '\n%s_BEGIN\n%s\n%s_END\n' "$marker" "$root" "$marker" >> "$capture" ;;
        malformed) : > "$capture"; printf '\n%s_BEGIN\n%s\nextra\n%s_END\n' "$marker" "$root" "$marker" >> "$capture" ;;
        missing) : > "$capture"; printf '%s\n' 'prompt only' >> "$capture" ;;
      esac
    fi
    ;;
  "pane read")
    cat "$capture"
    ;;
  *) : ;;
esac
exit 0
SH
  cat > "$fakebin/cygpath" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  -w) printf '%s\n' 'C:\\Treehouse.exe' ;;
  -u) printf '%s\n' "${FM_FAKE_HERDR_QUERY_ROOT:?}" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/herdr" "$fakebin/cygpath"
  fm_fake_exit0 "$fakebin" treehouse
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/sleep"
  printf '%s\n' "$fakebin"
}

# make_settle_case <name> <id> <stale_reads> builds a home, a primary project
# with a real worktree (the eventual settled path), and a separate real git
# repo standing in for the stale path (a real checkout of something else
# entirely, distinct from both the project and the worktree - mirroring the
# live incident where the stale read was another real firstmate home).
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home proj wt stale fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  stale="$case_dir/stale-other-checkout"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_git_init_commit "$stale"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise settled-worktree detection for $id.

## Firstmate spec
Record only the pane's stable worktree.
EOF
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads"
}

make_windows_herdr_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_windows_herdr_fakebin "$case_dir")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'herdr\n' > "$home/config/backend"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'off\n' > "$home/config/herdr-presentation-spaces"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise the native Windows Herdr worktree-root fallback for $id.

## Firstmate spec
The structured pane cwd is stale; accept only the sentinel-delimited Git root.
EOF
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_settle_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
}

read_windows_herdr_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_settle_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

run_windows_herdr_spawn() {
  local id=$1 mode=${2:-valid} query_root=${3:-$WT_DIR}
  FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 OSTYPE=msys HERDR_ENV= \
    FM_FAKE_HERDR_CAPTURE="$HOME_DIR/herdr-capture" FM_FAKE_HERDR_LOG="$HOME_DIR/herdr.log" \
    FM_FAKE_HERDR_QUERY_ROOT="$query_root" FM_FAKE_HERDR_PRIMARY="$PROJ_DIR" \
    FM_FAKE_HERDR_QUERY_MODE="$mode" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off --harness 'sh -c true' 2>&1
}

# A single stale first read (the exact incident) must not be accepted: the
# loop should keep polling until two consecutive reads agree, landing on the
# real settled worktree instead.
test_single_stale_first_read_is_not_accepted() {
  local rec id out status
  id=settle-single-stale-z1
  rec=$(make_settle_case settle-single "$id" 1)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane settles"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the transient stale path as the worktree"
  pass "a single transient stale pane_current_path read is not accepted as the worktree"
}

# A pane that reports the real worktree from the very first read still only
# costs the loop's existing one-second inter-poll sleep to confirm - not an
# extra full cycle on top of that.
test_already_settled_pane_costs_one_confirm_sleep() {
  local rec id out status pane_reads expected_reads
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  pane_reads=$(cat "$COUNTFILE")
  expected_reads=2
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  [ "$pane_reads" -eq "$expected_reads" ] || fail "already-settled pane used $pane_reads pane reads; expected $expected_reads (initial read plus one confirmation)"
  pass "an already-settled pane confirms via the existing inter-poll sleep, not an extra full cycle"
}

test_windows_herdr_stale_structured_cwd_uses_git_root() {
  local rec id out status
  id=herdr-windows-git-root-z3
  rec=$(make_windows_herdr_case herdr-windows-git-root "$id")
  read_windows_herdr_record "$rec"
  : > "$HOME_DIR/herdr-capture"
  out=$(run_windows_herdr_spawn "$id" valid "$WT_DIR")
  status=$?
  expect_code 0 "$status" "Windows Herdr fallback should settle on the shell's Git root"
  assert_contains "$out" "spawned $id" "spawn did not report success after the authoritative Git-root query"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "spawn did not record the queried worktree"
  pass "native-Windows Herdr fallback ignores stale structured cwd and accepts the sentinel Git root"
}

test_windows_herdr_fallback_refuses_primary_and_unproved_roots() {
  local mode rec id out status wrong
  for mode in primary malformed missing; do
    id="herdr-windows-$mode-z4"
    rec=$(make_windows_herdr_case "herdr-windows-$mode" "$id")
    read_windows_herdr_record "$rec"
    : > "$HOME_DIR/herdr-capture"
    out=$(run_windows_herdr_spawn "$id" "$mode" "$WT_DIR")
    status=$?
    [ "$status" -ne 0 ] || fail "$mode query must not let spawn succeed"
    [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "$mode query must not publish worker metadata"
  done
  pass "native-Windows Herdr fallback refuses primary, malformed, and missing Git-root evidence"

  id=herdr-windows-wrong-repo-z5
  rec=$(make_windows_herdr_case herdr-windows-wrong-repo "$id")
  read_windows_herdr_record "$rec"
  wrong="$HOME_DIR/wrong-repo"
  fm_git_init_commit "$wrong"
  : > "$HOME_DIR/herdr-capture"
  out=$(run_windows_herdr_spawn "$id" wrong-repo "$wrong")
  status=$?
  [ "$status" -ne 0 ] || fail "a non-worktree root must not be accepted"
  assert_contains "$out" "isolated worktree" "wrong-repo refusal did not come from the existing worktree safety validation"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "wrong-repo query must not publish worker metadata"
  pass "native-Windows Herdr fallback preserves the existing primary/repository/worktree safety refusals"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_sleep
test_windows_herdr_stale_structured_cwd_uses_git_root
test_windows_herdr_fallback_refuses_primary_and_unproved_roots

echo "# all fm-spawn-worktree-settle tests passed"
