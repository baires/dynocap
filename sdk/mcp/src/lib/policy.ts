import type { Sandbox } from "@microvm/sdk";

export const EXEC_TIMEOUT_SECONDS = 30;
export const OUTPUT_CAP_BYTES = 64 * 1024;
/** Fixed size for `terminal: true`; MCP has no window to follow. */
export const MCP_TERMINAL = { rows: 24, cols: 80 } as const;

const TRUNCATED = "\n… output truncated\n";

export async function presentExec(
  sandbox: Sandbox,
  command: string,
  options: {
    requireOffline?: boolean;
    permitFiltered?: boolean;
    cwd?: string;
    env?: Record<string, string>;
    timeoutSeconds?: number;
    terminal?: boolean;
  }
): Promise<string> {
  const result = await sandbox.exec(command, {
    ...(options.terminal ? { terminal: MCP_TERMINAL } : {}),
    requireOffline: options.requireOffline,
    ...(options.permitFiltered === undefined
      ? {}
      : { permitFiltered: options.permitFiltered }),
    cwd: options.cwd,
    env: options.env,
    timeoutSeconds: options.timeoutSeconds ?? EXEC_TIMEOUT_SECONDS,
  });
  // A terminal has one combined transcript; there is no stderr to label.
  if (options.terminal)
    return cap(`exit ${result.exitCode}\nterminal:\n${result.stdout}`);
  let text = `exit ${result.exitCode}\n${result.stdout}`;
  if (result.stderr.length > 0) text += `\nstderr:\n${result.stderr}`;
  return cap(text);
}

export function cap(text: string): string {
  const bytes = Buffer.from(text);
  if (bytes.length <= OUTPUT_CAP_BYTES) return text;
  let keep = Math.max(0, OUTPUT_CAP_BYTES - Buffer.byteLength(TRUNCATED));
  while (keep > 0 && (bytes[keep]! & 0xc0) === 0x80) keep--;
  return bytes.subarray(0, keep).toString("utf8") + TRUNCATED;
}
