# Claude 插件市场

一个精选的 Claude Code 实用插件集合。

## 可用插件

| 插件 | 描述 | 标签 |
|------|------|------|
| [claude-md](./plugins/claude-md) | 用于管理 CLAUDE.md 配置的插件，支持自动更新检测 | 配置, 效率, 钩子 |
| [darwin](./plugins/darwin) | 自动错误修复插件，将运行时错误交给专用代理处理，保留主对话上下文 | 错误处理, 代理, 自动化 |
| [plan-guardian](./plugins/plan-guardian) | 计划审查工作流插件，确保计划在执行前经过严格审查 | 规划, 审查, 代理, 质量 |
| [socratic-questioning](./plugins/socratic-questioning) | 引导 Claude 使用苏格拉底式提问方法，在行动前澄清不明确的需求 | 思维, 方法论, 钩子 |
| [bug-fix-testcase](./plugins/bug-fix-testcase) | 在修复 Bug 时自动在隔离的 git worktree 中生成子代理编写回归测试用例 | 测试, 修复, 回归, 代理, worktree |

## 安装方法

### 方法一：添加市场并安装插件（推荐）

首先，将此市场添加到 Claude Code：

```
/plugin marketplace add kenxcomp/yoyo
```

然后安装所需的插件：

```
/plugin install claude-md@kenxcomp-yoyo
/plugin install darwin@kenxcomp-yoyo
/plugin install plan-guardian@kenxcomp-yoyo
/plugin install socratic-questioning@kenxcomp-yoyo
/plugin install bug-fix-testcase@kenxcomp-yoyo
```

### 方法二：交互式界面

使用交互式插件管理器：

```
/plugin
```

进入 **Marketplaces** 标签页 → 添加此市场 → 切换到 **Discover** 标签页 → 安装所需插件。

### 方法三：本地开发

克隆仓库并本地加载插件进行开发/测试：

```bash
git clone https://github.com/kenxcomp/yoyo.git
claude --plugin-dir ./yoyo/plugins/claude-md
```

> **注意**: 需要 Claude Code 1.0.33 或更高版本。使用 `claude --version` 检查版本。

## 插件结构

每个插件遵循以下标准结构：

```
plugin-name/
├── .claude-plugin/
│   └── plugin.json      # 插件元数据和配置
├── hooks/               # 钩子定义
├── commands/            # 自定义命令
├── agents/              # 自定义代理
├── skills/              # 自定义技能
└── README.md            # 插件文档
```

## 插件功能

### claude-md 插件

`claude-md` 插件提供工作会话期间的重大更新自动检测功能。主要特性：

- **Stop 钩子**：自动评估变更是否需要更新 CLAUDE.md
- **智能检测**：使用 LLM 识别代码架构、功能和配置变更
- **更新技能**：引导用户更新或创建 CLAUDE.md

### 重大更新判断标准

- **代码架构变更**：新增模块、重构代码结构、修改核心逻辑
- **功能性变更**：新增功能、删除功能、修改 API 接口
- **配置/规范变更**：修改项目配置、编码规范、依赖更新

### darwin 插件

`darwin` 插件通过将运行时错误交给专用代理处理，实现自动错误修复。主要特性：

- **SessionStart 钩子**：在会话启动时注入技能感知
- **Auto-Fixer 技能**：遇到运行时错误时自动触发（Python、Bash、构建、测试失败）
- **Error-Fixer 代理**：分析错误、实施修复、验证方案并返回摘要
- **Config-Fixer 代理**：记录解决方案并更新配置以供未来参考

**支持的错误类型：**
- 文件/路径错误（FileNotFoundError、目录缺失）
- 导入错误（ModuleNotFoundError、依赖缺失）
- 语法错误（Python 语法错误、JSON 解析错误）
- 运行时错误（TypeError、AttributeError）
- 构建错误（npm、cargo、make、gradle 失败）
- 测试失败（pytest、jest、vitest）
- 权限错误

### plan-guardian 插件

`plan-guardian` 插件强制在执行前对计划进行严格审查。主要特性：

- **SessionStart 钩子**：在每个会话启动时注入计划模式规则作为 additionalContext
- **ExitPlanMode 钩子**：在计划审查代理批准计划之前阻止退出计划模式
- **EnterPlanMode 钩子**：进入新的规划会话时清除之前的审查状态
- **Plan-Reviewer 代理**：根据 8 项质量标准评估计划（边界情况、异常场景、风格一致性、逻辑一致性、验证步骤、不明确意图、语义歧义、用户意图）
- **/plan-review 技能**：随时手动触发计划审查

**审查工作流程：**
1. 进入计划模式 → 清除之前的审查状态
2. 将计划写入 `.plan-review/yoplan.md`
3. 启动 plan-reviewer 代理 → 评估所有 8 项标准
4. 如果通过，解除 ExitPlanMode 阻塞
5. 如果被阻塞，重新运行 plan-reviewer 并重试

### socratic-questioning 插件

`socratic-questioning` 插件使用苏格拉底式提问方法，确保在行动前充分理解用户需求。主要特性：

- **UserPromptSubmit 钩子**：评估每个用户提示的清晰度
- **多轮对话**：每次只问一个聚焦的问题，直到需求明确
- **双语支持**：自动检测并使用用户的语言（中文/英文）回复
- **不做推断**：从不假设或猜测，始终通过提问确认

**清晰度评估标准：**
- 具体性（模糊词汇是否有定义？）
- 上下文（是否提供了范围/环境？）
- 需求（预期结果是否明确？）
- 假设（是否识别了隐含信念？）
- 约束（是否说明了限制条件？）

### bug-fix-testcase 插件

`bug-fix-testcase` 插件在修复 Bug 时生成专用代理编写回归测试。主要特性：

- **SessionStart 钩子**：在会话启动时注入技能感知
- **UserPromptSubmit 钩子**：自动检测修复 Bug 的关键词（fix bug、bugfix、hotfix、patch、regression、defect、修复）
- **Bug-Fix 技能**：使用 Bug 上下文协调 testcase-writer 代理调用
- **Testcase-Writer 代理**（opus）：在隔离的 git worktree 中编写回归测试

**支持的测试框架：**
- Python (pytest)、JavaScript (Jest, Vitest)、TypeScript、Rust (cargo test)、Go (go test)、Ruby (RSpec)、Java (JUnit)

**Worktree 隔离：**
- 测试在 `.bug-fix-testcase/worktree-<timestamp>` 中的独立分支上编写
- 通过 `git cherry-pick`、`git checkout -- <file>` 或 `git merge` 合并
- 使用 `git worktree remove <path>` 清理

## 贡献指南

1. Fork 本仓库
2. 在 `plugins/` 目录下创建你的插件目录
3. 遵循标准插件结构
4. 提交 Pull Request

## 许可证

MIT
