# 日报自动化

对 AI 说「写日报」，自动生成飞书日报。

## 安装

```bash
git clone https://github.com/LawrenceChiu95/daily-report-skill ~/.agents/skills/daily-report
bash ~/.agents/skills/daily-report/scripts/setup.sh
```

setup 提供两种模式：
- **快速模式**（默认）：全部用默认值，10 秒装完，立刻可用
- **完整模式**：逐项配置，解锁团队摘要、IM 私聊采集、定时触发等

所有配置项之后都可以随时编辑 `~/.config/daily-report/config` 修改。

## 功能

| 说什么 | 做什么 |
|--------|--------|
| 「写日报」 | 自动采集飞书日历、会议纪要、IM、AI 对话记录、文件变更，生成飞书日报 |
| 「看看大家今天做了什么」 | 读取团队所有人的日报，提取跟你相关的内容（需在完整模式中配置） |

## 数据采集范围

| 数据源 | 说明 | 是否需要额外配置 |
|--------|------|:---:|
| 飞书日历 | 今天参加了什么会 | 否 |
| 飞书视频会议纪要 | 会议结论和纪要链接 | 否 |
| 飞书 IM | 群聊消息（默认），私聊可选 | 私聊需在完整模式开启 |
| AI 对话记录 | Cursor / Codex / Claude Code / OpenClaw | 否 |
| 工作区文件变更 | 当天改了哪些 .md 文件 | 需配置 WORKSPACE_DIR |

## 支持的 AI Agent

| Agent | 兼容方式 |
|-------|---------|
| Cursor | 自动发现（通过 `~/.agents/skills/`） |
| Codex | 自动发现（通过 `~/.agents/skills/`） |
| Claude Code | setup 自动创建 symlink |
| OpenClaw | setup 自动生成指令文件 |

setup 自动检测已安装的 Agent，只配置存在的，跳过不存在的。

## 配置文件

`~/.config/daily-report/config`，由 setup 生成。所有配置项都有注释说明，留空即跳过对应功能。

## 更新

```bash
cd ~/.agents/skills/daily-report && git pull
```

## 详细指南

```bash
cat ~/.agents/skills/daily-report/references/quickstart.md
```
