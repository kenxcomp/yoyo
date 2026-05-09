// Per-project configuration: <cwd>/.form-base/config.json.

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { DEFAULT_CONFIG, type FormBaseConfig } from "./types.ts";

const ROOT = ".form-base";
const CONFIG_FILE = "config.json";

export function readConfig(cwd: string): FormBaseConfig {
  const path = join(cwd, ROOT, CONFIG_FILE);
  if (!existsSync(path)) return { ...DEFAULT_CONFIG };
  try {
    const partial = JSON.parse(readFileSync(path, "utf-8")) as Partial<FormBaseConfig>;
    return { ...DEFAULT_CONFIG, ...partial };
  } catch {
    return { ...DEFAULT_CONFIG };
  }
}

export function writeConfig(cwd: string, config: FormBaseConfig): void {
  const path = join(cwd, ROOT, CONFIG_FILE);
  writeFileSync(path, JSON.stringify(config, null, 2));
}
