#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$SKILL_DIR/scripts"
CONF_DIR="$HOME/.config/daily-report"
CONF_FILE="$CONF_DIR/config"
REPORT_SCRIPT="$SCRIPT_DIR/daily-report.sh"

echo "=== 日报自动化 · 初始化 ==="
echo ""
echo "选择安装模式："
echo "  1) 快速模式 — 全部用默认值，10 秒装完，之后随时改配置"
echo "  2) 完整模式 — 逐项配置，解锁团队摘要、IM 私聊、定时触发等"
echo ""
read -rp "选择 [1/2，默认 1]: " setup_mode
setup_mode="${setup_mode:-1}"
echo ""

# --- 前置依赖 ---

if ! command -v lark-cli &>/dev/null; then
    echo "lark-cli 未安装，尝试自动安装..."
    if command -v npm &>/dev/null; then
        npm install -g lark-cli
        if ! command -v lark-cli &>/dev/null; then
            echo "错误：安装失败，请手动运行: npm install -g lark-cli"
            exit 1
        fi
    else
        echo "错误：npm 未安装，无法自动安装 lark-cli"
        echo "请先安装 Node.js（https://nodejs.org），然后运行: npm install -g lark-cli"
        exit 1
    fi
fi
echo "✓ lark-cli 已安装"

auth_status=$(lark-cli auth status 2>&1) || true
token_status=$(echo "$auth_status" | jq -r '.tokenStatus // "unknown"' 2>/dev/null)
if [[ "$token_status" != "valid" ]]; then
    echo "需要飞书认证，正在发起授权..."
    lark-cli auth login --domain calendar,task,doc,drive,contact
    auth_status=$(lark-cli auth status 2>&1)
fi

user_name=$(echo "$auth_status" | jq -r '.userName // ""')
user_open_id=$(echo "$auth_status" | jq -r '.userOpenId // ""')
echo "✓ 已认证为: $user_name ($user_open_id)"

# --- 个性化配置（全部可选） ---

workspace_dir=""
report_folder=""
permission_list=""
im_include_p2p="false"
team_wiki_node=""
team_space_id=""
watch_list=""
my_role=""
install_cron="n"

if [[ "$setup_mode" == "2" ]]; then

echo ""
echo "--- 1/6 工作区路径（可选）---"
echo "用于提取工作区文件变更记录。"
read -rp "工作区路径 [留空跳过]: " workspace_input
workspace_dir="${workspace_input:-}"

echo ""
echo "--- 2/6 日报存放位置（可选）---"
echo "日报默认创建在飞书个人空间根目录。"
echo "如需指定文件夹，输入飞书文件夹 URL 或 token。"
read -rp "文件夹 [留空用默认位置]: " folder_input
report_folder=""
if [[ -n "$folder_input" ]]; then
    if [[ "$folder_input" == *"/drive/folder/"* ]]; then
        report_folder=$(echo "$folder_input" | sed 's|.*/drive/folder/||;s|[?#].*||')
    else
        report_folder="$folder_input"
    fi
    echo "✓ 文件夹 token: $report_folder"
fi

echo ""
echo "--- 3/6 权限自动授予（可选）---"
echo "日报创建后自动给谁授予阅读权限？"
echo "提示：lark-cli contact +search \"姓名\" 可查 open_id"
read -rp "open_id 列表，空格分隔 [留空跳过]: " permission_input
permission_list="${permission_input:-}"

echo ""
echo "--- 4/6 IM 采集范围（可选）---"
echo "日报数据采集默认只读群聊消息。"
read -rp "是否也采集私聊消息？[y/N]: " im_p2p_input
im_include_p2p="false"
if [[ "${im_p2p_input:-n}" =~ ^[Yy] ]]; then
    im_include_p2p="true"
fi

echo ""
echo "--- 5/6 团队日报摘要（可选）---"
echo "配置后可以说「看看大家今天做了什么」，自动读取团队日报并提取跟你相关的内容。"
echo "粘贴团队日报的飞书知识库链接，格式如 https://xxx.feishu.cn/wiki/xxxxx"
read -rp "链接或 token [留空跳过]: " team_input
team_wiki_node=""
team_space_id=""
watch_list=""
my_role=""

