# 日报自动化 · 快速指南

对 AI 说「写日报」，自动生成飞书日报。

## 它会读什么

| 数据源 | 说明 | 是否需要额外授权 |
|--------|------|:---:|
| 飞书日历 | 今天参加了什么会 | 否 |
| 飞书视频会议纪要 | 会议结论和纪要链接 | 否 |
| 飞书 IM | 你在群里发的消息 | 是（登录时加 `--domain im`） |
| AI 对话记录 | Cursor / Codex / Claude Code / Naomi 当天的对话主题 | 否（读本地文件） |
| 工作区文件变更 | 当天改了哪些 .md 文件（需配置 WORKSPACE_DIR，未配置则跳过） | 否（读本地文件） |

## 它会产出什么

一份飞书文档，结构如下：

- **今日会议** — 参加的会议 + 结论 + 智能纪要链接
- **今日进展** — 今天推进了什么、产出了什么
- **下一步** — 明天最重要的 1-3 件事
- （按需）关键信息、会议/IM 同步、判断/待确认、风险/卡点

AI 会先给你看草稿，确认后才创建文档。敏感信息（人事、组织变动等）会自动过滤，不写入共享日报。

## 使用方式

| 方式 | 怎么做 | 适合场景 |
|------|--------|---------|
| 对 AI 说话 | 「写日报」「补昨天的日报」 | 日常使用（推荐） |
| 终端命令 | `bash ~/.agents/skills/daily-report/scripts/daily-report.sh auto` | 快速打底稿 |
| 查看原始数据 | `bash ~/.agents/skills/daily-report/scripts/daily-report.sh collect` | 调试 |

## 配置文件

位置：`~/.config/daily-report/config`

可修改的配置项：
- `WORKSPACE_DIR` — 工作区路径（用于提取文件变更）
- `PERMISSION_LIST` — 日报创建后自动授权的 open_id 列表
- `REPORT_FOLDER` — 日报创建到哪个飞书文件夹

查同事的 open_id：`lark-cli contact +search "姓名"`
