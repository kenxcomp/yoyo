// Render the form HTML by injecting form data into the static template.

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { FormDefinition, FormState } from "./types.ts";

const __dirname = dirname(fileURLToPath(import.meta.url));
const PUBLIC_DIR = join(__dirname, "..", "public");

export function renderFormHtml(
  formId: string,
  definition: FormDefinition,
  state: FormState,
): string {
  const template = readFileSync(join(PUBLIC_DIR, "form.html"), "utf-8");
  const payload = JSON.stringify(
    {
      id: formId,
      definition,
      status: state.status,
      submitted_at: state.submitted_at ?? null,
    },
    null,
    2,
  );

  return template
    .replace(/\{\{TITLE\}\}/g, escapeHtml(definition.title))
    .replace("/*__FORM_DATA__*/", `window.__FORM_DATA__ = ${payload};`);
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
