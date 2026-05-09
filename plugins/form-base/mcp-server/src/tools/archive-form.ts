import { formExists, readFormState, writeFormState } from "../form-store.ts";
import { fail, ok, type ToolContext, type ToolResult } from "./_context.ts";

export const definition = {
  name: "archive_form",
  description:
    "Archive a form so it no longer appears in the active list. Definition and answers stay on disk for review.",
  inputSchema: {
    type: "object",
    properties: {
      form_id: { type: "string" },
    },
    required: ["form_id"],
  },
} as const;

export async function handler(args: unknown, ctx: ToolContext): Promise<ToolResult> {
  const a = args as { form_id?: string };
  if (!a?.form_id) return fail("`form_id` is required.");
  if (!formExists(ctx.cwd, a.form_id)) return fail(`form '${a.form_id}' not found`);
  const state = readFormState(ctx.cwd, a.form_id);
  writeFormState(ctx.cwd, a.form_id, {
    ...state,
    status: "archived",
    archived_at: new Date().toISOString(),
  });
  return ok({ ok: true, form_id: a.form_id, status: "archived" });
}
