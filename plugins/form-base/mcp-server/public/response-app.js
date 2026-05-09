// form-base — response runtime. Renders business/technical sections, manages role toggle.

import { marked } from "marked";

const data = window.__RESPONSE_DATA__;
if (!data) {
  document.body.innerHTML = "<main><h1>无效响应数据</h1></main>";
  throw new Error("missing window.__RESPONSE_DATA__");
}

document.getElementById("fb-response-id").textContent = data.id;

// ─── render business ───
const business = document.getElementById("fb-business");
business.innerHTML = marked.parse(data.definition.business || "", {
  gfm: true,
  breaks: true,
});

// ─── render technical ───
const techToggle = document.getElementById("fb-tech-toggle");
const technical = document.getElementById("fb-technical");
const technicalBody = document.getElementById("fb-technical-body");
const filesUl = document.getElementById("fb-files-changed");

const techMarkdown = data.definition.technical;
const filesChanged = data.definition.attachments?.files_changed ?? [];

if (techMarkdown || filesChanged.length) {
  techToggle.hidden = false;
  technicalBody.innerHTML = techMarkdown
    ? marked.parse(techMarkdown, { gfm: true, breaks: true })
    : "";
  if (filesChanged.length) {
    filesUl.hidden = false;
    for (const f of filesChanged) {
      const li = document.createElement("li");
      li.textContent = f;
      filesUl.appendChild(li);
    }
  }
}

// ─── role toggle behaviour ───
const rolePill = document.getElementById("fb-role-pill");
let role = data.effective_role === "developer" ? "developer" : "non-developer";

function applyRole() {
  rolePill.dataset.role = role;
  rolePill.textContent = role === "developer" ? "👨‍💻 开发者视角" : "🧑 非开发者视角";

  const expand = role === "developer";
  technical.hidden = !expand;
  techToggle.classList.toggle("is-open", expand);
  techToggle.setAttribute("aria-expanded", String(expand));
  techToggle.querySelector(".label").textContent = expand
    ? "收起技术细节"
    : "展开技术细节(适合开发者查看)";

  if (expand) highlightAll();
}
applyRole();

rolePill.addEventListener("click", async () => {
  role = role === "developer" ? "non-developer" : "developer";
  applyRole();
  // persist back to server (best-effort; ignore failures)
  fetch(`/responses/${encodeURIComponent(data.id)}/role`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ user_role: role }),
  }).catch(() => {});
});

techToggle.addEventListener("click", () => {
  const wasHidden = technical.hidden;
  technical.hidden = !wasHidden;
  techToggle.classList.toggle("is-open", wasHidden);
  techToggle.setAttribute("aria-expanded", String(wasHidden));
  techToggle.querySelector(".label").textContent = wasHidden
    ? "收起技术细节"
    : "展开技术细节(适合开发者查看)";
  if (wasHidden) highlightAll();
});

// ─── code highlighting (Prism, autoloaded) ───
function highlightAll() {
  if (typeof window.Prism !== "undefined" && window.Prism.highlightAllUnder) {
    window.Prism.highlightAllUnder(technical);
  }
}
