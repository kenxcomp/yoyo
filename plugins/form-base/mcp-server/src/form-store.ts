// Project-level filesystem I/O for forms.
// All paths are anchored to a `cwd` argument so we don't lock to process.cwd().

import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { FormAnswers, FormDefinition, FormState } from "./types.ts";

const ROOT = ".form-base";
const FORMS = "forms";

function formDir(cwd: string, formId: string): string {
  return join(cwd, ROOT, FORMS, formId);
}

function ensureFormBaseRoot(cwd: string): void {
  const root = join(cwd, ROOT);
  const forms = join(root, FORMS);
  if (!existsSync(forms)) mkdirSync(forms, { recursive: true });

  const gitignore = join(root, ".gitignore");
  if (!existsSync(gitignore)) {
    writeFileSync(
      gitignore,
      [
        "# form-base — keep prompts/content under review, ignore live state and answers.",
        "forms/*/state.json",
        "forms/*/answers.json",
        "responses/*/meta.json",
        "",
      ].join("\n"),
    );
  }
}

export function createFormDir(
  cwd: string,
  formId: string,
  definition: FormDefinition,
  port: number,
): FormState {
  ensureFormBaseRoot(cwd);
  const dir = formDir(cwd, formId);
  mkdirSync(dir, { recursive: true });

  writeFileSync(join(dir, "definition.json"), JSON.stringify(definition, null, 2));

  const state: FormState = {
    status: "pending",
    port,
    created_at: new Date().toISOString(),
  };
  writeFileSync(join(dir, "state.json"), JSON.stringify(state, null, 2));
  return state;
}

export function formExists(cwd: string, formId: string): boolean {
  return existsSync(join(formDir(cwd, formId), "definition.json"));
}

export function readFormDefinition(cwd: string, formId: string): FormDefinition {
  const path = join(formDir(cwd, formId), "definition.json");
  return JSON.parse(readFileSync(path, "utf-8")) as FormDefinition;
}

export function readFormState(cwd: string, formId: string): FormState {
  const path = join(formDir(cwd, formId), "state.json");
  return JSON.parse(readFileSync(path, "utf-8")) as FormState;
}

export function writeFormState(cwd: string, formId: string, state: FormState): void {
  const path = join(formDir(cwd, formId), "state.json");
  writeFileSync(path, JSON.stringify(state, null, 2));
}

export function readFormAnswers(cwd: string, formId: string): FormAnswers | null {
  const path = join(formDir(cwd, formId), "answers.json");
  if (!existsSync(path)) return null;
  return JSON.parse(readFileSync(path, "utf-8")) as FormAnswers;
}

export function writeFormAnswers(
  cwd: string,
  formId: string,
  answers: Record<string, unknown>,
): FormAnswers {
  const path = join(formDir(cwd, formId), "answers.json");
  const payload: FormAnswers = {
    answers,
    submitted_at: new Date().toISOString(),
  };
  writeFileSync(path, JSON.stringify(payload, null, 2));
  return payload;
}

export function listFormIds(cwd: string): string[] {
  const dir = join(cwd, ROOT, FORMS);
  if (!existsSync(dir)) return [];
  return readdirSync(dir, { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => d.name);
}
