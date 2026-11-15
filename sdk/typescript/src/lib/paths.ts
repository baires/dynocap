import os from "node:os";
import path from "node:path";

export function resolveHome(home: string | undefined): string {
  if (home && home.length > 0) return path.resolve(home);
  const fromEnv = process.env.DYNOCAP_HOME;
  if (fromEnv && fromEnv.length > 0) return path.resolve(fromEnv);
  return path.join(os.homedir(), ".dynocap");
}

export function daemonSocket(home: string): string {
  return path.join(home, "daemon.sock");
}