if [[ -n "$team_input" ]]; then
    if [[ "$team_input" == *"/wiki/"* ]]; then
        team_wiki_node=$(echo "$team_input" | sed 's|.*/wiki/||;s|[?#].*||')
    else
        team_wiki_node="$team_input"
    fi

    echo "正在查询知识空间信息..."
    node_info=$(lark-cli wiki spaces get_node --params "{\"token\":\"$team_wiki_node\"}" 2>/dev/null) || node_info='{}'
    team_space_id=$(echo "$node_info" | jq -r '.data.node.space_id // ""' 2>/dev/null)
    node_title=$(echo "$node_info" | jq -r '.data.node.title // ""' 2>/dev/null)

    if [[ -z "$team_space_id" ]]; then
        echo "⚠ 无法自动获取 space_id，请手动输入（留空跳过）："
        read -rp "space_id: " team_space_id
    else
        echo "✓ 已识别：「${node_title}」(space: ${team_space_id})"
    fi

    echo ""
    read -rp "重点关注谁的日报？逗号分隔 [留空则全部由 AI 判断]: " watch_input
    watch_list="${watch_input:-}"
    echo ""
    echo "用一句话描述你的工作职责（AI 用这个判断哪些日报跟你相关）"
    echo "例：TapTap 社区负责人，管社区运营、评价、GameJam"
    read -rp "职责描述 [留空跳过]: " role_input
    my_role="${role_input:-}"
fi

echo ""
echo "--- 6/6 定时触发（可选）---"
if [[ "$(uname)" == "Darwin" ]]; then
    read -rp "是否安装每日 18:00 自动生成草稿日报？[y/N]: " install_cron
fi

fi  # end of setup_mode == "2"

# --- 写入配置 ---

mkdir -p "$CONF_DIR"
cat > "$CONF_FILE" << CONFEOF
# 日报自动化配置文件（由 setup 脚本生成于 $(date +%Y-%m-%d)）
# 所有配置项都可以留空，留空则使用默认值或跳过对应功能。
# 修改后立即生效，无需重新运行 setup。

# 飞书账号（自动填充）
USER_OPEN_ID="$user_open_id"
USER_NAME="$user_name"

# 工作区路径（用于提取文件变更，留空则跳过）
WORKSPACE_DIR="$workspace_dir"

# 日报存放位置（留空则创建在个人空间根目录）
REPORT_FOLDER="$report_folder"

# 创建日报后自动授予 view 权限的 open_id 列表（空格分隔，留空则不授权）
PERMISSION_LIST="$permission_list"

# IM 采集范围：true = 群聊+私聊，false = 仅群聊
IM_INCLUDE_P2P="$im_include_p2p"

# 团队日报摘要（留空则不启用 digest 功能）
TEAM_WIKI_NODE="$team_wiki_node"
TEAM_SPACE_ID="$team_space_id"

# 重点关注的人（逗号分隔，留空则全部由 AI 判断）
WATCH_LIST="$watch_list"

# 你的工作职责（一句话，AI 用来判断哪些日报跟你相关，留空也可以）
MY_ROLE="$my_role"
CONFEOF

echo ""
echo "✓ 配置已写入: $CONF_FILE"

# --- Agent 兼容配置（自动，无需用户操作） ---

echo ""
echo "--- Agent 兼容配置 ---"

agent_count=0

if [[ -d "$HOME/.cursor" ]]; then
    echo "✓ Cursor: 已通过 ~/.agents/skills/ 自动发现"
    ((agent_count++)) || true
fi

if [[ -d "$HOME/.codex" ]]; then
    echo "✓ Codex: 已通过 ~/.agents/skills/ 自动发现"
    ((agent_count++)) || true
fi

if [[ -d "$HOME/.claude" ]]; then
    mkdir -p "$HOME/.claude/skills"
    ln -sf "$SKILL_DIR" "$HOME/.claude/skills/daily-report"
    echo "✓ Claude Code: 已创建 symlink → ~/.claude/skills/daily-report"
    ((agent_count++)) || true
fi

if [[ -d "$HOME/.openclaw" ]]; then
    mkdir -p "$HOME/.openclaw/workspace/memory"
    cat > "$HOME/.openclaw/workspace/memory/daily-report-instructions.md" << 'NAOMI_EOF'
# 日报自动化指令

> 当用户说「写日报」「帮我写日报」「生成今天的日报」时触发

## 工作流

