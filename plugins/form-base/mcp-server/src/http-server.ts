// Embedded HTTP server for serving form/response HTML and accepting submissions.
// Binds to localhost:0 (system-assigned random port) and serves only on 127.0.0.1.

import { Hono } from "hono";
import { existsSync, readFileSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { readConfig } from "./config-store.ts";
import {
  formExists,
  readFormDefinition,
  readFormState,
  writeFormAnswers,
  writeFormState,
} from "./form-store.ts";
import { renderFormHtml } from "./form-renderer.ts";
import {
  readResponseDefinition,
  readResponseMeta,
  responseExists,
  writeResponseMeta,
} from "./response-store.ts";
import { renderResponseHtml } from "./response-renderer.ts";
import type { FormBaseConfig } from "./types.ts";

// `developer` role wants code-by-default; PM/lawyer/null fall back to the
// explicit `default_user_role` config (which itself defaults to non-developer).
function roleToUserRoleDefault(config: FormBaseConfig): "non-developer" | "developer" {
  if (config.role === "developer") return "developer";
  return config.default_user_role;
}

const __dirname = dirname(fileURLToPath(import.meta.url));
const PUBLIC_DIR = resolve(join(__dirname, "..", "public"));

export interface HttpServerHandle {
  port: number;
  baseUrl: string;
  stop: () => void;
}

export function startHttpServer(cwd: string): HttpServerHandle {
  const app = new Hono();

  // Form view (writable)
  app.get("/forms/:id", (c) => {
    const id = c.req.param("id");
    if (!formExists(cwd, id)) return c.text("Form not found", 404);
    const def = readFormDefinition(cwd, id);
    const state = readFormState(cwd, id);
    return c.html(renderFormHtml(id, def, state));
  });

  // Form submit
  app.post("/forms/:id/submit", async (c) => {
    const id = c.req.param("id");
    if (!formExists(cwd, id)) {
      return c.json({ ok: false, error: "form not found" }, 404);
    }
    const body = (await c.req.json().catch(() => ({}))) as {
      answers?: Record<string, unknown>;
    };
    const answers = body.answers ?? {};
    writeFormAnswers(cwd, id, answers);
    const state = readFormState(cwd, id);
    writeFormState(cwd, id, {
      ...state,
      status: "submitted",
      submitted_at: new Date().toISOString(),
    });
    return c.json({ ok: true });
  });

  // Response view (read-only)
  app.get("/responses/:id", (c) => {
    const id = c.req.param("id");
    if (!responseExists(cwd, id)) return c.text("Response not found", 404);
    const def = readResponseDefinition(cwd, id);
    // touch meta to mark "viewed_at" if you ever want — not used now.
    readResponseMeta(cwd, id);
    const config = readConfig(cwd);
    const role = def.user_role ?? roleToUserRoleDefault(config);
    return c.html(renderResponseHtml(id, def, role));
  });

  // Allow toggling user_role from inside the page (per-response).
  app.post("/responses/:id/role", async (c) => {
    const id = c.req.param("id");
    if (!responseExists(cwd, id)) {
      return c.json({ ok: false, error: "response not found" }, 404);
    }
    const body = (await c.req.json().catch(() => ({}))) as {
      user_role?: "non-developer" | "developer";
    };
    const role = body.user_role;
    if (role !== "non-developer" && role !== "developer") {
      return c.json({ ok: false, error: "invalid user_role" }, 400);
    }
    const def = readResponseDefinition(cwd, id);
    def.user_role = role;
    // rewrite content.json so subsequent loads honor it
    const path = join(cwd, ".form-base", "responses", id, "content.json");
    const fs = await import("node:fs/promises");
    await fs.writeFile(path, JSON.stringify(def, null, 2));
    return c.json({ ok: true });
  });

  // Static assets — only files under public/, no traversal
  app.get("/assets/*", (c) => {
    const requested = decodeURIComponent(c.req.path.replace(/^\/assets\//, ""));
    const filePath = resolve(join(PUBLIC_DIR, requested));
    if (filePath !== PUBLIC_DIR && !filePath.startsWith(PUBLIC_DIR + "/")) {
      return c.text("forbidden", 403);
    }
    if (!existsSync(filePath)) return c.text("not found", 404);
    if (!statSync(filePath).isFile()) return c.text("not a file", 404);
    const data = readFileSync(filePath);
    return new Response(data, {
      headers: {
        "content-type": guessMime(filePath),
        "cache-control": "public, max-age=300",
      },
    });
  });

  // Health
  app.get("/health", (c) => c.json({ ok: true, cwd }));

  const server = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    fetch: app.fetch,
  });

  const port = server.port;
  if (typeof port !== "number") {
    throw new Error("HTTP server failed to bind a port");
  }

  return {
    port,
    baseUrl: `http://localhost:${port}`,
    stop: () => server.stop(),
  };
}

function guessMime(path: string): string {
  const ext = path.split(".").pop()?.toLowerCase() ?? "";
  switch (ext) {
    case "html":
      return "text/html; charset=utf-8";
    case "js":
    case "mjs":
      return "application/javascript; charset=utf-8";
    case "css":
      return "text/css; charset=utf-8";
    case "json":
      return "application/json; charset=utf-8";
    case "svg":
      return "image/svg+xml";
    case "png":
      return "image/png";
    case "jpg":
    case "jpeg":
      return "image/jpeg";
    case "woff":
      return "font/woff";
    case "woff2":
      return "font/woff2";
    case "ttf":
      return "font/ttf";
    case "ico":
      return "image/x-icon";
    default:
      return "application/octet-stream";
  }
}
