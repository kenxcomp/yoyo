import {
  listResponseIds,
  readResponseDefinition,
  readResponseMeta,
} from "../response-store.ts";
import type { ResponseStatus } from "../types.ts";
import { ok, type ToolContext, type ToolResult } from "./_context.ts";

export const definition = {
  name: "list_responses",
  description:
    "List rendered responses in the current project (cwd/.form-base/responses/*). Optional filter by status.",
  inputSchema: {
    type: "object",
    properties: {
      status: {
        type: "string",
        enum: ["active", "archived"],
        description: "Filter by status.",
      },
    },
  },
} as const;

export async function handler(args: unknown, ctx: ToolContext): Promise<ToolResult> {
  const a = args as { status?: ResponseStatus };
  const ids = listResponseIds(ctx.cwd);
  const items = ids
    .map((id) => {
      try {
        const def = readResponseDefinition(ctx.cwd, id);
        const meta = readResponseMeta(ctx.cwd, id);
        return {
          response_id: id,
          title: def.title,
          status: meta.status,
          user_role: def.user_role ?? "non-developer",
          has_technical: Boolean(def.technical),
          created_at: meta.created_at,
        };
      } catch {
        return null;
      }
    })
    .filter((x): x is NonNullable<typeof x> => x !== null)
    .filter((x) => (a?.status ? x.status === a.status : true))
    .sort((x, y) => y.created_at.localeCompare(x.created_at));

  return ok({ count: items.length, responses: items });
}
