// Shared types for form-base MCP server.

// ────────────────────────── FORM ──────────────────────────

export type FormItem =
  | RadioItem
  | CheckboxItem
  | TextItem
  | MarkdownItem
  | ColorItem
  | FontItem
  | SliderItem;

export interface RadioItem {
  type: "radio";
  name: string;
  label: string;
  options: { value: string; label: string }[];
  default?: string;
  description?: string;
}

export interface CheckboxItem {
  type: "checkbox";
  name: string;
  label: string;
  options: { value: string; label: string }[];
  default?: string[];
  description?: string;
}

export interface TextItem {
  type: "text";
  name: string;
  label: string;
  placeholder?: string;
  default?: string;
  description?: string;
}

export interface MarkdownItem {
  type: "markdown";
  name: string;
  label: string;
  rows?: number;
  default?: string;
  description?: string;
}

export interface ColorItem {
  type: "color";
  name: string;
  label: string;
  default?: string;
  description?: string;
}

export interface FontItem {
  type: "font";
  name: string;
  label: string;
  samples: string[];
  default?: string;
  description?: string;
}

export interface SliderItem {
  type: "slider";
  name: string;
  label: string;
  min: number;
  max: number;
  step?: number;
  default?: number;
  unit?: string;
  description?: string;
}

export interface StyleProposal {
  name: string;
  primary?: string;
  secondary?: string;
  font?: string;
  radius?: number;
  preview_html?: string;
  notes?: string;
}

export interface FormDefinition {
  title: string;
  description?: string;
  items: FormItem[];
  style_suggestions?: StyleProposal[];
}

export type FormStatus = "pending" | "submitted" | "archived";

export interface FormState {
  status: FormStatus;
  port: number;
  created_at: string;
  submitted_at?: string;
  archived_at?: string;
}

export interface FormAnswers {
  answers: Record<string, unknown>;
  submitted_at: string;
}

// ────────────────────────── RESPONSE ──────────────────────────

export interface ResponseDefinition {
  title: string;
  business: string;
  technical?: string;
  user_role?: "non-developer" | "developer";
  attachments?: {
    images?: { src: string; alt?: string }[];
    files_changed?: string[];
  };
}

export type ResponseStatus = "active" | "archived";

export interface ResponseMeta {
  status: ResponseStatus;
  port: number;
  created_at: string;
  archived_at?: string;
}

// ────────────────────────── ROLE ──────────────────────────

// Role shapes ONLY how the agent answers (vocabulary, framing, level of detail).
// It never restricts which tools the agent uses or how tasks are executed.
// `null` means no persona injection — default Claude Code voice.
export type FormBaseRole = "product-manager" | "developer" | "lawyer" | null;

export const KNOWN_ROLES = ["product-manager", "developer", "lawyer"] as const;

// ────────────────────────── CONFIG ──────────────────────────

export interface FormBaseConfig {
  role: FormBaseRole;
  default_user_role: "non-developer" | "developer";
  response_threshold_chars: number;
  response_threshold_lines: number;
  auto_open_browser: boolean;
}

export const DEFAULT_CONFIG: FormBaseConfig = {
  role: "product-manager",
  default_user_role: "non-developer",
  response_threshold_chars: 600,
  response_threshold_lines: 30,
  auto_open_browser: false,
};
