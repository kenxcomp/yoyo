import { formExists, readFormAnswers, readFormState } from "../form-store.ts";
import { fail, ok, type ToolContext, type ToolResult } from "./_context.ts";

export const definition = {
  name: "read_answers",
  description:
    "Read the user's submitted answers for a form. Call this after the user says 'I'm done' / 'I've finished' / similar. Returns the answers map plus the submission timestamp.",
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

  const answers = readFormAnswers(ctx.cwd, a.form_id);
  if (!answers) {
    const state = readFormState(ctx.cwd, a.form_id);
    return fail(
      `form '${a.form_id}' has no answers yet (status: ${state.status}). Ask the user to open the form URL and click Save.`,
    );
  }

  return ok({
    form_id: a.form_id,
    answers: answers.answers,
    submitted_at: answers.submitted_at,
  });
}
