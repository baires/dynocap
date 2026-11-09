#!/usr/bin/env node
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";

import { createServer } from "./index.ts";

const server = createServer({
  allowNat: process.env.MICROVM_MCP_ALLOW_NAT === "1",
});
await server.connect(new StdioServerTransport());
