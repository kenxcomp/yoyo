// Shared tool context — kept thin on purpose.

import type { HttpServerHandle } from "../http-server.ts";

export interface ToolContext {
  cwd: string;
  http: HttpServerHandle;
}

export interface ToolResultContent {
  type: "text";
  text: string;
}

export interface ToolResult {
  content: ToolResultContent[];
  isError?: boolean;
  [key: string]: unknown;
}

export function ok(payload: unknown): ToolResult {
  return {
    content: [{ type: "text", text: JSON.stringify(payload, null, 2) }],
  };
}

export function fail(message: string): ToolResult {
  return {
    content: [{ type: "text", text: JSON.stringify({ ok: false, error: message }) }],
    isError: true,
  };
}
