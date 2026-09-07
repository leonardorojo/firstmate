#!/usr/bin/env bash
# Focused regression for the native-Windows Herdr Bash launch boundary.
# The POSIX launch payload is materialized into a task-local .sh file and the
# text sent to cmd.exe carries only bash.exe plus that script, never the
# payload (a payload embedded after `bash -c` is re-parsed and corrupted by
# cmd.exe; live evidence from the native-Windows smoke series).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-treehouse-lib.sh
. "$ROOT/bin/fm-treehouse-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-windows-herdr-launch)
FAKEBIN="$TMP_ROOT/fakebin"
HOME_DIR="$TMP_ROOT/home with spaces"
STATE_DIR="$HOME_DIR/state with spaces"
LAUNCH_DIR="$HOME_DIR/launch dir with spaces"
BRIEF="$HOME_DIR/brief with spaces.md"
PI_DIR="$HOME_DIR/fake pi with spaces"
AUX_SCRIPT="$HOME_DIR/auxiliary script with spaces.sh"
DEGRADED_BIN="$TMP_ROOT/degraded-bin"
mkdir -p "$FAKEBIN" "$STATE_DIR" "$PI_DIR" "$LAUNCH_DIR" "$DEGRADED_BIN"
UNIXBIN="$TMP_ROOT/unixbin"
mkdir -p "$UNIXBIN"
cat > "$UNIXBIN/uname" <<'SH'
#!/usr/bin/bash
printf '%s\n' Linux
SH
chmod +x "$UNIXBIN/uname"
printf '%s\n' 'full brief: spaces, quotes " and ampersands & pipes | parens (x)' > "$BRIEF"

cat > "$FAKEBIN/cygpath" <<'SH'
#!/usr/bin/bash
set -u
case "${1:-}" in
  -w)
    case "${3:-}" in
      *bash*) printf '%s\n' 'C:\Program Files\Fake Bash\bash.exe' ;;
      *)      printf '%s\n' 'C:\Program Files\Fake Home\launch.sh' ;;
    esac
    ;;
  -u) printf '%s\n' "${FM_FAKE_SCRIPT_MSYS:?}" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/cygpath"
cat > "$FAKEBIN/cmd.exe" <<'SH'
#!/usr/bin/bash
set -u
line=${1:-}
printf '%s' "$line" > "${FM_FAKE_CMD_LOG:?}"
case "$line" in
  cmd.exe\ /d\ /v:off\ /s\ /c\ *) ;;
  *) exit 92 ;;
