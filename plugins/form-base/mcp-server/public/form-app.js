// form-base — form runtime. Reads window.__FORM_DATA__, renders items, handles save.

import { marked } from "marked";
import { renderRadio } from "/assets/components/radio.js";
import { renderCheckbox } from "/assets/components/checkbox.js";
import { renderText } from "/assets/components/text.js";
import { renderMarkdown } from "/assets/components/markdown.js";

// Phase 2 components — also imported eagerly; tree-shaking unimportant for our scale.
import { renderColor } from "/assets/components/color-picker.js";
import { renderFont } from "/assets/components/font-sample.js";
import { renderSlider } from "/assets/components/slider.js";

const RENDERERS = {
  radio: renderRadio,
  checkbox: renderCheckbox,
  text: renderText,
  markdown: renderMarkdown,
  color: renderColor,
  font: renderFont,
  slider: renderSlider,
};

const data = window.__FORM_DATA__;
if (!data) {
  document.body.innerHTML = "<main><h1>无效表单数据</h1></main>";
  throw new Error("missing window.__FORM_DATA__");
}

const formIdSpan = document.getElementById("fb-form-id");
formIdSpan.textContent = data.id;

const statusSpan = document.getElementById("fb-status");

// Description
const descBox = document.getElementById("fb-description");
if (data.definition.description) {
  descBox.innerHTML = marked.parse(data.definition.description, { gfm: true, breaks: true });
  descBox.hidden = false;
}

// Style suggestions (Phase 2 will fill rendering — kept here behind a feature gate)
const styleHost = document.getElementById("fb-style-suggestions");
if (Array.isArray(data.definition.style_suggestions) && data.definition.style_suggestions.length) {
  renderStyleSuggestions(styleHost, data.definition.style_suggestions);
}

// Items
const itemsHost = document.getElementById("fb-items");
const valueGetters = [];

for (const item of data.definition.items) {
  const r = RENDERERS[item.type];
  if (!r) {
    const note = document.createElement("div");
    note.className = "fb-item";
    note.innerHTML = `<div class="fb-item-label">[未知字段类型: ${escapeHtml(item.type)}]</div>`;
    itemsHost.appendChild(note);
    continue;
  }

  const card = document.createElement("section");
  card.className = "fb-item";
  card.dataset.fieldType = item.type;
  card.dataset.fieldName = item.name;

  const label = document.createElement("div");
  label.className = "fb-item-label";
  label.textContent = item.label;
  card.appendChild(label);

  if (item.description) {
    const desc = document.createElement("div");
    desc.className = "fb-item-description";
    desc.innerHTML = marked.parseInline(item.description);
    card.appendChild(desc);
  }

  const built = r(item);
  card.appendChild(built.element);
  itemsHost.appendChild(card);
  valueGetters.push(() => [item.name, built.getValue()]);
}

// Pre-fill banner if already submitted
if (data.status === "submitted" || data.status === "archived") {
  const banner = document.getElementById("fb-saved-banner");
  banner.hidden = false;
  banner.innerHTML =
    `<strong>此表单已提交于 ${escapeHtml(data.submitted_at || "未知时间")}</strong>。 ` +
    `如需修改,直接编辑后再次点保存即可。`;
}

// Save handler
const form = document.getElementById("fb-form");
const saveBtn = document.getElementById("fb-save");
const savebarStatus = document.getElementById("fb-savebar-status");

form.addEventListener("submit", async (ev) => {
  ev.preventDefault();
  saveBtn.disabled = true;
  setStatus(savebarStatus, "saving", "保存中…");

  const answers = Object.fromEntries(valueGetters.map((g) => g()));
  try {
    const res = await fetch(`/forms/${encodeURIComponent(data.id)}/submit`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ answers }),
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    setStatus(savebarStatus, "success", "已保存");
    document.getElementById("fb-saved-banner").hidden = false;
  } catch (err) {
    setStatus(savebarStatus, "error", `保存失败: ${err?.message ?? String(err)}`);
  } finally {
    saveBtn.disabled = false;
  }
});

// ─── helpers ───

function setStatus(el, kind, text) {
  el.classList.remove("is-success", "is-error");
  if (kind === "success") el.classList.add("is-success");
  if (kind === "error") el.classList.add("is-error");
  el.querySelector(".label").textContent = text;
}

function escapeHtml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function renderStyleSuggestions(host, proposals) {
  const grid = document.createElement("div");
  grid.className = "fb-styles";
  for (const p of proposals) {
    const card = document.createElement("div");
    card.className = "fb-style-card";
    const name = document.createElement("div");
    name.className = "fb-style-card-name";
    name.textContent = p.name;
    card.appendChild(name);

    const swatches = document.createElement("div");
    swatches.className = "fb-style-swatches";
    for (const color of [p.primary, p.secondary].filter(Boolean)) {
      const sw = document.createElement("div");
      sw.className = "fb-style-swatch";
      sw.style.background = color;
      sw.title = color;
      swatches.appendChild(sw);
    }
    if (swatches.childElementCount) card.appendChild(swatches);

    const meta = document.createElement("div");
    meta.className = "fb-style-card-meta";
    const bits = [];
    if (p.font) bits.push(`字体: ${p.font}`);
    if (typeof p.radius === "number") bits.push(`圆角: ${p.radius}px`);
    meta.textContent = bits.join(" · ");
    if (bits.length) card.appendChild(meta);

    if (p.notes) {
      const notes = document.createElement("div");
      notes.className = "fb-style-card-meta";
      notes.style.marginTop = "6px";
      notes.textContent = p.notes;
      card.appendChild(notes);
    }

    grid.appendChild(card);
  }
  host.appendChild(grid);
}
