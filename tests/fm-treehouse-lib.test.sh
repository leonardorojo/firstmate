#!/usr/bin/env bash
# Focused tests for the spawn-time treehouse command resolver.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-treehouse-lib.sh
. "$ROOT/bin/fm-treehouse-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-treehouse-lib)
ORIGINAL_PATH=$PATH

make_treehouse() {
  local path=$1
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$path"
}

make_cygpath() {
  local bin=$1 native=$2
  cat > "$bin" <<SH
#!/usr/bin/env bash
printf '%s\\n' "$native"
SH
  chmod +x "$bin"
}

make_unix_uname() {
  local bin=$1
  cat > "$bin" <<'SH'
#!/usr/bin/env bash
printf '%s\\n' Linux
SH
  chmod +x "$bin"
}

test_herdr_windows_uses_firstmate_path() {
  local dir="$TMP_ROOT/path-mismatch" fakebin treehouse
  mkdir -p "$dir"
  fakebin="$dir/fakebin"
  treehouse="$dir/Users/lgroj/bin/treehouse"
  mkdir -p "$fakebin"
  make_treehouse "$treehouse"
  ln -s "$treehouse" "$fakebin/treehouse"
  make_cygpath "$fakebin/cygpath" 'C:\Users\lgroj\bin\treehouse'

  PATH="$fakebin:$ORIGINAL_PATH" OSTYPE=msys \
    fm_treehouse_resolve_command herdr
  [ "$FM_TREEHOUSE_EXECUTABLE" = 'C:\Users\lgroj\bin\treehouse' ] \
    || fail "MSYS Herdr did not carry the resolved executable into native form"
  [ "$FM_TREEHOUSE_GET_COMMAND" = "& 'C:\\Users\\lgroj\\bin\\treehouse' get" ] \
    || fail "MSYS Herdr did not send the resolved native executable"
  pass "Herdr uses the Firstmate treehouse path even when the pane PATH differs"
}

test_herdr_windows_quotes_spaces_and_apostrophes() {
  local dir="$TMP_ROOT/quoted" fakebin treehouse
  fakebin="$dir/fakebin"
  treehouse="$dir/Users/O'Brien/bin/Tree House/treehouse"
  mkdir -p "$fakebin"
  make_treehouse "$treehouse"
  ln -s "$treehouse" "$fakebin/treehouse"
  make_cygpath "$fakebin/cygpath" "C:\\Users\\O'Brien\\Tree House\\treehouse"

  PATH="$fakebin:$ORIGINAL_PATH" OSTYPE=mingw64 \
    fm_treehouse_resolve_command herdr
  [ "$FM_TREEHOUSE_GET_COMMAND" = "& 'C:\\Users\\O''Brien\\Tree House\\treehouse' get" ] \
    || fail "PowerShell quoting did not protect spaces and apostrophes"
  pass "Herdr PowerShell command quotes spaces and apostrophes safely"
}

test_missing_and_invalid_treehouse_refuse() {
  local dir="$TMP_ROOT/refuse" fakebin out status
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"

  out=$(PATH="$fakebin" OSTYPE=linux fm_treehouse_resolve_command tmux 2>&1)
  status=$?
  expect_code 1 "$status" "missing treehouse should refuse"
  assert_contains "$out" "treehouse is missing" "missing treehouse refusal was not explained"

  mkdir -p "$fakebin/treehouse"
  out=$(PATH="$fakebin" OSTYPE=linux fm_treehouse_resolve_command tmux 2>&1)
  status=$?
  expect_code 1 "$status" "invalid treehouse should refuse"
  assert_contains "$out" "treehouse is missing" "invalid treehouse refusal was not explained"
  pass "missing and invalid Treehouse executables refuse safely"
}

test_windows_conversion_requires_cygpath() {
  local dir="$TMP_ROOT/no-cygpath" fakebin treehouse out status
  fakebin="$dir/fakebin"
  treehouse="$dir/treehouse"
  mkdir -p "$fakebin"
  make_treehouse "$treehouse"
  ln -s "$treehouse" "$fakebin/treehouse"

  out=$(PATH="$fakebin" OSTYPE=msys fm_treehouse_resolve_command herdr 2>&1)
  status=$?
  expect_code 1 "$status" "MSYS conversion without cygpath should refuse"
  assert_contains "$out" "requires cygpath" "missing cygpath refusal was not explained"
  pass "MSYS Herdr refuses when POSIX-to-Windows conversion is unavailable"
}

test_unix_and_tmux_keep_bare_command() {
  local dir="$TMP_ROOT/unchanged" fakebin treehouse
  fakebin="$dir/fakebin"
  treehouse="$dir/treehouse"
  mkdir -p "$fakebin"
  make_treehouse "$treehouse"
  ln -s "$treehouse" "$fakebin/treehouse"
  make_unix_uname "$fakebin/uname"

  PATH="$fakebin:$ORIGINAL_PATH" OSTYPE=linux \
    fm_treehouse_resolve_command tmux
  [ "$FM_TREEHOUSE_GET_COMMAND" = 'treehouse get' ] \
    || fail "tmux behavior changed from the bare treehouse command"
  PATH="$fakebin:$ORIGINAL_PATH" OSTYPE=linux \
    fm_treehouse_resolve_command herdr
  [ "$FM_TREEHOUSE_GET_COMMAND" = 'treehouse get' ] \
    || fail "Unix Herdr behavior changed from the bare treehouse command"
  pass "Unix and tmux spawns keep the historical bare treehouse command"
}

test_herdr_windows_uses_firstmate_path
test_herdr_windows_quotes_spaces_and_apostrophes
test_missing_and_invalid_treehouse_refuse
test_windows_conversion_requires_cygpath
test_unix_and_tmux_keep_bare_command

echo "# all fm-treehouse-lib tests passed"