esac
rest=${line#*cmd.exe /d /v:off /s /c }
# cmd /s semantics: strip the first and last quote character, leaving the two
# quoted argv items the command parser then runs.
rest=${rest#\"}
rest=${rest%\"}
bash_win=$(printf '%s' "$rest" | sed -n 's/^"\([^"]*\)" "\([^"]*\)"$/\1/p')
script_win=$(printf '%s' "$rest" | sed -n 's/^"\([^"]*\)" "\([^"]*\)"$/\2/p')
[ -n "$bash_win" ] && [ -n "$script_win" ] || exit 93
script_msys=$(cygpath -u "$script_win") || exit 94
PATH="${FM_FAKE_DEGRADED_PATH:?}" exec /usr/bin/bash "$script_msys"
SH
chmod +x "$FAKEBIN/cmd.exe"
cat > "$PI_DIR/pi" <<'SH'
#!/usr/bin/bash
set -u
printf 'FM_PI_HARNESS=%s\n' "${FM_PI_HARNESS-}" > "${FM_FAKE_PI_ENV:?}"
: > "${FM_FAKE_PI_ARGS:?}"
for arg in "$@"; do printf '%s\n' "$arg" >> "$FM_FAKE_PI_ARGS"; done
count=0
[ -f "$FM_FAKE_PI_COUNT" ] && count=$(cat "$FM_FAKE_PI_COUNT")
printf '%s\n' "$((count + 1))" > "$FM_FAKE_PI_COUNT"
SH
chmod +x "$PI_DIR/pi"
cat > "$AUX_SCRIPT" <<'SH'
#!/usr/bin/env bash
set -u
command -v env > "${FM_FAKE_ENV_PATH:?}"
printf '%s\n' auxiliary-ok > "${FM_FAKE_AUX_MARKER:?}"
SH
chmod +x "$AUX_SCRIPT"

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\''/g"
  printf "'"
}

HOST_PATH="$PATH"
export PATH="$FAKEBIN:$PATH"
export BACKEND=herdr OSTYPE=msys FM_FAKE_CMD_LOG="$TMP_ROOT/cmd.log"
export FM_FAKE_PI_ENV="$TMP_ROOT/pi.env" FM_FAKE_PI_ARGS="$TMP_ROOT/pi.args"
export FM_FAKE_PI_COUNT="$TMP_ROOT/pi.count"
export FM_FAKE_DEGRADED_PATH="$DEGRADED_BIN"
export FM_FAKE_ENV_PATH="$TMP_ROOT/env.path" FM_FAKE_AUX_MARKER="$TMP_ROOT/aux.marker"

# The script-boundary wrapper stays native-Windows-Herdr only. tmux and
# Unix/macOS Herdr keep the historical direct-text launch path.
if BACKEND=tmux spawn_windows_herdr_native_capable; then
  fail "tmux was wrongly recognized as the native-Windows Herdr path"
fi
if PATH="$UNIXBIN:$PATH" BACKEND=herdr OSTYPE=linux spawn_windows_herdr_native_capable; then
  fail "a non-Windows Herdr shell was wrongly recognized as the native path"
fi
pass "the script-boundary wrapper stays native-Windows-Herdr only"

spawn_windows_herdr_native_capable \
  || fail "MSYS Herdr was not recognized as the native-Windows guarded path"
BASH_NATIVE=$(spawn_windows_herdr_resolve_bash) \
  || fail "native bash.exe could not be resolved"
[ "$BASH_NATIVE" = 'C:\Program Files\Fake Bash\bash.exe' ] \
  || fail "bash resolution did not cross the Windows executable boundary"

BRIEF_PAYLOAD=$(cat "$BRIEF")
PI_PAYLOAD="$(shell_quote "$AUX_SCRIPT"); GOTMPDIR=$(shell_quote "$STATE_DIR/gotmp") TRACEPARENT='00-0123456789abcdef0123456789abcdef-0123456789abcdef-01' env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI FM_PI_HARNESS=pi $(shell_quote "$PI_DIR/pi") --model test -e $(shell_quote "$STATE_DIR/pi-ext.ts") $(shell_quote "$BRIEF_PAYLOAD")"
LAUNCH_SCRIPT="$LAUNCH_DIR/launch.sh"
export FM_FAKE_SCRIPT_MSYS="$LAUNCH_SCRIPT"
WRAPPED=$(spawn_windows_herdr_wrap_launch "$BASH_NATIVE" "$LAUNCH_SCRIPT" "$PI_PAYLOAD") \
  || fail "native Herdr launch wrapper refused a valid payload"

[ "$WRAPPED" = 'cmd.exe /d /v:off /s /c ""C:\Program Files\Fake Bash\bash.exe" "C:\Program Files\Fake Home\launch.sh""' ] \
  || fail "wrapper did not send only the two quoted Windows paths"
[ "$(sed -n '1p' "$LAUNCH_SCRIPT")" = '#!/usr/bin/env bash' ] \
  || fail "launch script is missing its bash shebang"
[ "$(sed -n '2p' "$LAUNCH_SCRIPT")" = 'export PATH="/usr/local/bin:/usr/bin:/bin:${PATH:-}"' ] \
  || fail "launch script is missing the POSIX PATH bootstrap"
[ "$(sed -n '3p' "$LAUNCH_SCRIPT")" = "$PI_PAYLOAD" ] \
  || fail "launch script does not carry the exact POSIX payload after bootstrap"
[ "$(wc -l < "$LAUNCH_SCRIPT")" = 3 ] \
  || fail "launch script carried unexpected extra content"
pass "launch payload was materialized byte-for-byte into a task-local .sh file"

if PATH="$DEGRADED_BIN" /usr/bin/bash -c 'command -v env >/dev/null 2>&1'; then
  fail "env was resolvable before the launch-script PATH bootstrap"
fi
pass "degraded Bash PATH cannot resolve env before bootstrap"
FM_FAKE_CMD_LOG="$TMP_ROOT/cmd.log" bash -c 'cmd.exe "$1"' _ "$WRAPPED" \
  || fail "fake cmd.exe rejected the script-boundary wrapper"
[ -f "$TMP_ROOT/env.path" ] && [ -s "$TMP_ROOT/env.path" ] \
  || fail "env was not resolvable after the launch-script PATH bootstrap"
[ "$(cat "$TMP_ROOT/aux.marker")" = auxiliary-ok ] \
  || fail "an auxiliary #!/usr/bin/env bash script did not run after bootstrap"
[ "$(cat "$TMP_ROOT/pi.count")" = 1 ] \
  || fail "Pi launch did not occur exactly once"
grep -Fx 'FM_PI_HARNESS=pi' "$TMP_ROOT/pi.env" >/dev/null \
  || fail "FM_PI_HARNESS was not preserved"
grep -Fx -- '-e' "$TMP_ROOT/pi.args" >/dev/null \
  || fail "Pi extension argument was not preserved"
grep -Fx -- "$STATE_DIR/pi-ext.ts" "$TMP_ROOT/pi.args" >/dev/null \
  || fail "Pi extension path was not preserved"
grep -Fx -- "$BRIEF_PAYLOAD" "$TMP_ROOT/pi.args" >/dev/null \
  || fail "full spaced-path metacharacter brief payload was not preserved byte-for-byte"
assert_contains "$(cat "$TMP_ROOT/cmd.log")" 'C:\Program Files\Fake Bash\bash.exe' \
  "cmd.exe did not receive the native spaced Bash path"
assert_contains "$(cat "$TMP_ROOT/cmd.log")" 'C:\Program Files\Fake Home\launch.sh' \
  "cmd.exe did not receive the native spaced launch-script path"
assert_not_contains "$(cat "$TMP_ROOT/cmd.log")" "$BRIEF_PAYLOAD" \
  "the brief payload leaked onto the cmd.exe command line"
assert_not_contains "$(cat "$TMP_ROOT/cmd.log")" 'export GOTMPDIR=' \
  "a standalone GOTMPDIR export reached cmd.exe"
assert_not_contains "$(cat "$TMP_ROOT/cmd.log")" 'export TRACEPARENT=' \
  "a standalone TRACEPARENT export reached cmd.exe"
assert_not_contains "$(cat "$TMP_ROOT/cmd.log")" 'env -u CURSOR_AGENT' \
  "the raw env launch text reached the cmd.exe command line"
assert_not_contains "$(cat "$TMP_ROOT/cmd.log")" 'bash -c' \
  "the wrapper still routed the payload through bash -c"
assert_not_contains "$(cat "$TMP_ROOT/cmd.log")" "$PI_DIR/pi" \
  "the Pi executable path leaked onto the cmd.exe command line"
assert_not_contains "$(cat "$TMP_ROOT/cmd.log")" 'export PATH=' \
  "the launch-script PATH bootstrap leaked onto the cmd.exe command line"
pass "fake cmd.exe receives only the two paths and Pi argv and brief survive exactly"

REAL_CMD=$(PATH="$HOST_PATH" type -P -- cmd.exe 2>/dev/null || true)
REAL_BASH_BIN=$(PATH="$HOST_PATH" type -P -- bash.exe 2>/dev/null || true)
if [ -n "$REAL_CMD" ] && [ -n "$REAL_BASH_BIN" ] \
   && command -v cygpath >/dev/null 2>&1; then
  REAL_DIR="$TMP_ROOT/real cmd marker"
  mkdir -p "$REAL_DIR"
  REAL_MARKER="$REAL_DIR/reached marker.txt"
  REAL_ENV_PATH="$REAL_DIR/env path.txt"
  REAL_AUX="$REAL_DIR/real auxiliary.sh"
  REAL_SCRIPT="$REAL_DIR/launch.sh"
  cat > "$REAL_AUX" <<'SH'
#!/usr/bin/env bash
printf '%s\n' auxiliary-ok > "${FM_REAL_AUX_MARKER:?}"
SH
  chmod +x "$REAL_AUX"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'export PATH="/usr/local/bin:/usr/bin:/bin:${PATH:-}"' \
    "command -v env > $(shell_quote "$REAL_ENV_PATH")" \
    "$(shell_quote "$REAL_AUX")" \
    "touch $(shell_quote "$REAL_MARKER")" > "$REAL_SCRIPT"
  chmod +x "$REAL_SCRIPT"
  REAL_BASH=$(cygpath -w -- "$REAL_BASH_BIN")
  REAL_SCRIPT_WIN=$(cygpath -w -- "$REAL_SCRIPT")
  export FM_REAL_AUX_MARKER="$REAL_DIR/real auxiliary marker"
  if PATH="$DEGRADED_BIN" "$REAL_CMD" /d /v:off /s /c "\"$REAL_BASH\" \"$REAL_SCRIPT_WIN\"" \
    >/dev/null 2>&1 && [ -f "$REAL_MARKER" ] \
    && [ -s "$REAL_ENV_PATH" ] \
    && [ "$(cat "$FM_REAL_AUX_MARKER")" = auxiliary-ok ]; then
    pass "real cmd.exe reaches native Bash and bootstrap resolves env plus env-shebang"
  else
    pass "real cmd.exe marker regression skipped because this MSYS shell cannot safely submit the native command line"
  fi
else
  pass "real cmd.exe regression skipped because native tools are unavailable"
fi

echo "# all native-Windows Herdr launch tests passed"
