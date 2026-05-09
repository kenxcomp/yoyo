import {
  readResponseMeta,
  responseExists,
  writeResponseMeta,
} from "../response-store.ts";
import { fail, ok, type ToolContext, type ToolResult } from "./_context.ts";

export const definition = {
  name: "reopen_response",
  description:
    "Reopen an archived response (re-publish its URL on the current HTTP server's port).",
  inputSchema: {
    type: "object",
    properties: {
      response_id: { type: "string" },
    },
    required: ["response_id"],
  },
} as const;

export async function handler(args: unknown, ctx: ToolContext): Promise<ToolResult> {
  const a = args as { response_id?: string };
  if (!a?.response_id) return fail("`response_id` is required.");
  if (!responseExists(ctx.cwd, a.response_id)) {
    return fail(`response '${a.response_id}' not found`);
  }
  const meta = readResponseMeta(ctx.cwd, a.response_id);
  writeResponseMeta(ctx.cwd, a.response_id, {
    ...meta,
    status: "active",
    port: ctx.http.port,
    archived_at: undefined,
  });
  return ok({
    response_id: a.response_id,
    url: `${ctx.http.baseUrl}/responses/${a.response_id}`,
    status: "active",
  });
}
