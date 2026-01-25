# Claude 插件市场

一个精选的 Claude Code 实用插件集合。

## 可用插件

| 插件 | 描述 | 标签 |
|------|------|------|
| [claude_md](./plugins/claude_md) | 用于管理 CLAUDE.md 配置的插件，支持自动更新检测 | 配置, 效率, 钩子 |
| [Socratic_Questioning](./plugins/Socratic_Questioning) | 引导 Claude 使用苏格拉底式提问方法，在行动前澄清不明确的需求 | 思维, 方法论, 钩子 |

## 安装方法

### 方法一：添加市场并安装插件（推荐）

首先，将此市场添加到 Claude Code：

```
/plugin marketplace add kenxcomp/yoyo
```

然后安装所需的插件：

```
/plugin install claude_md@kenxcomp-yoyo
/plugin install Socratic_Questioning@kenxcomp-yoyo
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
claude --plugin-dir ./yoyo/plugins/claude_md
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

### claude_md 插件

`claude_md` 插件提供工作会话期间的重大更新自动检测功能。主要特性：

- **Stop 钩子**：自动评估变更是否需要更新 CLAUDE.md
- **智能检测**：使用 LLM 识别代码架构、功能和配置变更
- **更新技能**：引导用户更新或创建 CLAUDE.md

### 重大更新判断标准

- **代码架构变更**：新增模块、重构代码结构、修改核心逻辑
- **功能性变更**：新增功能、删除功能、修改 API 接口
- **配置/规范变更**：修改项目配置、编码规范、依赖更新

### Socratic_Questioning 插件

`Socratic_Questioning` 插件使用苏格拉底式提问方法，确保在行动前充分理解用户需求。主要特性：

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

## 贡献指南

1. Fork 本仓库
2. 在 `plugins/` 目录下创建你的插件目录
3. 遵循标准插件结构
4. 提交 Pull Request

## 许可证

MIT
