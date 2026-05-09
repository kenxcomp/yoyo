// Color picker — native <input type="color"> + a hex text field, plus a live swatch preview.

export function renderColor(item) {
  const wrapper = document.createElement("div");
  wrapper.style.display = "flex";
  wrapper.style.alignItems = "center";
  wrapper.style.gap = "12px";

  const swatch = document.createElement("div");
  swatch.style.width = "40px";
  swatch.style.height = "40px";
  swatch.style.borderRadius = "8px";
  swatch.style.border = "1px solid var(--border-strong)";

  const colorInput = document.createElement("input");
  colorInput.type = "color";
  colorInput.style.width = "44px";
  colorInput.style.height = "32px";
  colorInput.style.border = "1px solid var(--border-strong)";
  colorInput.style.borderRadius = "6px";
  colorInput.style.padding = "0";
  colorInput.style.cursor = "pointer";

  const hex = document.createElement("input");
  hex.type = "text";
  hex.className = "fb-input";
  hex.style.flex = "0 1 140px";
  hex.style.fontFamily = "var(--font-mono)";
  hex.maxLength = 9;

  const initial = typeof item.default === "string" ? item.default : "#3b82f6";
  setBoth(initial);

  function setBoth(value) {
    const v = normalizeHex(value);
    hex.value = v;
    colorInput.value = v.length >= 7 ? v.slice(0, 7) : "#000000";
    swatch.style.background = v;
  }

  colorInput.addEventListener("input", () => setBoth(colorInput.value));
  hex.addEventListener("input", () => {
    swatch.style.background = hex.value;
    if (/^#[0-9a-fA-F]{6}$/.test(hex.value)) colorInput.value = hex.value;
  });

  wrapper.append(swatch, colorInput, hex);

  return {
    element: wrapper,
    getValue() {
      return hex.value;
    },
  };
}

function normalizeHex(v) {
  if (!v) return "#000000";
  v = v.trim();
  if (!v.startsWith("#")) v = "#" + v;
  return v;
}
