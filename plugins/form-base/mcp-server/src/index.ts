#!/usr/bin/env bun
// form-base MCP server entry. Starts the embedded HTTP server, registers tools,
// and connects stdio transport.

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { startHttpServer } from "./http-server.ts";
import * as archiveForm from "./tools/archive-form.ts";
import * as archiveResponse from "./tools/archive-response.ts";
import * as createForm from "./tools/create-form.ts";
import * as getFormStatus from "./tools/get-form-status.ts";
import * as listForms from "./tools/list-forms.ts";
import * as listResponses from "./tools/list-responses.ts";
import * as readAnswers from "./tools/read-answers.ts";
import * as renderResponse from "./tools/render-response.ts";
import * as reopenForm from "./tools/reopen-form.ts";
import * as reopenResponse from "./tools/reopen-response.ts";
import type { ToolContext, ToolResult } from "./tools/_context.ts";

type ToolModule = {
  definition: { name: string; description: string; inputSchema: unknown };
  handler: (args: unknown, ctx: ToolContext) => Promise<ToolResult>;
};

const TOOLS: ToolModule[] = [
  createForm,
  getFormStatus,
  readAnswers,
  listForms,
  archiveForm,
  reopenForm,
  renderResponse,
  listResponses,
  archiveResponse,
  reopenResponse,
];

async function main() {
  const cwd = process.cwd();
  const http = startHttpServer(cwd);

  const ctx: ToolContext = { cwd, http };

  const server = new Server(
    { name: "form-base", version: "1.0.0" },
    { capabilities: { tools: {} } },
  );

  server.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: TOOLS.map((t) => t.definition),
  }));

  server.setRequestHandler(CallToolRequestSchema, async (req) => {
    const name = req.params.name;
    const args = req.params.arguments ?? {};
    const tool = TOOLS.find((t) => t.definition.name === name);
    if (!tool) {
      return {
        content: [{ type: "text", text: `unknown tool: ${name}` }],
        isError: true,
      };
    }
    try {
      return await tool.handler(args, ctx);
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      return {
        content: [{ type: "text", text: `tool '${name}' failed: ${msg}` }],
        isError: true,
      };
    }
  });

  // Log to stderr so it doesn't pollute the stdio MCP channel.
  process.stderr.write(
    `[form-base] MCP server up. HTTP: ${http.baseUrl}  cwd: ${cwd}\n`,
  );

  const transport = new StdioServerTransport();
  await server.connect(transport);

  // Clean shutdown
  const shutdown = () => {
    try {
      http.stop();
    } catch {
      /* noop */
    }
    process.exit(0);
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}

main().catch((err) => {
  process.stderr.write(
    `[form-base] fatal: ${err instanceof Error ? err.stack ?? err.message : String(err)}\n`,
  );
  process.exit(1);
});
