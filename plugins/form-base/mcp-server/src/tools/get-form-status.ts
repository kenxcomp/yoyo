import { formExists, readFormState } from "../form-store.ts";
import { fail, ok, type ToolContext, type ToolResult } from "./_context.ts";

export const definition = {
  name: "get_form_status",
  description:
    "Check whether a form has been submitted. Returns `pending` (waiting on the user), `submitted` (read_answers will succeed), or `archived`.",
  inputSchema: {
    type: "object",
    properties: {
      form_id: { type: "string", description: "The form_id returned by create_form." },
    },
    required: ["form_id"],
  },
} as const;

export async function handler(args: unknown, ctx: ToolContext): Promise<ToolResult> {
  const a = args as { form_id?: string };
  if (!a?.form_id) return fail("`form_id` is required.");
  if (!formExists(ctx.cwd, a.form_id)) return fail(`form '${a.form_id}' not found`);
  const state = readFormState(ctx.cwd, a.form_id);
  return ok({
    form_id: a.form_id,
    status: state.status,
    submitted_at: state.submitted_at ?? null,
    created_at: state.created_at,
  });
}
