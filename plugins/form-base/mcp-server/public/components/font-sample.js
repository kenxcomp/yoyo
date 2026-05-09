// Font sample selector — radio cards each rendered in their own font with a sample sentence.

export function renderFont(item) {
  const wrapper = document.createElement("div");
  wrapper.style.display = "grid";
  wrapper.style.gridTemplateColumns = "repeat(auto-fill, minmax(220px, 1fr))";
  wrapper.style.gap = "10px";

  const SAMPLE = "The quick brown fox 你好,世界 — 1234567890";
  const samples = Array.isArray(item.samples) && item.samples.length > 0 ? item.samples : [
    "Inter, system-ui, sans-serif",
    "Roboto, system-ui, sans-serif",
    '"JetBrains Mono", monospace',
    '"Source Han Sans SC", "Noto Sans SC", sans-serif',
  ];

  const inputs = [];
  for (const fontFamily of samples) {
    const id = `fb-font-${fontFamily.replace(/[^a-z0-9]/gi, "-")}`;
    const card = document.createElement("label");
    card.htmlFor = id;
    card.style.display = "block";
    card.style.padding = "14px 16px";
    card.style.background = "var(--surface-2)";
    card.style.border = "1px solid var(--border)";
    card.style.borderRadius = "10px";
    card.style.cursor = "pointer";
    card.style.transition = "border-color 120ms ease, background 120ms ease";

    const top = document.createElement("div");
    top.style.display = "flex";
    top.style.alignItems = "center";
    top.style.gap = "8px";
    top.style.marginBottom = "6px";

    const input = document.createElement("input");
    input.type = "radio";
    input.name = item.name;
    input.value = fontFamily;
    input.id = id;
    input.style.accentColor = "var(--primary)";
    if (item.default === fontFamily) input.checked = true;

    const family = document.createElement("span");
    family.style.fontSize = "12px";
    family.style.fontFamily = "var(--font-mono)";
    family.style.color = "var(--text-faint)";
    family.textContent = fontFamily.split(",")[0].replace(/['"]/g, "");

    top.append(input, family);

    const sample = document.createElement("div");
    sample.style.fontFamily = fontFamily;
    sample.style.fontSize = "16px";
    sample.style.lineHeight = "1.4";
    sample.textContent = SAMPLE;

    card.append(top, sample);
    wrapper.appendChild(card);
    inputs.push(input);

    card.addEventListener("click", () => {
      // visual highlight
      wrapper.querySelectorAll("label").forEach((l) => {
        l.style.borderColor = "var(--border)";
        l.style.background = "var(--surface-2)";
      });
      card.style.borderColor = "var(--primary)";
      card.style.background = "var(--primary-soft)";
    });
  }

  // initial highlight if default
  const checked = inputs.find((i) => i.checked);
  if (checked) checked.parentElement.click();

  return {
    element: wrapper,
    getValue() {
      const sel = inputs.find((i) => i.checked);
      return sel ? sel.value : null;
    },
  };
}
