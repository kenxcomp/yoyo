// Checkbox (multi-choice) component.

export function renderCheckbox(item) {
  const wrapper = document.createElement("div");
  wrapper.className = "fb-options";
  wrapper.setAttribute("role", "group");

  const defaults = new Set(Array.isArray(item.default) ? item.default : []);
  const inputs = [];

  for (const opt of item.options ?? []) {
    const optionId = `fb-${item.name}-${opt.value}`;
    const label = document.createElement("label");
    label.className = "fb-option";
    label.htmlFor = optionId;

    const input = document.createElement("input");
    input.type = "checkbox";
    input.name = item.name;
    input.value = opt.value;
    input.id = optionId;
    if (defaults.has(opt.value)) input.checked = true;

    const span = document.createElement("span");
    span.className = "fb-option-label";
    span.textContent = opt.label;

    label.append(input, span);
    wrapper.append(label);
    inputs.push(input);
  }

  return {
    element: wrapper,
    getValue() {
      return inputs.filter((i) => i.checked).map((i) => i.value);
    },
  };
}
