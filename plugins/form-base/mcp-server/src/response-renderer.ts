// Render the response HTML by injecting response data into the static template.

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { ResponseDefinition } from "./types.ts";

const __dirname = dirname(fileURLToPath(import.meta.url));
const PUBLIC_DIR = join(__dirname, "..", "public");

export function renderResponseHtml(
  responseId: string,
  definition: ResponseDefinition,
  effectiveRole: "non-developer" | "developer",
): string {
  const template = readFileSync(join(PUBLIC_DIR, "response.html"), "utf-8");
  const payload = JSON.stringify(
    {
      id: responseId,
      definition,
      effective_role: effectiveRole,
    },
    null,
    2,
  );

  return template
    .replace(/\{\{TITLE\}\}/g, escapeHtml(definition.title))
    .replace("/*__RESPONSE_DATA__*/", `window.__RESPONSE_DATA__ = ${payload};`);
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
