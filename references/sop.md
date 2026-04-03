# 日报 SOP

## 日报结构

固定章节（每天都写）：

| 章节 | 内容 | 来源 |
|------|------|------|
| 今日会议 | 参加的会议 + 结论 + 智能纪要链接；无会议写「无会议」 | 飞书 VC 搜索 + 会议纪要 API |
| 今日进展 | 今天推进了什么、产出了什么、准备了什么 | AI 读取对话记录 + 文件变更 |
| 下一步 | 明天最重要的 1-3 件事 | AI 从对话中识别 |

按需章节（有内容才写，没有就不出现）：

| 章节 | 什么时候写 | 来源 |
|------|------|------|
| 关键信息 | 今天有新口径、新反馈、新背景信息 | 对话记录 + 飞书 IM + 会议纪要 |
| 会议 / IM 同步 | 有需要同步给团队的公开信息 | 飞书 VC / IM |
| 判断 / 待确认 | 有待拍板的决策点 | AI 从对话中提取 |
| 风险 / 卡点 | 真的有阻塞 | AI 从对话中提取 |

---

## 三种触发方式

### A. AI Agent 交互式（推荐，最高质量）

对 AI 说「写日报」或「写一份 X 月 X 日的日报」。

AI 自动执行：
1. `bash ~/.agents/skills/daily-report/scripts/daily-report.sh collect [日期]`
2. 如有 IM 搜索权限，再补充飞书 IM 里的关键信息
3. 读取对话内容，理解当天实际工作，过滤非工作对话
4. **先做敏感信息筛除**，再整理公开版日报草稿
5. 呈现草稿，问「有什么需要补充的吗？」
6. 确认后创建飞书文档 + 自动授权

**这是唯一能写出高质量日报的方式**——AI 能读对话内容、理解上下文、区分主次。

### B. 终端一键生成

```bash
bash ~/.agents/skills/daily-report/scripts/daily-report.sh auto              # 今日日报
bash ~/.agents/skills/daily-report/scripts/daily-report.sh auto --draft       # 草稿模式
bash ~/.agents/skills/daily-report/scripts/daily-report.sh collect 2026-04-01 # 只采集不创建
```

限制：auto 模式只生成公开版骨架（会议 + 进展 + 待办），没有 AI 内容理解。适合快速打底稿。

### C. Naomi/OpenClaw

对 Naomi 说「写日报」。Naomi 按 memory 中的指令执行类似流程。

限制：Naomi 只能读飞书数据和自己的记忆，无法读 Cursor/Codex/Claude Code 的对话记录。

---

## 首次配置

```bash
bash ~/.agents/skills/daily-report/scripts/setup.sh
```

按提示完成：飞书认证、选择日报文件夹、配置权限列表。setup 自动检测已安装的 Agent 并配置兼容性。

配置文件位置：`~/.config/daily-report/config`

---

## 不放什么

- 不抄日程表——日报记的是做了什么，不是排了什么
- 不放非工作对话（个人投资、生活、朋友私事）
- 不堆文件名——要说清楚做了什么、产出了什么
- 不把敏感事项「抽象改写后」塞进日报——敏感事项直接不写

---

## 敏感信息红线

以下内容**直接禁止写入共享日报**：

- 人事调整、淘汰、替换、晋升、降级
- 对具体同事的能力评价、适配度判断、优先级排序
- 未公开的组织变化、汇报线变化、团队 restructuring
- 管理层私下讨论的敏感事项
- 未公开的资源倾斜、预算、HC、裁撤计划
- 只适合一对一向 Leader 汇报的内容

判断规则：

1. 这件事是否已经在团队可见范围公开？
2. 如果被同事看到，会不会引发不必要联想？
3. 如果被 Bot 汇总扩散，会不会有风险？
4. 这件事是否更适合单独向 Leader 汇报？

只要 2/3/4 有一个答案是「会」或「是」，就直接不写。

---

## 补权限人员

编辑 `~/.config/daily-report/config`，在 `PERMISSION_LIST` 中添加 open_id（空格分隔）。查 open_id：

```bash
lark-cli contact +search "姓名"
```

---

## 已知限制

| 限制 | 原因 | 规避方式 |
|------|------|---------|
| auto 模式日报质量低 | shell 脚本不理解内容，只能列文件名 | 用 AI Agent 交互式模式 |
| 文件变更可能不准 | 基于 stat 时间戳，多次修改只记最后一次日期 | AI 交叉验证对话记录 |
| 飞书 IM 需额外授权 | `im:message:search` scope 需在 lark-cli 登录时单独申请 | 登录时加 `--domain im`，或手动补充重要对话要点 |
| 云端/飞书 Bot 无法采集本地数据 | 云端 OpenClaw 或飞书 Bot 跑的是远端 shell，无法访问本机的 Agent 对话记录和文件变更 | 本地部署的 OpenClaw 不受此限制；云端/Bot 部署只能用飞书 API 采集，对话记录覆盖受限 |
