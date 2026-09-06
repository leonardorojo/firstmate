#!/usr/bin/env bash
# Deterministic contract tests for native-Windows Bash-script invocation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-script-launcher)
cleanup() {
  fm_test_cleanup
}
trap cleanup EXIT

node_available() {
  command -v node >/dev/null 2>&1 || {
    echo "skip: node not found for script launcher tests"
    exit 0
  }
}

test_platform_mapping() {
  node --input-type=module <<'JS'
import { scriptInvocation } from "./.pi/extensions/lib/fm-script-launcher.mjs";

const assert = (condition, message) => {
  if (!condition) throw new Error(message);
};
const script = "C:/Firstmate folder/bin/fm-check.sh";
const args = ["--command", "printf 'quoted; $HOME' && echo \"space\""];
const posix = scriptInvocation(script, args, "linux");
assert(posix.command === script, `POSIX command changed: ${posix.command}`);
assert(JSON.stringify(posix.args) === JSON.stringify(args), "POSIX argv changed");
const windows = scriptInvocation(script, args, "win32");
assert(windows.command === "bash", `Windows command was not bash: ${windows.command}`);
assert(JSON.stringify(windows.args) === JSON.stringify([script, ...args]), "Windows argv boundaries changed");
JS
  pass "script launcher maps POSIX scripts directly and Windows scripts to bash with separate argv"
}

test_argument_and_option_boundaries() {
  local script cwd output status=0
  script="$TMP_ROOT/argv-check.sh"
  cwd="$TMP_ROOT/working directory"
  mkdir -p "$cwd"
  cat > "$script" <<'SH'
#!/usr/bin/env bash
printf 'cwd=<%s>\n' "$PWD"
printf 'env=<%s>\n' "${FM_LAUNCHER_TEST_ENV:-}"
printf 'input=<'; cat; printf '>\n'
i=0
for arg in "$@"; do
  printf 'arg[%s]=<%s>\n' "$i" "$arg"
  i=$((i + 1))
done
SH
  chmod +x "$script"
  output=$(node --input-type=module <<'JS'
import { spawnScript, spawnScriptSync } from "./.pi/extensions/lib/fm-script-launcher.mjs";

const script = process.env.FM_LAUNCHER_SCRIPT;
const cwd = process.env.FM_LAUNCHER_CWD;
const args = [
  "plain",
  "two words",
  "a\"quoted\" value",
  "semi; dollar$HOME && pipe|",
  "--command",
  "printf 'quoted; $HOME' && echo \"spaces and symbols\"",
];
const child = spawnScript(script, args, {
  cwd,
  env: { ...process.env, FM_LAUNCHER_TEST_ENV: "preserved env value" },
  stdio: ["pipe", "pipe", "pipe"],
  detached: false,
});
let stdout = "";
let stderr = "";
child.stdout.setEncoding("utf8");
child.stderr.setEncoding("utf8");
child.stdout.on("data", (chunk) => { stdout += chunk; });
child.stderr.on("data", (chunk) => { stderr += chunk; });
child.stdin.end("stdin with spaces; $HOME\n");
const code = await new Promise((resolve, reject) => {
  child.on("error", reject);
  child.on("close", resolve);
});
if (code !== 0) throw new Error(`launcher child exited ${code}: ${stderr}`);
if (!/^cwd=<.*[\\/]working directory>\n/.test(stdout)) {
  throw new Error(`cwd option was not preserved: ${JSON.stringify(stdout)}`);
}
const expected = [
  "env=<preserved env value>",
  "input=<stdin with spaces; $HOME\n>",
  "arg[0]=<plain>",
  "arg[1]=<two words>",
  "arg[2]=<a\"quoted\" value>",
  "arg[3]=<semi; dollar$HOME && pipe|>",
  "arg[4]=<--command>",
  "arg[5]=<printf 'quoted; $HOME' && echo \"spaces and symbols\">",
];
for (const line of expected) {
  if (!stdout.includes(line)) throw new Error(`missing preserved output ${JSON.stringify(line)} in ${JSON.stringify(stdout)}`);
}
const sync = spawnScriptSync(script, args, {
  cwd,
  env: { ...process.env, FM_LAUNCHER_TEST_ENV: "preserved sync env" },
  encoding: "utf8",
  input: "sync input",
});
if (sync.status !== 0 || !sync.stdout.includes("arg[3]=<semi; dollar$HOME && pipe|>")) {
  throw new Error(`spawnScriptSync did not preserve argv: ${JSON.stringify(sync)}`);
}
JS
  ) || status=$?
  expect_code 0 "$status" "script launcher option and argv boundary execution"
  [ -z "$output" ] || fail "script launcher emitted unexpected output: $output"
  pass "script launcher preserves cwd, env, stdio, input, detached, and special argv content"
}

node_available
export FM_LAUNCHER_SCRIPT="$TMP_ROOT/argv-check.sh"
export FM_LAUNCHER_CWD="$TMP_ROOT/working directory"
test_platform_mapping
test_argument_and_option_boundaries
