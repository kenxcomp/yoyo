# form-base

为 Claude Code 和 Codex 提供 HTML 交互基座。让智能体可以:

1. **用表单提问** — 单选 / 多选 / 填空 / Markdown 输入,以及颜色 / 字体 / 滑块等样式预览,通过本地 HTML 页面收集;用户填好点击保存,在 CLI 说"我完成了",智能体读到答案继续工作。
2. **渲染长回复** — 当回复内容较长或涉及代码改动时,优先用 HTML 渲染:**业务视角默认显示**,**代码 / 文件改动 / 技术细节默认折叠在 toggle 中**。把用户当非开发者,除非用户明确说"我是开发者"。

跨工具:Claude Code 用 plugin 一键装,Codex 走 MCP 配置。

## 安装

### Claude Code
```bash
/plugin marketplace add kenxcomp/yoyo
/plugin install form-base@yoyo
```
重启会话。Plugin 自动启动 MCP server 并在 SessionStart 注入 skill 提示。

### Codex
先装 bun(`brew install oven-sh/bun/bun`),克隆 marketplace,然后在 `~/.codex/config.toml` 加:

```toml
[mcp_servers.form-base]
command = "bun"
args = ["/abs/path/to/yoyo/plugins/form-base/mcp-server/src/index.ts"]
```

(发布到 npm 后:`command = "bunx"`、`args = ["@kenxyoyo/form-base-mcp"]`。)

## 工作原理

MCP server 暴露两组工具(共 10 个):

**Form 模式(收集输入):**
- `create_form(title, items[], description?, style_suggestions?)` → `{form_id, url}`
- `get_form_status(form_id)` → `{status, submitted_at?}`
- `read_answers(form_id)` → `{answers, submitted_at}`
- `list_forms(status?)`、`archive_form(form_id)`、`reopen_form(form_id)`

**Response 模式(渲染长输出):**
- `render_response(title, business, technical?, user_role?)` → `{response_id, url}`
- `list_responses(status?)`、`archive_response(response_id)`、`reopen_response(response_id)`

Server 内嵌 HTTP 服务,绑定 `localhost:<随机端口>`;`/forms/<id>` 渲染可写表单,`/responses/<id>` 渲染只读响应(含 toggle)。

数据存在 `<cwd>/.form-base/`:
```
.form-base/
├── forms/<id>/{definition.json, state.json, answers.json}
├── responses/<id>/{content.json, meta.json}
└── config.json   (默认 user_role、响应阈值 等)
```

## Slash 命令(Claude Code)

- `/form-init` — 在当前项目初始化 `.form-base/` 目录
- `/form-list` — 列出活跃 / 已归档表单
- `/form-show <id>` — 重新生成某表单的 URL
- `/form-status` — 当前 form/response 总体状态
- `/response-list` — 列出响应
- `/response-show <id>` — 重新生成某响应的 URL

## Skill 提示(SessionStart 自动注入)

告诉智能体何时用 form / 何时用 response / 何时直接用 CLI 文本。决策权交给智能体,不强制拦截。

## 存储与 git

`/form-init` 会在 `.form-base/` 创建 `.gitignore`,默认忽略 `answers.json` / `state.json` / `meta.json`。`definition.json` / `content.json` 可提交,便于 PR 复盘"问了什么、答了什么"。

## 开发

```bash
cd mcp-server
bun install
bun run src/index.ts          # 启动 MCP stdio + 内嵌 HTTP
```

## License

MIT — © kenxcomp 2026
