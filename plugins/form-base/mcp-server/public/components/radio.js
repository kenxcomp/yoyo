// Radio (single-choice) component.

export function renderRadio(item) {
  const wrapper = document.createElement("div");
  wrapper.className = "fb-options";
  wrapper.setAttribute("role", "radiogroup");

  const inputs = [];
  for (const opt of item.options ?? []) {
    const optionId = `fb-${item.name}-${opt.value}`;
    const label = document.createElement("label");
    label.className = "fb-option";
    label.htmlFor = optionId;

    const input = document.createElement("input");
    input.type = "radio";
    input.name = item.name;
    input.value = opt.value;
    input.id = optionId;
    if (item.default === opt.value) input.checked = true;

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
      const checked = inputs.find((i) => i.checked);
      return checked ? checked.value : null;
    },
  };
}
