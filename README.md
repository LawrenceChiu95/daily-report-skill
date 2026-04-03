# 日报自动化

对 AI 说「写日报」，自动生成飞书日报。

## 安装

```bash
git clone https://github.com/LawrenceChiu95/daily-report-skill ~/.agents/skills/daily-report
bash ~/.agents/skills/daily-report/scripts/setup.sh
```

setup 会自动完成：飞书 CLI 安装、认证、日报文件夹配置、权限列表、Agent 兼容配置。

## 功能

| 说什么 | 做什么 |
|--------|--------|
| 「写日报」 | 自动采集飞书日历、会议纪要、IM、AI 对话记录、文件变更，生成飞书日报 |
| 「看看大家今天做了什么」 | 读取团队所有人的日报，提取跟你相关的内容 |

## 数据采集范围

- 飞书日历和视频会议纪要
- 飞书 IM 消息（群聊默认，私聊可选）
- AI 对话记录（Cursor / Codex / Claude Code）
- 工作区文件变更

## 支持的 AI Agent

Cursor、Codex、Claude Code、OpenClaw/Naomi — setup 自动检测已安装的 Agent 并配置。

## 配置文件

`~/.config/daily-report/config`，由 setup 生成，可手动编辑。

详细使用指南见 `references/quickstart.md`。
