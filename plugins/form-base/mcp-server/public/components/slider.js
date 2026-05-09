// Numeric slider with live value readout (supports a unit suffix).

export function renderSlider(item) {
  const wrapper = document.createElement("div");
  wrapper.style.display = "flex";
  wrapper.style.alignItems = "center";
  wrapper.style.gap = "16px";

  const input = document.createElement("input");
  input.type = "range";
  input.min = String(item.min ?? 0);
  input.max = String(item.max ?? 100);
  input.step = String(item.step ?? 1);
  input.style.flex = "1";
  input.style.accentColor = "var(--primary)";
  const initial =
    typeof item.default === "number"
      ? item.default
      : (Number(input.min) + Number(input.max)) / 2;
  input.value = String(initial);

  const readout = document.createElement("div");
  readout.style.minWidth = "84px";
  readout.style.textAlign = "right";
  readout.style.fontFamily = "var(--font-mono)";
  readout.style.fontSize = "14px";
  readout.style.color = "var(--text-muted)";

  const update = () => {
    const unit = item.unit ?? "";
    readout.textContent = `${input.value}${unit ? " " + unit : ""}`;
  };
  input.addEventListener("input", update);
  update();

  wrapper.append(input, readout);

  return {
    element: wrapper,
    getValue() {
      const n = Number(input.value);
      return Number.isFinite(n) ? n : null;
    },
  };
}
