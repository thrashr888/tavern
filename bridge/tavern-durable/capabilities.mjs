// What this agent's machine offers, for its card in Tavern: its MCP servers (with tool counts),
// the running Docker containers, and which well-known command-line tools are installed. The host
// looks once at start and again every few minutes; nothing here asks the agent.

import { execFile } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

/** Tools worth showing when the agent's PATH has them. */
export const CLIS = ["gh", "glab", "git", "cider", "moff", "docker", "node", "python3", "uv", "cargo", "swift", "xcodebuild", "jq", "rg", "ollama", "terraform", "tfctl"];

/** The CLIs found on `pathList` (a PATH string). */
export function installedClis(pathList = process.env.PATH ?? "", names = CLIS) {
  const dirs = pathList.split(path.delimiter).filter(Boolean);
  return names.filter((name) => dirs.some((dir) => {
    try {
      fs.accessSync(path.join(dir, name), fs.constants.X_OK);
      return true;
    } catch {
      return false;
    }
  }));
}

/** Running container names, or null when Docker isn't there or doesn't answer. */
export function dockerContainers({ run = execFile } = {}) {
  return new Promise((resolve) => {
    run("docker", ["ps", "--format", "{{.Names}}"], { timeout: 5000 }, (error, stdout) => {
      if (error) return resolve(null);
      resolve(String(stdout).split("\n").map((line) => line.trim()).filter(Boolean).sort());
    });
  });
}

/** `{mcp: [{name, tools}], docker, clis}` for get_state. */
export async function capabilities(servers = [], options = {}) {
  return {
    mcp: servers.map((server) => ({ name: server.name, tools: server.tools?.length ?? 0 })),
    docker: await dockerContainers(options),
    clis: installedClis(options.pathList),
  };
}
