// Project-level filesystem I/O for responses.

import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { ResponseDefinition, ResponseMeta } from "./types.ts";

const ROOT = ".form-base";
const RESPONSES = "responses";

function responseDir(cwd: string, responseId: string): string {
  return join(cwd, ROOT, RESPONSES, responseId);
}

function ensureRoot(cwd: string): void {
  const dir = join(cwd, ROOT, RESPONSES);
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
}

export function createResponseDir(
  cwd: string,
  responseId: string,
  definition: ResponseDefinition,
  port: number,
): ResponseMeta {
  ensureRoot(cwd);
  const dir = responseDir(cwd, responseId);
  mkdirSync(dir, { recursive: true });

  writeFileSync(join(dir, "content.json"), JSON.stringify(definition, null, 2));

  const meta: ResponseMeta = {
    status: "active",
    port,
    created_at: new Date().toISOString(),
  };
  writeFileSync(join(dir, "meta.json"), JSON.stringify(meta, null, 2));
  return meta;
}

export function responseExists(cwd: string, responseId: string): boolean {
  return existsSync(join(responseDir(cwd, responseId), "content.json"));
}

export function readResponseDefinition(cwd: string, responseId: string): ResponseDefinition {
  const path = join(responseDir(cwd, responseId), "content.json");
  return JSON.parse(readFileSync(path, "utf-8")) as ResponseDefinition;
}

export function readResponseMeta(cwd: string, responseId: string): ResponseMeta {
  const path = join(responseDir(cwd, responseId), "meta.json");
  return JSON.parse(readFileSync(path, "utf-8")) as ResponseMeta;
}

export function writeResponseMeta(cwd: string, responseId: string, meta: ResponseMeta): void {
  const path = join(responseDir(cwd, responseId), "meta.json");
  writeFileSync(path, JSON.stringify(meta, null, 2));
}

export function listResponseIds(cwd: string): string[] {
  const dir = join(cwd, ROOT, RESPONSES);
  if (!existsSync(dir)) return [];
  return readdirSync(dir, { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => d.name);
}
