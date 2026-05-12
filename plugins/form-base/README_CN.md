# form-base

为 Claude Code 和 Codex 提供 HTML 交互基座。让智能体可以:

1. **用表单提问** — 单选 / 多选 / 填空 / Markdown 输入,以及颜色 / 字体 / 滑块等样式预览,通过本地 HTML 页面收集;用户填好点击保存,在 CLI 说"我完成了",智能体读到答案继续工作。
2. **渲染长回复** — 当回复内容较长或涉及代码改动时,优先用 HTML 渲染:**业务视角默认显示**,**代码 / 文件改动 / 技术细节默认折叠在 toggle 中**。把用户当非开发者,除非用户明确说"我是开发者"。
3. **注入沟通角色** — 安装后默认注入 **product-manager** 角色:用宏观视角(功能、用户流程、架构、权衡)沟通,不谈代码行号和文件路径。可通过 slash 命令切换到 `developer` / `lawyer` / `null`。角色只影响**回答风格**,不影响智能体如何使用工具、如何执行任务。

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
└── config.json   (role、默认 user_role、响应阈值 等)
```

## Slash 命令(Claude Code)

- `/form-base:role [--product-manager|--developer|--lawyer|--null]` — 切换沟通角色(不带参数 = 显示当前角色)
- `/form-init` — 在当前项目初始化 `.form-base/` 目录
- `/form-list` — 列出活跃 / 已归档表单
- `/form-show <id>` — 重新生成某表单的 URL
- `/form-status` — 当前 form/response 总体状态
- `/response-list` — 列出响应
- `/response-show <id>` — 重新生成某响应的 URL

## 角色(沟通人格)

安装后 SessionStart 钩子会注入一个角色 persona,**只影响**智能体如何回答(用什么词汇、什么角度、详细到什么程度),**不**约束工具调用或任务执行。

| 角色 | 适合场景 | 风格 |
|------|----------|------|
| `product-manager` *(默认)* | 给非技术干系人复盘;产品 / 范围决策 | 谈功能、用户流程、范围、权衡、架构形状。回答里不出现文件路径和行号。 |
| `developer` | 和工程师对线;深度代码工作 | 文件路径、行号、代码块、设计取舍随便上,不做用户向翻译。 |
| `lawyer` | 合规 / 知识产权 / 数据处理 / 合同审查 | 风险与合规视角,暴露模糊点,给建议但不替你下决定。 |
| `null` | 纯 Claude Code 默认风格 | 完全不注入 persona。 |

切换方式:
```bash
/form-base:role --developer
/form-base:role --lawyer
/form-base:role --product-manager
/form-base:role --null            # 清除 persona 注入
/form-base:role                   # 查看当前角色
```

当前角色还会决定 `render_response` 的默认 `user_role`:`developer` → 技术段默认展开;其他 → 技术段默认折叠。Persona 内容存在 [`scripts/personas.json`](scripts/personas.json) — 想加新角色只需往这个文件里追加一项,再在 `commands/role.md` 里加一个 flag 即可。

## Skill 提示(SessionStart 自动注入)

告诉智能体何时用 form / 何时用 response / 何时直接用 CLI 文本,以及当前应该用哪个角色 persona 回答。决策权交给智能体,不强制拦截。

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
