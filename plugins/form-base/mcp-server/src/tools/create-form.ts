import { nanoid } from "nanoid";
import { createFormDir } from "../form-store.ts";
import type { FormDefinition } from "../types.ts";
import { fail, ok, type ToolContext, type ToolResult } from "./_context.ts";

export const definition = {
  name: "create_form",
  description:
    "Create an HTML form for the user to fill in (radio / checkbox / text / markdown / color / font / slider). Returns a localhost URL the user opens in a browser. After the user clicks Save and tells you 'I'm done', call read_answers to retrieve their input. Use this when you need to collect structured information (requirements clarification, style choices, etc.) instead of asking many separate text questions.",
  inputSchema: {
    type: "object",
    properties: {
      title: { type: "string", description: "Form title shown at the top of the page." },
      description: {
        type: "string",
        description: "Optional intro text in markdown, rendered above the items.",
      },
      items: {
        type: "array",
        description: "Form items. Each item must include `type`, `name`, and `label`.",
        items: {
          type: "object",
          properties: {
            type: {
              type: "string",
              enum: ["radio", "checkbox", "text", "markdown", "color", "font", "slider"],
            },
            name: { type: "string" },
            label: { type: "string" },
            description: { type: "string" },
            options: {
              type: "array",
              items: {
                type: "object",
                properties: {
                  value: { type: "string" },
                  label: { type: "string" },
                },
                required: ["value", "label"],
              },
            },
            placeholder: { type: "string" },
            rows: { type: "number" },
            samples: { type: "array", items: { type: "string" } },
            min: { type: "number" },
            max: { type: "number" },
            step: { type: "number" },
            unit: { type: "string" },
            default: {},
          },
          required: ["type", "name", "label"],
        },
      },
      style_suggestions: {
        type: "array",
        description: "Optional style proposals shown as comparison cards above the items.",
        items: {
          type: "object",
          properties: {
            name: { type: "string" },
            primary: { type: "string" },
            secondary: { type: "string" },
            font: { type: "string" },
            radius: { type: "number" },
            preview_html: { type: "string" },
            notes: { type: "string" },
          },
          required: ["name"],
        },
      },
    },
    required: ["title", "items"],
  },
} as const;

export async function handler(args: unknown, ctx: ToolContext): Promise<ToolResult> {
  const a = args as Partial<FormDefinition>;
  if (!a || typeof a.title !== "string" || !a.title.trim()) {
    return fail("`title` is required.");
  }
  if (!Array.isArray(a.items) || a.items.length === 0) {
    return fail("`items` must be a non-empty array.");
  }
  for (const it of a.items) {
    if (!it || typeof it !== "object") return fail("each item must be an object");
    if (!("type" in it) || !("name" in it) || !("label" in it)) {
      return fail("each item must have type/name/label");
    }
  }

  const definition: FormDefinition = {
    title: a.title,
    description: a.description,
    items: a.items as FormDefinition["items"],
    style_suggestions: a.style_suggestions,
  };

  const formId = nanoid(10);
  createFormDir(ctx.cwd, formId, definition, ctx.http.port);
  const url = `${ctx.http.baseUrl}/forms/${formId}`;

  return ok({
    form_id: formId,
    url,
    instructions:
      "Tell the user to open the URL, fill in the form, and click Save. When they reply 'I'm done', call read_answers with this form_id.",
  });
}