### Step 1: 采集今日数据
并行执行以下采集：
1. 飞书会议与纪要链接
2. 飞书待办
3. 回顾今日对话中提到的关键信息
4. 如可用，补充飞书 IM 里的关键信息

### Step 2: 先做敏感信息过滤
以下内容直接不写进共享日报：
- 人事调整、淘汰、替换、晋升、降级
- 对具体同事的能力评价、适配度判断、优先级排序
- 未公开的组织变化、汇报线变化
- 管理层私下讨论的敏感事项
- 只适合单独向 Leader 汇报的内容

规则：敏感事项不做抽象表达，直接删除。

### Step 3: 呈现草稿
将采集到的数据整理成以下结构，呈现给用户审阅：

```
## YYYY-MM-DD 星期X 日报

### 今日会议
- {会议}（附智能纪要链接）

### 今日进展
- {今日推进的项目和变更}

### 关键信息
- {今天新增的口径、反馈、背景信息}

### 会议 / IM 同步
- {适合同步给团队的公开信息}

### 判断 / 待确认
- {当前倾向和待确认点}

### 风险 / 卡点
- {公开范围内可说的阻塞}

### 下一步
- {明日最重要的 1-3 件事}
```

### Step 4: 用户确认
- 问用户：「有什么需要补充的公开信息吗？」
- 用户确认后，进入下一步

### Step 5: 创建飞书文档
使用 `feishu_docx_create` 创建文档：
- 标题：`YYYY-MM-DD 星期X 日报`
- 如果配置了 wiki node / 文件夹，创建到指定位置

### Step 6: 授权
如果知道需要授权的用户 / Bot open_id，使用 `feishu_permission_member_create` 授予 view 权限。

### Step 7: 返回结果
告知用户文档链接，确认是否需要修改。

## 注意事项
- 不要把所有对话内容都塞进去，只选对管理判断有价值的公开信息
- 某天没有明显产出也可以，重点写"今天事情往前推进了什么"
- 如果今天没有会议或任务，对应章节写「无」即可
- 草稿阶段允许用户多次修改，最终确认后再创建文档
NAOMI_EOF
    echo "✓ OpenClaw: 已生成指令文件 → ~/.openclaw/workspace/memory/daily-report-instructions.md"
    ((agent_count++)) || true
fi

if [[ "$agent_count" -eq 0 ]]; then
    echo "⚠ 未检测到已安装的 AI Agent（Cursor/Codex/Claude Code/OpenClaw）"
    echo "  你可以直接用命令行运行脚本，或安装任意 Agent 后重新运行 setup"
fi

# --- 定时触发 ---

if [[ "${install_cron:-n}" =~ ^[Yy] ]]; then
    LAUNCHAGENT_LABEL="com.$(whoami).daily-report"
    LAUNCHAGENT_PLIST="$HOME/Library/LaunchAgents/${LAUNCHAGENT_LABEL}.plist"
    mkdir -p "$(dirname "$LAUNCHAGENT_PLIST")"
    cat > "$LAUNCHAGENT_PLIST" << PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LAUNCHAGENT_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$REPORT_SCRIPT</string>
        <string>auto</string>
        <string>--draft</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>18</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>/tmp/daily-report.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/daily-report.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
</dict>
</plist>
PLISTEOF
    launchctl unload "$LAUNCHAGENT_PLIST" 2>/dev/null || true
    launchctl load "$LAUNCHAGENT_PLIST"
    echo ""
    echo "✓ LaunchAgent 已安装，每日 18:00 自动生成草稿日报"
    echo "  日志位置: /tmp/daily-report.log"
    echo "  卸载命令: launchctl unload $LAUNCHAGENT_PLIST"
fi

# --- 完成 ---

echo ""
echo "=== 初始化完成 ==="
echo ""
echo "使用方法："
echo "  对 AI 说「写日报」           # 交互式生成（推荐）"
echo "  对 AI 说「看看大家今天做了什么」 # 团队日报摘要"
echo "  bash $REPORT_SCRIPT auto    # 命令行一键生成"
echo ""
echo "修改配置：$CONF_FILE"
echo "详细使用指南：cat $SKILL_DIR/references/quickstart.md"

cat << 'COFFEE'

  ┌──────────────────────────────────────┐
  │  日报自动化 · Powered by 远夏        │
  │                                      │
  │  本工具接受咖啡形式的 star ⭐          │
  └──────────────────────────────────────┘

COFFEE
