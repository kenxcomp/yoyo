import {
  readResponseMeta,
  responseExists,
  writeResponseMeta,
} from "../response-store.ts";
import { fail, ok, type ToolContext, type ToolResult } from "./_context.ts";

export const definition = {
  name: "archive_response",
  description:
    "Archive a response so it no longer appears in the active list. Content stays on disk for review.",
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
    status: "archived",
    archived_at: new Date().toISOString(),
  });
  return ok({ ok: true, response_id: a.response_id, status: "archived" });
}
