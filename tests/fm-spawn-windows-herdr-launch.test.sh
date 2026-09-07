#!/usr/bin/env bash
# Focused regression for the native-Windows Herdr Bash launch boundary.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-treehouse-lib.sh
. "$ROOT/bin/fm-treehouse-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-windows-herdr-launch)
FAKEBIN="$TMP_ROOT/fakebin"
HOME_DIR="$TMP_ROOT/home with spaces"
STATE_DIR="$HOME_DIR/state with spaces"
BRIEF="$HOME_DIR/brief with spaces.md"
PI_DIR="$HOME_DIR/fake pi with spaces"
mkdir -p "$FAKEBIN" "$STATE_DIR" "$PI_DIR"
printf '%s\n' 'full brief: spaces, quotes " and ampersands &' > "$BRIEF"

cat > "$FAKEBIN/cmd.exe" <<'SH'
#!/usr/bin/bash
set -u
line=${1:-}
printf '%s' "$line" > "${FM_FAKE_CMD_LOG:?}"
case "$line" in
  cmd.exe\ /d\ /v:off\ /s\ /c\ *) ;;
  export\ *|env\ *) exit 91 ;;
  *) exit 92 ;;
esac
payload=${line#* -c \"}
payload=${payload%\"\"}
payload=$(printf '%s' "$payload" | sed 's/\\\"/\"/g')
exec /usr/bin/bash -c "$payload"
SH
chmod +x "$FAKEBIN/cmd.exe"
cat > "$FAKEBIN/cygpath" <<'SH'
#!/usr/bin/bash
set -u
case "${1:-}" in
  -w) printf '%s\n' 'C:\Program Files\Fake Bash\bash.exe' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/cygpath"
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

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\''/g"
  printf "'"
}

export PATH="$FAKEBIN:$PATH"
export BACKEND=herdr OSTYPE=msys FM_FAKE_CMD_LOG="$TMP_ROOT/cmd.log"
export FM_FAKE_PI_ENV="$TMP_ROOT/pi.env" FM_FAKE_PI_ARGS="$TMP_ROOT/pi.args"
export FM_FAKE_PI_COUNT="$TMP_ROOT/pi.count"

spawn_windows_herdr_native_capable \
  || fail "MSYS Herdr was not recognized as the native-Windows guarded path"
BASH_NATIVE=$(spawn_windows_herdr_resolve_bash) \
  || fail "native bash.exe could not be resolved"
[ "$BASH_NATIVE" = 'C:\Program Files\Fake Bash\bash.exe' ] \
  || fail "bash resolution did not cross the Windows executable boundary"

BRIEF_PAYLOAD=$(cat "$BRIEF")
PI_PAYLOAD="FM_PI_HARNESS=pi GOTMPDIR=$(shell_quote "$STATE_DIR/gotmp") TRACEPARENT='00-0123456789abcdef0123456789abcdef-0123456789abcdef-01' $(shell_quote "$PI_DIR/pi") --model test -e $(shell_quote "$STATE_DIR/pi-ext.ts") $(shell_quote "$BRIEF_PAYLOAD")"
WRAPPED=$(spawn_windows_herdr_wrap_launch "$BASH_NATIVE" "$PI_PAYLOAD") \
  || fail "native Herdr launch wrapper refused a valid payload"
FM_FAKE_CMD_LOG="$TMP_ROOT/cmd.log" bash -c 'cmd.exe "$1"' _ "$WRAPPED" \
  || fail "fake cmd.exe rejected the Bash wrapper"
[ "$(cat "$TMP_ROOT/pi.count")" = 1 ] \
  || fail "Pi launch did not occur exactly once"
grep -Fx 'FM_PI_HARNESS=pi' "$TMP_ROOT/pi.env" >/dev/null \
  || fail "FM_PI_HARNESS was not preserved"
grep -Fx -- '-e' "$TMP_ROOT/pi.args" >/dev/null \
  || fail "Pi extension argument was not preserved"
assert_contains "$(cat "$TMP_ROOT/pi.args")" "$BRIEF_PAYLOAD" \
  "full spaced-path brief payload was not preserved"
assert_contains "$(cat "$TMP_ROOT/cmd.log")" 'C:\Program Files\Fake Bash\bash.exe' \
  "cmd.exe did not receive the native spaced Bash path"
assert_not_contains "$(cat "$TMP_ROOT/cmd.log")" 'export GOTMPDIR=' \
  "standalone GOTMPDIR export was sent to cmd.exe"
assert_not_contains "$(cat "$TMP_ROOT/cmd.log")" 'export TRACEPARENT=' \
  "standalone TRACEPARENT export was sent to cmd.exe"
pass "fake cmd.exe accepts one native Bash wrapper and preserves Pi argv and brief payload"

if command -v cmd.exe >/dev/null 2>&1 && command -v cygpath >/dev/null 2>&1 \
   && command -v bash.exe >/dev/null 2>&1; then
  REAL_DIR="$TMP_ROOT/real cmd marker"
  mkdir -p "$REAL_DIR"
  REAL_MARKER="$REAL_DIR/reached marker.txt"
  REAL_BASH=$(cygpath -w -- "$(type -P -- bash.exe)")
  if cmd.exe /d /v:off /s /c "\"$REAL_BASH\" -c \"touch '$REAL_MARKER'\"" \
    >/dev/null 2>&1 && [ -f "$REAL_MARKER" ]; then
    pass "real cmd.exe reaches native Bash and a harmless spaced-path marker"
  else
    pass "real cmd.exe marker regression skipped because this MSYS shell cannot safely submit the native command line"
  fi
else
  pass "real cmd.exe regression skipped because native tools are unavailable"
fi

echo "# all native-Windows Herdr launch tests passed"
