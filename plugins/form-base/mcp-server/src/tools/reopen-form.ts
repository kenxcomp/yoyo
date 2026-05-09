import {
  formExists,
  readFormAnswers,
  readFormState,
  writeFormState,
} from "../form-store.ts";
import { fail, ok, type ToolContext, type ToolResult } from "./_context.ts";

export const definition = {
  name: "reopen_form",
  description:
    "Reopen an archived or submitted form (re-publish its URL on the current HTTP server's port). Useful for re-asking the user to revise their answers.",
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
  // If they have prior answers, keep them — reopen status reflects whether
  // we want them to revise (pending) or just view (submitted).
  const prior = readFormAnswers(ctx.cwd, a.form_id);
  writeFormState(ctx.cwd, a.form_id, {
    ...state,
    status: prior ? "submitted" : "pending",
    port: ctx.http.port,
    archived_at: undefined,
  });

  return ok({
    form_id: a.form_id,
    url: `${ctx.http.baseUrl}/forms/${a.form_id}`,
    status: prior ? "submitted" : "pending",
    has_prior_answers: prior !== null,
  });
}
