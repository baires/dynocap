import type { Sandbox } from "@microvm/sdk";

export const EXEC_TIMEOUT_SECONDS = 30;
export const OUTPUT_CAP_BYTES = 64 * 1024;

const TRUNCATED = "\n… output truncated\n";

export async function presentExec(
  sandbox: Sandbox,
  command: string,
  options: {
    cwd?: string;
    env?: Record<string, string>;
    timeoutSeconds?: number;
  }
): Promise<string> {
  const result = await sandbox.exec(command, {
    cwd: options.cwd,
    env: options.env,
    timeoutSeconds: options.timeoutSeconds ?? EXEC_TIMEOUT_SECONDS,
  });
  let text = `exit ${result.exitCode}\n${result.stdout}`;
  if (result.stderr.length > 0) text += `\nstderr:\n${result.stderr}`;
  return cap(text);
}

function cap(text: string): string {
  const bytes = Buffer.from(text);
  if (bytes.length <= OUTPUT_CAP_BYTES) return text;
  const keep = Math.max(0, OUTPUT_CAP_BYTES - Buffer.byteLength(TRUNCATED));
  return bytes.subarray(0, keep).toString("utf8") + TRUNCATED;
}
