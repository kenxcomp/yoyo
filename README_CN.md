# Claude 插件市场

一个精选的 Claude Code 实用插件集合。

## 可用插件

| 插件 | 描述 | 标签 |
|------|------|------|
| [claude_md](./plugins/claude_md) | 用于管理 CLAUDE.md 配置的插件 | 配置, 效率 |
| [Socratic_Questioning](./plugins/Socratic_Questioning) | 引导 Claude 使用苏格拉底式提问方法的插件 | 思维, 方法论 |

## 安装方法

### 方法一：克隆整个市场

```bash
git clone https://github.com/kennethx/claude-plugin-marketplace.git
```

### 方法二：下载单个插件

进入插件目录，按照插件的安装说明进行操作。

## 插件结构

每个插件遵循以下标准结构：

```
plugin-name/
├── .claude-plugin/
│   └── plugin.json      # 插件元数据和配置
├── commands/            # 自定义命令
├── agents/              # 自定义代理
├── skills/              # 自定义技能
└── README.md            # 插件文档
```

## 贡献指南

1. Fork 本仓库
2. 在 `plugins/` 目录下创建你的插件目录
3. 遵循标准插件结构
4. 提交 Pull Request

## 许可证

MIT
