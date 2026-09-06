import type { ChildProcessWithoutNullStreams, SpawnOptions, SpawnSyncOptions, SpawnSyncReturns } from "node:child_process";

export function scriptInvocation(
  script: string,
  args?: readonly string[],
  platform?: NodeJS.Platform | string,
): { command: string; args: string[] };

export function spawnScript(
  script: string,
  args?: readonly string[],
  options?: SpawnOptions,
): ChildProcessWithoutNullStreams;

export function spawnScriptSync(
  script: string,
  args: readonly string[] | undefined,
  options: SpawnSyncOptions & { encoding: "utf8" },
): SpawnSyncReturns<string>;

export function spawnScriptSync(
  script: string,
  args?: readonly string[],
  options?: SpawnSyncOptions,
): SpawnSyncReturns<Buffer>;
