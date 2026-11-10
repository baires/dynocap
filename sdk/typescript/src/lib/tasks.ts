import { resolve } from "node:path";
import { ControlType, encodeFrame, encodeJSON } from "./framing.ts";
import { daemonSocket } from "./paths.ts";
import { roundTrip } from "./session.ts";
import { SandboxError } from "./errors.ts";

export async function requireCapability(
  home: string,
  capability: "taskVersion" | "transferVersion" | "taskManagementVersion"
): Promise<void> {
  const result = await roundTrip(
    daemonSocket(home),
    encodeFrame(ControlType.ping, new Uint8Array())
  );
  if (
    !result ||
    typeof result !== "object" ||
    !(capability in result) ||
    Reflect.get(result, capability) !== 1
  ) {
    throw new SandboxError(
      "daemon",
      `daemon lacks ${capability} v1; rebuild and restart it`
    );
  }
}
export async function taskOperation(
  home: string,
  body: Record<string, unknown>
): Promise<unknown> {
  await requireCapability(home, "taskVersion");
  if (
    body.name !== undefined ||
    ["list", "resolve", "entries", "remove", "diff"].includes(String(body.op))
  ) {
    await requireCapability(home, "taskManagementVersion");
  }
  return roundTrip(daemonSocket(home), encodeJSON(ControlType.task, body));
}
export async function transfer(
  home: string,
  body: Record<string, unknown>
): Promise<void> {
  await requireCapability(home, "transferVersion");
  await roundTrip(
    daemonSocket(home),
    encodeJSON(ControlType.transfer, {
      ...body,
      localPath: resolve(String(body.localPath)),
    })
  );
}
