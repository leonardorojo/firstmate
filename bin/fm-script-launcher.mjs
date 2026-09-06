import { spawn, spawnSync } from "node:child_process";

/**
 * Return the executable and argv used to invoke one tracked Bash script.
 * Windows cannot execute a .sh file as a native child process, so Bash is the
 * executable there and the script path remains its first separate argument.
 */
export function scriptInvocation(script, args = [], platform = process.platform) {
  if (platform === "win32") {
    return { command: "bash", args: [script, ...args] };
  }
  return { command: script, args: [...args] };
}

/**
 * Spawn a tracked Bash script without involving a shell on either platform.
 * All caller options except shell are retained, including cwd, env, stdio,
 * detached, and an IPC stdio entry.
 */
export function spawnScript(script, args = [], options = {}) {
  const invocation = scriptInvocation(script, args);
  return spawn(invocation.command, invocation.args, { ...options, shell: false });
}

/** Synchronous counterpart to spawnScript for extension adapters. */
export function spawnScriptSync(script, args = [], options = {}) {
  const invocation = scriptInvocation(script, args);
  return spawnSync(invocation.command, invocation.args, { ...options, shell: false });
}
