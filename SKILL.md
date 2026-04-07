---
name: daily-report
description: >
  AI 驱动的飞书日报自动生成工具。从多源数据采集（飞书日历、视频会议纪要、IM 消息、
  AI 对话记录、工作区文件变更）到飞书文档创建发布，全流程自动化。
  当用户说「写日报」「帮我写日报」「生成今天的日报」「补X月X日的日报」「写一份昨天的日报」时使用。
  依赖 lark-cli。首次使用需运行 setup.sh 初始化配置。
---

# 日报自动化

AI 编排的飞书日报生成工具。核心价值：把「打开飞书 → 新建文档 → 回忆今天做了什么 → 手写 → 授权」压缩为一句「写日报」。

## 前置条件

- `lark-cli` 已安装且认证有效
- 已运行过 `setup.sh` 生成配置文件 `~/.config/daily-report/config`

### 首次使用检查

如果用户第一次说「写日报」，先检查：

1. `lark-cli` 是否可用：`command -v lark-cli`
2. 配置文件是否存在：`~/.config/daily-report/config`
3. 认证是否有效：`lark-cli auth status`

缺失任何一项，引导用户运行：

```bash
bash ~/.agents/skills/daily-report/scripts/setup.sh
```

setup 会自动检测已安装的 Agent 并配置兼容性。

## 完整工作流

用户说「写日报」时，按以下步骤执行：

### Step 1: 数据采集

运行脚本收集当天元数据：

```bash
bash ~/.agents/skills/daily-report/scripts/daily-report.sh collect [日期]
```

输出 JSON 包含：日历事件、视频会议+纪要链接、工作区文件变更、AI 对话记录摘要、IM 消息、GitLab commit/MR（需配置）、非工作日草稿（pending_days）。

如指定日期（如「补昨天的日报」），传入 `YYYY-MM-DD` 格式日期参数。

### Step 2: IM 补充

如果具备 IM 搜索权限，使用 `lark-cli im +messages-search` 补充飞书群聊中的关键信息。重点关注：口径变化、决策结论、Action Items。

### Step 3: 读对话理解工作

collect 输出的 conversations 字段包含当天各 Agent 的对话主题摘要。读取这些对话内容，理解用户当天的实际工作推进情况。过滤掉非工作内容（个人事务、闲聊等）。

### Step 4: 敏感信息过滤

**以下内容直接禁止写入共享日报**（不做抽象表达，直接删除）：

- 人事调整、淘汰、替换、晋升、降级
- 对具体同事的能力评价、适配度判断
- 未公开的组织变化、汇报线变化
- 管理层私下讨论的敏感事项
- 未公开的资源倾斜、预算、HC
- 只适合单独向 Leader 汇报的内容

判断规则：只要同事看到会引发不必要联想，或被 Bot 扩散有风险，就不写。

### Step 5: 整理草稿并呈现

按以下结构整理日报，呈现给用户确认：

**固定章节**（每天都写）：

| 章节 | 内容 |
|------|------|
| 今日会议 | 参加的会议 + 结论 + 智能纪要链接；无会议写「无会议」 |
| 今日进展 | 今天推进了什么、产出了什么、准备了什么 |
| 下一步 | 明天最重要的 1-3 件事 |

**按需章节**（有内容才写，没有就不出现）：

| 章节 | 什么时候写 |
|------|------|
| 关键信息 | 今天有新口径、新反馈、新背景信息 |
| 会议 / IM 同步 | 有需要同步给团队的公开信息 |
| 判断 / 待确认 | 有待拍板的决策点 |
| 风险 / 卡点 | 真的有阻塞 |

呈现草稿后，问用户：「有什么需要补充或修改的吗？」

### GitLab 代码活动（可选）

如果用户配置了 `GITLAB_HOST` 和 `GITLAB_TOKEN`（在 `~/.config/daily-report/config` 中），collect 输出的 JSON 会包含 `gitlab` 字段（commit、MR authored、MR reviewed）。生成日报时自动渲染为「代码提交」「MR 动态」「Code Review」小节。

未配置时 `gitlab.error` 为 `"未配置"`，日报中不出现 GitLab 相关内容，不影响其他功能。

### 非工作日行为

`auto` 命令内置了非工作日判断（支持法定假日配置、公共 API fallback、星期兜底）：

- **非工作日**：静默采集数据存到 `~/.daily-report/pending/YYYY-MM-DD.json`，不创建飞书文档
- **工作日**：正常生成日报，并自动合并之前积攒的非工作日草稿，渲染为「假期/周末推进」章节
- `auto` 支持指定日期参数（如 `auto 2026-04-05`）用于补生成

清除草稿：`bash daily-report.sh clear-pending`

### Step 6: 创建飞书文档

用户确认后，通过 stdin 传入 markdown 内容创建文档：

```bash
echo "$markdown_content" | bash ~/.agents/skills/daily-report/scripts/daily-report.sh create [--title "标题"]
```

脚本自动：创建飞书文档 → 授予权限列表中的用户 view 权限 → 返回文档链接。

### Step 7: 发布（可选）

用户说「发布日报」时，将草稿从个人空间移到公共目录：

```bash
bash ~/.agents/skills/daily-report/scripts/daily-report.sh publish <wiki_token>
```

## 飞书文档更新规则

- **首次创建**：使用 `create` 命令
- **用户未在飞书端修改过**：可用 `lark-cli docs +update --mode overwrite`
- **用户已在飞书端修改过**：只用 `--mode append` 或 `--mode replace_range --selection-by-title "## 章节名"`
- **不确定**：先问用户

## 日报原则

- 忠实记录，不美化不贬低
- 记录「今天事情往前推进了什么」，不要求每天都有明确产出
- 不抄日程表（日报记的是做了什么，不是排了什么）
- 不堆文件名（要说清楚做了什么、产出了什么）
- 默认按「同事 + Leader + Bot 都会看到」来写

完整 SOP 见 `references/sop.md`。

## 团队日报摘要

用户说「看看大家今天做了什么」「团队日报摘要」「今天有什么跟我相关的」时触发。

### 前置条件

config 中需要配置 `TEAM_WIKI_NODE` 和 `TEAM_SPACE_ID`。未配置时引导用户重新运行 setup 或手动编辑 config。

### 工作流

1. 运行脚本读取所有人的日报：

```bash
bash ~/.agents/skills/daily-report/scripts/daily-report.sh digest [日期]
```

输出 JSON 包含：用户身份（name + role）、关注列表、所有人的日报内容。

2. 按两个层级处理日报内容：
   - **关注列表的人**（`watch_list`）：完整摘要，一定出现在结果中
   - **其他所有人**：AI 自行判断是否与用户相关，判断依据包括：
     - 日报中提到了用户的名字
     - 涉及用户负责的业务（从 `my_role` 推断）
     - 有需要用户配合或知晓的事项
     - 与用户当前在做的项目相关

3. 生成摘要，按以下结构输出：

```markdown
## YYYY-MM-DD 团队日报摘要

### 重点关注
- **{人名}**：{完整摘要}

### 与你相关
- **{人名}**：{相关条目}

### 其他动态
（用户可以说「展开全部」查看所有人的日报）
```

### 注意事项

- digest 输出的 JSON 中包含 `user.role` 字段，即使没有 workspace 规则也能判断相关性
- 跳过用户自己的日报（按 `USER_NAME` 匹配）
- 日报标题格式不统一（有 `2026-04-02` 也有 `2026-4-2`），脚本已做兼容
- 如果某人当天没有日报（节点下没有匹配日期的文档），直接跳过，不报错
