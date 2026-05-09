// Markdown editor with side-by-side live preview.

import { marked } from "marked";

export function renderMarkdown(item) {
  const wrapper = document.createElement("div");
  wrapper.className = "fb-md";

  const editorCol = document.createElement("div");
  editorCol.className = "fb-md-editor";
  const editorLabel = document.createElement("div");
  editorLabel.className = "fb-md-editor-label";
  editorLabel.textContent = "Markdown 输入";
  const textarea = document.createElement("textarea");
  textarea.className = "fb-textarea";
  textarea.name = item.name;
  textarea.rows = item.rows ?? 8;
  if (typeof item.default === "string") textarea.value = item.default;
  if (item.placeholder) textarea.placeholder = item.placeholder;
  editorCol.append(editorLabel, textarea);

  const previewCol = document.createElement("div");
  previewCol.className = "fb-md-editor";
  const previewLabel = document.createElement("div");
  previewLabel.className = "fb-md-editor-label";
  previewLabel.textContent = "预览";
  const preview = document.createElement("div");
  preview.className = "fb-md-preview";
  previewCol.append(previewLabel, preview);

  const update = () => {
    preview.innerHTML = marked.parse(textarea.value || "*(预览将在你输入后出现)*", {
      gfm: true,
      breaks: true,
    });
  };
  textarea.addEventListener("input", update);
  update();

  wrapper.append(editorCol, previewCol);

  return {
    element: wrapper,
    getValue() {
      return textarea.value;
    },
  };
}
