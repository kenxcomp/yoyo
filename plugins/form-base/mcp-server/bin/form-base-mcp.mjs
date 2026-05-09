#!/usr/bin/env bun
// Thin shim so npm accepts the bin entry (it rejects .ts extensions).
// Bun runtime executes this .mjs and then loads the TypeScript source directly.
import "../src/index.ts";
