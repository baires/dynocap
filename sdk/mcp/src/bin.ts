#!/usr/bin/env node
import path from "node:path";

import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";

import { createServer } from "./index.ts";

const list = (value: string | undefined, separator: string) =>
  value === undefined ? undefined : value.split(separator).filter(Boolean);

const server = createServer({
  allowNat: process.env.DYNOCAP_MCP_ALLOW_NAT === "1",
  allowFiltered: process.env.DYNOCAP_MCP_ALLOW_FILTERED === "1",
  allowSshKey: process.env.DYNOCAP_MCP_ALLOW_SSH_KEY === "1",
  roots: list(process.env.DYNOCAP_MCP_ROOTS, path.delimiter),
  gitHosts: list(process.env.DYNOCAP_MCP_GIT_HOSTS, ","),
});
await server.connect(new StdioServerTransport());
