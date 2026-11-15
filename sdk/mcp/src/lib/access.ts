import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";

/** Repository hosts an MCP caller may name when DYNOCAP_MCP_GIT_HOSTS is unset. */
export const DEFAULT_GIT_HOSTS = ["github.com", "gitlab.com", "bitbucket.org"];

export type AccessPolicy = {
  /** Directories a task may import. Unset means the server's working directory. */
  roots?: string[];
  /** Hosts a repositoryUrl may name. Unset means DEFAULT_GIT_HOSTS. */
  gitHosts?: string[];
  /** Let the caller name an SSH key file for a guest fetch. */
  allowSshKey?: boolean;
};

/** The caller may be a prompt-injected model, so host paths are the server's choice, not the caller's. */
export async function admitProjectPath(
  projectPath: string,
  policy: AccessPolicy
): Promise<string> {
  const home = await real(os.homedir());
  const resolved = await real(path.resolve(projectPath));
  if (sensitive(resolved, home))
    throw new Error(
      `projectPath ${resolved} is the home directory, contains it, or is a dot directory in it`
    );
  const roots = await allowedRoots(policy, home);
  if (roots.length === 0)
    throw new Error(
      "no project roots are configured for this MCP server; set DYNOCAP_MCP_ROOTS to the directories tasks may import"
    );
  if (!roots.some((root) => within(resolved, root)))
    throw new Error(
      `projectPath ${resolved} is outside the MCP project roots (${roots.join(", ")}); set DYNOCAP_MCP_ROOTS to allow it`
    );
  return resolved;
}

export function admitRepositoryUrl(url: string, policy: AccessPolicy): void {
  const allowed = (policy.gitHosts ?? DEFAULT_GIT_HOSTS).map((host) =>
    host.trim().toLowerCase()
  );
  let host: string;
  if (url.startsWith("git@")) host = url.slice(4).split(":")[0] ?? "";
  else {
    try {
      host = new URL(url).hostname;
    } catch {
      throw new Error("repositoryUrl is invalid");
    }
  }
  host = host.toLowerCase();
  if (!allowed.includes(host))
    throw new Error(
      `repository host ${host} is not allowed by this MCP server; set DYNOCAP_MCP_GIT_HOSTS to permit it`
    );
}

async function allowedRoots(
  policy: AccessPolicy,
  home: string
): Promise<string[]> {
  if (policy.roots !== undefined) {
    const roots: string[] = [];
    for (const root of policy.roots.filter((entry) => entry.length > 0))
      roots.push(await real(path.resolve(root)));
    return roots.filter((root) => !sensitive(root, home));
  }
  // A server launched from / or ~ would otherwise expose the whole home directory.
  const cwd = await real(process.cwd());
  return sensitive(cwd, home) ? [] : [cwd];
}

function sensitive(candidate: string, home: string): boolean {
  if (within(home, candidate)) return true;
  if (!within(candidate, home)) return false;
  return path.relative(home, candidate).split(path.sep)[0]!.startsWith(".");
}

function within(candidate: string, root: string): boolean {
  const relative = path.relative(root, candidate);
  return (
    relative === "" ||
    (relative !== ".." &&
      !relative.startsWith(".." + path.sep) &&
      !path.isAbsolute(relative))
  );
}

async function real(target: string): Promise<string> {
  return fs.realpath(target);
}
