import { nanoid } from "nanoid";
import { createResponseDir } from "../response-store.ts";
import type { ResponseDefinition } from "../types.ts";
import { fail, ok, type ToolContext, type ToolResult } from "./_context.ts";

export const definition = {
  name: "render_response",
  description:
    "Render a long response as an HTML page where the BUSINESS section is shown by default and the TECHNICAL section is hidden behind a collapsed toggle. Use this when your reply is long (~600 chars / 30 lines), contains code/files/diffs, or the user's request was business-level (e.g. 'build me an X') rather than a pure technical question. The `business` field should read like a non-technical user-facing summary; the `technical` field can include file paths, code blocks, diffs, and decisions. Default user_role is 'non-developer' (technical hidden); set to 'developer' only if the user explicitly asked for code/details.",
  inputSchema: {
    type: "object",
    properties: {
      title: { type: "string", description: "High-level title in user-language (no jargon)." },
      business: {
        type: "string",
        description:
          "Markdown rendered by default. Describe what changed from the user's app/business perspective. Avoid file names, function names, and technical terms.",
      },
      technical: {
        type: "string",
        description:
          "Optional markdown shown only after the user expands the toggle. Put files / code blocks / diffs / technical decisions here.",
      },
      user_role: {
        type: "string",
        enum: ["non-developer", "developer"],
        description: "If 'developer', technical is shown by default. Default: 'non-developer'.",
      },
      attachments: {
        type: "object",
        properties: {
          images: {
            type: "array",
            items: {
              type: "object",
              properties: {
                src: { type: "string" },
                alt: { type: "string" },
              },
              required: ["src"],
            },
          },
          files_changed: {
            type: "array",
            items: { type: "string" },
            description: "List of file paths changed; rendered above the technical body.",
          },
        },
      },
    },
    required: ["title", "business"],
  },
} as const;

export async function handler(args: unknown, ctx: ToolContext): Promise<ToolResult> {
  const a = args as Partial<ResponseDefinition>;
  if (!a || typeof a.title !== "string" || !a.title.trim()) {
    return fail("`title` is required.");
  }
  if (typeof a.business !== "string" || !a.business.trim()) {
    return fail("`business` is required (markdown for the user-facing summary).");
  }

  const definition: ResponseDefinition = {
    title: a.title,
    business: a.business,
    technical: a.technical,
    user_role: a.user_role,
    attachments: a.attachments,
  };

  const id = nanoid(10);
  createResponseDir(ctx.cwd, id, definition, ctx.http.port);
  const url = `${ctx.http.baseUrl}/responses/${id}`;

  return ok({
    response_id: id,
    url,
    instructions:
      "Tell the user a short one-liner like '已经准备好详细说明,请打开 [URL] 查看,有反馈随时说' — do NOT repeat the business content in CLI; the HTML page is the deliverable.",
  });
}
