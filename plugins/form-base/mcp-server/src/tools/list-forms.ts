import { listFormIds, readFormDefinition, readFormState } from "../form-store.ts";
import type { FormStatus } from "../types.ts";
import { ok, type ToolContext, type ToolResult } from "./_context.ts";

export const definition = {
  name: "list_forms",
  description:
    "List all forms in the current project (cwd/.form-base/forms/*). Optional filter by status.",
  inputSchema: {
    type: "object",
    properties: {
      status: {
        type: "string",
        enum: ["pending", "submitted", "archived"],
        description: "Filter by status.",
      },
    },
  },
} as const;

export async function handler(args: unknown, ctx: ToolContext): Promise<ToolResult> {
  const a = args as { status?: FormStatus };
  const ids = listFormIds(ctx.cwd);
  const items = ids
    .map((id) => {
      try {
        const def = readFormDefinition(ctx.cwd, id);
        const state = readFormState(ctx.cwd, id);
        return {
          form_id: id,
          title: def.title,
          status: state.status,
          created_at: state.created_at,
          submitted_at: state.submitted_at ?? null,
        };
      } catch {
        return null;
      }
    })
    .filter((x): x is NonNullable<typeof x> => x !== null)
    .filter((x) => (a?.status ? x.status === a.status : true))
    .sort((x, y) => y.created_at.localeCompare(x.created_at));

  return ok({ count: items.length, forms: items });
}
