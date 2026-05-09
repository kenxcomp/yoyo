// Single-line text input.

export function renderText(item) {
  const input = document.createElement("input");
  input.className = "fb-input";
  input.type = "text";
  input.name = item.name;
  if (item.placeholder) input.placeholder = item.placeholder;
  if (typeof item.default === "string") input.value = item.default;

  return {
    element: input,
    getValue() {
      return input.value;
    },
  };
}
