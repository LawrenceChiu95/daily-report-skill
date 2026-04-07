#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_FILE="${DAILY_REPORT_CONF:-$HOME/.config/daily-report/config}"

TODAY=$(date +%Y-%m-%d)
WEEKDAY_NUM=$(date +%u)
WEEKDAY_NAMES=("" "周一" "周二" "周三" "周四" "周五" "周六" "周日")
WEEKDAY="${WEEKDAY_NAMES[$WEEKDAY_NUM]}"

SENSITIVE_PATTERN='团队升级|汰换|淘汰|裁员|开掉|替换优先级|候选名单|人员配置分析|人事调整|组织调整|汇报线|晋升|降级|绩效|适配度判断|HC|编制|预算分配|薪资|调薪|年终奖|股权|面试评价|offer审批|能力不足|不胜任|PIP|试用期不通过|保密|未公开|不要外传'

# ── 非工作日草稿存储 ────────────────────────────────────────
PENDING_DIR="$HOME/.daily-report/pending"
mkdir -p "$PENDING_DIR"

is_workday() {
    local date="${1:-$TODAY}"

    # 优先级 1：调休上班日（周末但上班）→ 工作日
    if [[ " ${WORKDAY_OVERRIDES:-} " == *" $date "* ]]; then
        return 0
    fi

    # 优先级 2：法定假日 → 非工作日
    if [[ " ${HOLIDAYS:-} " == *" $date "* ]]; then
        return 1
    fi

    # 优先级 3：无本地配置时 fallback 到 API
    local dow
    if [[ "$(uname)" == "Darwin" ]]; then
        dow=$(date -j -f "%Y-%m-%d" "$date" "+%u" 2>/dev/null || echo "?")
    else
        dow=$(date -d "$date" "+%u" 2>/dev/null || echo "?")
    fi
    if [[ -z "${HOLIDAYS:-}" ]]; then
        local api_result
        api_result=$(curl -sf --max-time 3 "https://timor.tech/api/holiday/info/$date" 2>/dev/null) || true
        if [[ -n "$api_result" ]]; then
            local holiday_type
            holiday_type=$(echo "$api_result" | jq -r '.type.type // empty' 2>/dev/null)
            case "$holiday_type" in
                0|3) return 0 ;;  # 0=工作日, 3=调休上班
                1|2) return 1 ;;  # 1=周末, 2=法定假日
            esac
        fi
    fi

    # 兜底：按星期判断
    [[ "$dow" -le 5 ]]
}

has_meaningful_output() {
    local data="$1"
    local conv_count git_count meeting_count gl_commits gl_mrs
    conv_count=$(echo "$data" | jq '.conversations.total_sessions // 0')
    git_count=$(echo "$data" | jq '.workspace.file_count // 0')
    meeting_count=$(echo "$data" | jq '.meetings.count // 0')
    gl_commits=$(echo "$data" | jq '.gitlab.commit_count // 0')
    gl_mrs=$(echo "$data" | jq '.gitlab.mr_count // 0')
    [[ "$conv_count" -gt 0 || "$git_count" -gt 0 || "$meeting_count" -gt 0 || "$gl_commits" -gt 0 || "$gl_mrs" -gt 0 ]]
}

is_sensitive_text() {
    local text="$1"
    if [[ -z "$text" ]]; then
        return 1
    fi
    local full_pattern="$SENSITIVE_PATTERN"
    if [[ -n "${EXTRA_SENSITIVE_PATTERN:-}" ]]; then
        full_pattern="${full_pattern}|${EXTRA_SENSITIVE_PATTERN}"
    fi
    echo "$text" | grep -E -q "$full_pattern"
}

load_config() {
    if [[ ! -f "$CONF_FILE" ]]; then
        echo "错误：配置文件 $CONF_FILE 不存在" >&2
        echo "请先运行: bash $SCRIPT_DIR/setup.sh" >&2
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$CONF_FILE"
}

check_auth() {
    local status
    status=$(lark-cli auth status 2>&1) || true
    local token_status
    token_status=$(echo "$status" | jq -r '.tokenStatus // "unknown"' 2>/dev/null)
    if [[ "$token_status" != "valid" && "$token_status" != "needs_refresh" ]]; then
        echo "错误：lark-cli 认证已过期，请先运行: lark-cli auth login --domain calendar,task,docs,drive" >&2
        exit 1
    fi
}

collect_calendar() {
    local target_date="${1:-$TODAY}"
    local start="${target_date}T00:00:00+08:00"
    local end="${target_date}T23:59:59+08:00"
    local result
    result=$(lark-cli calendar +agenda --start "$start" --end "$end" 2>/dev/null) || result='{"data":[]}'
    local events
    events=$(echo "$result" | jq -c '[.data[]? | {
        summary: .summary,
        start: (.start_time.timestamp // "" | if . != "" then (. | tonumber | strftime("%H:%M")) else "未知" end),
        end: (.end_time.timestamp // "" | if . != "" then (. | tonumber | strftime("%H:%M")) else "未知" end),
        status: (.self_rsvp_status // "needs_action"),
        organizer: (.organizer_name // "")
    }] // []' 2>/dev/null) || events='[]'
    echo "$events"
}

collect_tasks() {
    echo '[]'
}

collect_git() {
    local ws_dir="${WORKSPACE_DIR:-$(pwd)}"
    if [[ ! -d "$ws_dir/.git" ]]; then
        echo '{"directories":[],"file_count":0}'
        return
    fi
    local target_date="${1:-$TODAY}"
    local changed_files
    if [[ "$(uname)" == "Darwin" ]]; then
        changed_files=$(cd "$ws_dir" && find . -maxdepth 4 -name "*.md" -type f \
            -exec stat -f "%Sm %N" -t "%Y-%m-%d" {} \; 2>/dev/null \
            | grep "^${target_date}" | cut -d' ' -f2- | grep -v '^\.') || changed_files=""
    else
        changed_files=$(cd "$ws_dir" && find . -maxdepth 4 -name "*.md" -type f \
            -newermt "${target_date} 00:00:00" ! -newermt "${target_date} 23:59:59" \
            -printf "%P\n" 2>/dev/null | grep -v '^\.') || changed_files=""
    fi
    if [[ -z "$changed_files" ]]; then
        changed_files=$(cd "$ws_dir" && git -c core.quotePath=false diff --name-only --cached 2>/dev/null) || changed_files=""
    fi

    if [[ -z "$changed_files" ]]; then
        echo '{"directories":[],"file_count":0}'
        return
    fi

    local dirs_json
    dirs_json=$(echo "$changed_files" | python3 -c "
import sys, json
from collections import defaultdict
files = [l.strip() for l in sys.stdin if l.strip()]
groups = defaultdict(list)
for f in files:
    parts = f.split('/')
    if parts[0].startswith('.'):
        continue
    top = parts[0] if len(parts) > 1 else '根目录'
    name = '/'.join(parts[1:]) if len(parts) > 1 else parts[0]
    groups[top].append(name)
result = [{'directory': k, 'files': v[:5], 'count': len(v)} for k, v in groups.items()]
print(json.dumps(result, ensure_ascii=False))
" 2>/dev/null) || dirs_json='[]'

    local file_count
    file_count=$(echo "$changed_files" | grep -c . || echo 0)
    echo "{\"directories\":$dirs_json,\"file_count\":$file_count}"
}

collect_im() {
    local target_date="${1:-$TODAY}"
    local start="${target_date}T00:00:00+08:00"
    local end="${target_date}T23:59:59+08:00"

    local chat_type_arg="--chat-type group"
    if [[ "${IM_INCLUDE_P2P:-false}" == "true" ]]; then
        chat_type_arg=""
    fi

    local result
    # shellcheck disable=SC2086
    result=$(lark-cli im +messages-search --sender-type user $chat_type_arg --start "$start" --end "$end" --page-all 2>/dev/null) || result='{"data":{"messages":[]}}'

    local messages
    messages=$(echo "$result" | jq -c '[.data.messages[]? | select(.msg_type == "text" or .msg_type == "post") | {
        chat_name: .chat_name,
        content: (.content // ""),
        time: .create_time,
        chat_id: .chat_id
    }]' 2>/dev/null) || messages='[]'

    echo "$messages"
}

collect_conversations() {
    local env_args=()
    if [[ -n "${WORKSPACE_DIR:-}" ]]; then
        env_args=(env "WORKSPACE_DIR=$WORKSPACE_DIR")
    fi
    "${env_args[@]}" python3 "$SCRIPT_DIR/collect-conversations.py" "${1:-$TODAY}" 2>/dev/null \
        || echo '{"conversations":[],"naomi_memory":null,"total_sessions":0}'
}

collect_gitlab() {
    local target_date="${1:-$TODAY}"
    if [[ -z "${GITLAB_HOST:-}" || -z "${GITLAB_TOKEN:-}" ]]; then
        echo '{"commits":[],"mrs_authored":[],"mrs_reviewed":[],"commit_count":0,"mr_count":0,"review_count":0,"error":"未配置"}'
        return
    fi
    GITLAB_HOST="$GITLAB_HOST" GITLAB_TOKEN="$GITLAB_TOKEN" \
        python3 "$SCRIPT_DIR/collect-gitlab.py" "$target_date" 2>/dev/null \
        || echo '{"commits":[],"mrs_authored":[],"mrs_reviewed":[],"commit_count":0,"mr_count":0,"review_count":0,"error":"脚本执行失败"}'
}

collect_meetings() {
    local target_date="${1:-$TODAY}"
    local start="${target_date}T00:00:00+08:00"
    local end="${target_date}T23:59:59+08:00"

    local meetings_raw
    meetings_raw=$(lark-cli vc +search --start "$start" --end "$end" 2>/dev/null) || meetings_raw='{"data":{"items":[]}}'

    local meeting_ids
    meeting_ids=$(echo "$meetings_raw" | jq -r '[.data.items[]?.id] | join(",")' 2>/dev/null)

    local notes_map='{}'
    if [[ -n "$meeting_ids" && "$meeting_ids" != "" ]]; then
        local raw_notes
        raw_notes=$(lark-cli vc +notes --meeting-ids "$meeting_ids" 2>&1 | grep -v '^\[vc') || raw_notes='{}'
        notes_map=$(echo "$raw_notes" | jq -c 'reduce (.data.notes[]? // empty) as $n ({}; . + {($n.meeting_id): ("https://xd.feishu.cn/docx/" + $n.note_doc_token)})' 2>/dev/null) || notes_map='{}'
    fi

    local events
    events=$(echo "$meetings_raw" | jq -c --argjson nm "$notes_map" '[.data.items[]? | {
        id: .id,
        summary: (.display_info | split("\n")[0]),
        description: .meta_data.description,
        note_url: ($nm[.id] // null)
    }]' 2>/dev/null) || events='[]'

    jq -n --argjson events "$events" '{events: $events, count: ($events | length)}'
}

cmd_collect() {
    load_config
    check_auth

    local target_date="${1:-$TODAY}"
    local target_weekday="$WEEKDAY"
    if [[ "$target_date" != "$TODAY" ]]; then
        if [[ "$(uname)" == "Darwin" ]]; then
            target_weekday=$(date -j -f "%Y-%m-%d" "$target_date" "+%u" 2>/dev/null || echo "?")
        else
            target_weekday=$(date -d "$target_date" "+%u" 2>/dev/null || echo "?")
        fi
        target_weekday="${WEEKDAY_NAMES[$target_weekday]:-?}"
    fi

    local calendar git_data conversations meetings im_messages gitlab_data
    calendar=$(collect_calendar "$target_date")
    git_data=$(collect_git "$target_date")
    conversations=$(collect_conversations "$target_date")
    meetings=$(collect_meetings "$target_date")
    im_messages=$(collect_im "$target_date")
    gitlab_data=$(collect_gitlab "$target_date")

    # 检查是否有未消费的非工作日草稿
    local pending_days="[]"
    if [[ -d "$PENDING_DIR" ]]; then
        for pf in "$PENDING_DIR"/*.json; do
            [[ -f "$pf" ]] || continue
            local pdate pweekday pdow
            pdate=$(basename "$pf" .json)
            if [[ "$(uname)" == "Darwin" ]]; then
                pdow=$(date -j -f "%Y-%m-%d" "$pdate" "+%u" 2>/dev/null || echo "?")
            else
                pdow=$(date -d "$pdate" "+%u" 2>/dev/null || echo "?")
            fi
            pweekday="${WEEKDAY_NAMES[$pdow]:-}"
            pending_days=$(echo "$pending_days" | jq \
                --arg d "$pdate" \
                --arg w "$pweekday" \
                --slurpfile data "$pf" \
                '. + [{"date": $d, "weekday": $w, "data": $data[0]}]')
        done
    fi

    jq -n \
        --arg date "$target_date" \
        --arg weekday "$target_weekday" \
        --argjson calendar "$calendar" \
        --argjson workspace "$git_data" \
        --argjson conversations "$conversations" \
        --argjson meetings "$meetings" \
        --argjson im "$im_messages" \
        --argjson gitlab "$gitlab_data" \
        --argjson pending_days "$pending_days" \
        '{
            date: $date,
            weekday: $weekday,
            calendar: { events: $calendar, count: ($calendar | length) },
            workspace: $workspace,
            conversations: $conversations,
            meetings: $meetings,
            im: { messages: $im, count: ($im | length) },
            gitlab: $gitlab,
            pending_days: $pending_days
        }'
}

generate_markdown() {
    local data="$1"

    local meetings_section="### 今日会议

"
    local meeting_count
    meeting_count=$(echo "$data" | jq '.meetings.count // 0')
    if [[ "$meeting_count" -gt 0 ]]; then
        meetings_section+="| 会议 | 时间 | 结论 | 纪要 |
"
        meetings_section+="|------|------|------|------|
"
        while IFS= read -r event; do
            local summary time_str note_url
            summary=$(echo "$event" | jq -r '.summary // ""')
            time_str=$(echo "$event" | jq -r '(.description // "") | match("([0-9]{1,2}:[0-9]{2})") | .string' 2>/dev/null) || time_str=""
            note_url=$(echo "$event" | jq -r '.note_url // ""')
            local note_cell="—"
            if [[ -n "$note_url" && "$note_url" != "null" ]]; then
                note_cell="[智能纪要](${note_url})"
            fi
            meetings_section+="| ${summary} | ${time_str} | （待补充） | ${note_cell} |
"
        done < <(echo "$data" | jq -c '.meetings.events[]')
    else
        meetings_section+="无会议。
"
    fi

    # ── 假期/周末推进（如有 pending_days）────────────────────────
    local pending_section=""
    local pending_count
    pending_count=$(echo "$data" | jq '.pending_days | length // 0')
    if [[ "$pending_count" -gt 0 ]]; then
        local first_date last_date
        first_date=$(echo "$data" | jq -r '.pending_days[0].date' | sed 's/^[0-9]*-//' | sed 's/-/\//')
        last_date=$(echo "$data" | jq -r '.pending_days[-1].date' | sed 's/^[0-9]*-//' | sed 's/-/\//')
        pending_section="### 假期/周末推进（${first_date}-${last_date}）

"
        while IFS= read -r day_entry; do
            local pdate pweekday
            pdate=$(echo "$day_entry" | jq -r '.date')
            pweekday=$(echo "$day_entry" | jq -r '.weekday')
            local p_display
            p_display=$(echo "$pdate" | sed 's/^[0-9]*-//' | sed 's/^0//;s/-0/-/;s/-/月/')
            pending_section+="**${p_display}日（${pweekday}）**
"
            # GitLab 提交
            local p_gl_commits
            p_gl_commits=$(echo "$day_entry" | jq '.data.gitlab.commit_count // 0')
            if [[ "$p_gl_commits" -gt 0 ]]; then
                while IFS= read -r commit; do
                    local prj ttl
                    prj=$(echo "$commit" | jq -r '.project // ""')
                    ttl=$(echo "$commit" | jq -r '.commit_title // ""')
                    pending_section+="- 代码提交：${ttl}（${prj}）
"
                done < <(echo "$day_entry" | jq -c '.data.gitlab.commits[]? // empty')
            fi
            # MR 动态
            local p_gl_mrs
            p_gl_mrs=$(echo "$day_entry" | jq '.data.gitlab.mr_count // 0')
            if [[ "$p_gl_mrs" -gt 0 ]]; then
                while IFS= read -r mr; do
                    local ttl prj
                    ttl=$(echo "$mr" | jq -r '.title // ""')
                    prj=$(echo "$mr" | jq -r '.project // ""')
                    pending_section+="- MR：${ttl}（${prj}）
"
                done < <(echo "$day_entry" | jq -c '.data.gitlab.mrs_authored[]? // empty')
            fi
            # 工作区文档变更
            local p_dir_count
            p_dir_count=$(echo "$day_entry" | jq '.data.workspace.directories | length // 0')
            if [[ "$p_dir_count" -gt 0 ]]; then
                while IFS= read -r dir_entry; do
                    local dirname files_preview
                    dirname=$(echo "$dir_entry" | jq -r '.directory')
                    files_preview=$(echo "$dir_entry" | jq -r '.files[:3] | join("、")')
                    local line="- 文档变更：**${dirname}** — ${files_preview}"
                    if ! is_sensitive_text "$line"; then
                        pending_section+="${line}
"
                    fi
                done < <(echo "$day_entry" | jq -c '.data.workspace.directories[]? // empty')
            fi
            # 如果什么都没有，标记对话活跃
            local p_conv
            p_conv=$(echo "$day_entry" | jq '.data.conversations.total_sessions // 0')
            if [[ "$p_gl_commits" -eq 0 && "$p_gl_mrs" -eq 0 && "$p_dir_count" -eq 0 && "$p_conv" -gt 0 ]]; then
                pending_section+="- AI 对话 ${p_conv} 个会话（详见对话记录）
"
            fi
            pending_section+="
"
        done < <(echo "$data" | jq -c '.pending_days[]')
    fi

    local progress_section="### 今日进展

"

    # ── GitLab 代码提交 & MR ────────────────────────────────────────
    local gl_commit_count gl_mr_count gl_review_count gl_error
    gl_commit_count=$(echo "$data" | jq '.gitlab.commit_count // 0')
    gl_mr_count=$(echo "$data" | jq '.gitlab.mr_count // 0')
    gl_review_count=$(echo "$data" | jq '.gitlab.review_count // 0')
    gl_error=$(echo "$data" | jq -r '.gitlab.error // ""')

    if [[ "$gl_error" == "null" || -z "$gl_error" ]]; then
        if [[ "$gl_commit_count" -gt 0 ]]; then
            progress_section+="**代码提交（${gl_commit_count} commits）**\n\n"
            while IFS= read -r commit; do
                [[ -z "$commit" || "$commit" == "null" ]] && continue
                local prj ref cnt ttl
                prj=$(echo "$commit" | jq -r '.project // ""')
                ref=$(echo "$commit" | jq -r '.ref // ""')
                cnt=$(echo "$commit" | jq -r '.commit_count // 1')
                ttl=$(echo "$commit" | jq -r '.commit_title // ""')
                progress_section+="- **${prj}** \`${ref}\`：${cnt} 次 — ${ttl}\n"
            done < <(echo "$data" | jq -c '.gitlab.commits[]? // empty')
            progress_section+="\n"
        fi

        if [[ "$gl_mr_count" -gt 0 ]]; then
            progress_section+="**MR 动态**\n\n"
            while IFS= read -r mr; do
                [[ -z "$mr" || "$mr" == "null" ]] && continue
                local action ttl prj action_label
                action=$(echo "$mr" | jq -r '.action // ""')
                ttl=$(echo "$mr" | jq -r '.title // ""')
                prj=$(echo "$mr" | jq -r '.project // ""')
                case "$action" in
                    opened|created) action_label="创建" ;;
                    merged|accepted) action_label="合并" ;;
                    closed) action_label="关闭" ;;
                    *) action_label="$action" ;;
                esac
                progress_section+="- ${action_label} MR：${ttl}（${prj}）\n"
            done < <(echo "$data" | jq -c '.gitlab.mrs_authored[]? // empty')
            progress_section+="\n"
        fi

        if [[ "$gl_review_count" -gt 0 ]]; then
            progress_section+="**Code Review**\n\n"
            while IFS= read -r mr; do
                [[ -z "$mr" || "$mr" == "null" ]] && continue
                local action ttl prj action_label
                action=$(echo "$mr" | jq -r '.action // ""')
                ttl=$(echo "$mr" | jq -r '.title // ""')
                prj=$(echo "$mr" | jq -r '.project // ""')
                case "$action" in
                    "commented on") action_label="评论" ;;
                    approved) action_label="Approved" ;;
                    *) action_label="$action" ;;
                esac
                progress_section+="- ${action_label}：${ttl}（${prj}）\n"
            done < <(echo "$data" | jq -c '.gitlab.mrs_reviewed[]? // empty')
            progress_section+="\n"
        fi
    fi

    # ── 工作区文档变更 ──────────────────────────────────────────────
    local dir_count
    dir_count=$(echo "$data" | jq '.workspace.directories | length')
    if [[ "$dir_count" -gt 0 ]]; then
        while IFS= read -r dir_entry; do
            local dirname files_preview line
            dirname=$(echo "$dir_entry" | jq -r '.directory')
            files_preview=$(echo "$dir_entry" | jq -r '.files[:3] | join("、")')
            line="- **${dirname}**：${files_preview}"
            if ! is_sensitive_text "$line"; then
                progress_section+="${line}\n"
            fi
        done < <(echo "$data" | jq -c '.workspace.directories[]')
    fi

    if [[ "$gl_commit_count" -eq 0 && "$gl_mr_count" -eq 0 && "$gl_review_count" -eq 0 && "$dir_count" -eq 0 ]]; then
        progress_section+="- （待补充）\n"
    fi

    local next_section="### 下一步

- （待补充）
"

    local markdown=""
    markdown+="${meetings_section}\n"
    if [[ -n "$pending_section" ]]; then
        markdown+="${pending_section}\n"
    fi
    markdown+="${progress_section}\n"
    markdown+="${next_section}\n"

    echo -e "$markdown"
}

grant_permissions() {
    local doc_token="$1"
    if [[ -z "${PERMISSION_LIST:-}" ]]; then
        return 0
    fi
    for member_id in $PERMISSION_LIST; do
        lark-cli drive permission.members create "$doc_token" \
            --params "{\"type\":\"docx\",\"need_notification\":false}" \
            --data "{\"member_type\":\"openid\",\"member_id\":\"$member_id\",\"perm\":\"view\",\"type\":\"user\"}" \
            2>/dev/null || echo "警告：授权 $member_id 失败" >&2
    done
}

cmd_create() {
    load_config
    check_auth

    local title="${TODAY} ${WEEKDAY} 日报"
    local markdown=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --title) title="$2"; shift 2 ;;
            --draft) title="[草稿] $title"; shift ;;
            *) shift ;;
        esac
    done

    if [[ -t 0 ]]; then
        echo "错误：请通过 stdin 传入 markdown 内容" >&2
        echo "用法：echo \"内容\" | bash $0 create [--title 标题]" >&2
        exit 1
    fi
    markdown=$(cat)

    local create_args=(--title "$title" --markdown "$markdown")
    if [[ -n "${DRAFT_WIKI_SPACE:-}" ]]; then
        create_args+=(--wiki-space "$DRAFT_WIKI_SPACE")
    elif [[ -n "${REPORT_WIKI_NODE:-}" ]]; then
        create_args+=(--wiki-node "$REPORT_WIKI_NODE")
    elif [[ -n "${REPORT_FOLDER:-}" ]]; then
        create_args+=(--folder-token "$REPORT_FOLDER")
    fi

    local result
    result=$(lark-cli docs +create "${create_args[@]}" 2>&1)
    local doc_id doc_url
    doc_id=$(echo "$result" | jq -r '.data.doc_id // .doc_id // empty' 2>/dev/null)
    doc_url=$(echo "$result" | jq -r '.data.doc_url // .doc_url // empty' 2>/dev/null)

    if [[ -z "$doc_id" ]]; then
        echo "错误：创建文档失败" >&2
        echo "$result" >&2
        exit 1
    fi

    grant_permissions "$doc_id"

    # 首份日报彩蛋（仅触发一次）
    if [[ -z "${FIRST_REPORT_DONE:-}" ]]; then
        echo "" >&2
        echo "🎉 你的第一份自动化日报已生成！从此告别手动建文档。" >&2
        echo "   如果觉得好用，记得请远夏喝杯咖啡。" >&2
        echo "" >&2
        echo "FIRST_REPORT_DONE=true" >> "$CONF_FILE"
    fi

    jq -n \
        --arg doc_id "$doc_id" \
        --arg doc_url "$doc_url" \
        --arg title "$title" \
        '{doc_id: $doc_id, doc_url: $doc_url, title: $title, status: "created"}'
}

cmd_auto() {
    local draft_flag=""
    local target_date="$TODAY"
    for arg in "$@"; do
        case "$arg" in
            --draft) draft_flag="--draft" ;;
            20[0-9][0-9]-*) target_date="$arg" ;;
        esac
    done

    # 非工作日：静默存档到本地，不创建飞书文档
    if ! is_workday "$target_date"; then
        local data
        data=$(cmd_collect "$target_date")
        if has_meaningful_output "$data"; then
            echo "$data" > "$PENDING_DIR/${target_date}.json"
            echo "非工作日（${target_date}），已静默存档到 $PENDING_DIR/${target_date}.json" >&2
        else
            echo "非工作日（${target_date}），无工作产出，跳过" >&2
        fi
        return 0
    fi

    # 工作日：正常流程
    local data
    data=$(cmd_collect "$target_date")
    local markdown
    markdown=$(generate_markdown "$data")

    local weekday_label="$WEEKDAY"
    if [[ "$target_date" != "$TODAY" ]]; then
        local dow
        if [[ "$(uname)" == "Darwin" ]]; then
            dow=$(date -j -f "%Y-%m-%d" "$target_date" "+%u" 2>/dev/null || echo "?")
        else
            dow=$(date -d "$target_date" "+%u" 2>/dev/null || echo "?")
        fi
        weekday_label="${WEEKDAY_NAMES[$dow]:-}"
    fi

    local title="${target_date} ${weekday_label} 日报"
    local create_args=(--title "$title")
    if [[ -n "$draft_flag" ]]; then
        create_args+=(--draft)
    fi

    echo "$markdown" | cmd_create "${create_args[@]}"

    # 创建成功后清除已消费的 pending 草稿
    cmd_clear_pending
}

cmd_publish() {
    load_config
    check_auth

    if [[ -z "${PUBLISH_WIKI_NODE:-}" || -z "${PUBLISH_SPACE_ID:-}" ]]; then
        echo "错误：未配置发布位置（PUBLISH_WIKI_NODE / PUBLISH_SPACE_ID）" >&2
        exit 1
    fi

    local wiki_token="${1:-}"
    if [[ -z "$wiki_token" ]]; then
        echo "错误：请提供要发布的文档 wiki token" >&2
        echo "用法：bash $0 publish <wiki_token>" >&2
        exit 1
    fi

    local result
    result=$(lark-cli api POST "/open-apis/wiki/v2/spaces/$PUBLISH_SPACE_ID/nodes/$wiki_token/move" \
        --data "{\"target_parent_token\":\"$PUBLISH_WIKI_NODE\"}" 2>&1)

    local code
    code=$(echo "$result" | jq -r '.code // 1' 2>/dev/null)
    if [[ "$code" == "0" ]]; then
        grant_permissions "$(lark-cli wiki spaces get_node --params "{\"token\":\"$wiki_token\"}" 2>/dev/null | jq -r '.data.node.obj_token // empty')"
        echo "已发布到公共目录"
    else
        echo "发布失败：" >&2
        echo "$result" >&2
        exit 1
    fi
}

cmd_clear_pending() {
    local count=0
    for pf in "$PENDING_DIR"/*.json; do
        [[ -f "$pf" ]] || continue
        rm "$pf"
        count=$((count + 1))
    done
    if [[ "$count" -gt 0 ]]; then
        echo "已清除 ${count} 个非工作日草稿" >&2
    fi
}

cmd_digest() {
    load_config
    check_auth

    local target_date="${1:-$TODAY}"
    if [[ -z "${TEAM_WIKI_NODE:-}" || -z "${TEAM_SPACE_ID:-}" ]]; then
        echo "错误：未配置团队日报节点（TEAM_WIKI_NODE / TEAM_SPACE_ID）" >&2
        echo "请在 $CONF_FILE 中添加 TEAM_WIKI_NODE 和 TEAM_SPACE_ID" >&2
        exit 1
    fi

    local date_no_pad
    date_no_pad=$(echo "$target_date" | sed 's/-0/-/g; s/^0//')
    local date_patterns=("$target_date" "$date_no_pad")

    local people_nodes
    people_nodes=$(lark-cli api GET "/open-apis/wiki/v2/spaces/$TEAM_SPACE_ID/nodes" \
        --params "{\"parent_node_token\":\"$TEAM_WIKI_NODE\"}" --page-all 2>/dev/null \
        | jq -c '[.data.items[]? | {name: .title, node_token: .node_token, has_child: .has_child}]' 2>/dev/null) || people_nodes='[]'

    local reports='[]'
    while IFS= read -r person; do
        local name node_token has_child
        name=$(echo "$person" | jq -r '.name')
        node_token=$(echo "$person" | jq -r '.node_token')
        has_child=$(echo "$person" | jq -r '.has_child')

        if [[ "$name" == "${USER_NAME:-}" ]]; then
            continue
        fi

        if [[ "$has_child" != "true" ]]; then
            continue
        fi

        local children
        children=$(lark-cli api GET "/open-apis/wiki/v2/spaces/$TEAM_SPACE_ID/nodes" \
            --params "{\"parent_node_token\":\"$node_token\"}" --page-all 2>/dev/null \
            | jq -c '.data.items // []' 2>/dev/null) || children='[]'

        local matched_doc=""
        for pat in "${date_patterns[@]}"; do
            matched_doc=$(echo "$children" | jq -c --arg d "$pat" '[.[]? | select(.title | contains($d))] | first // empty' 2>/dev/null)
            if [[ -n "$matched_doc" ]]; then
                break
            fi
        done

        if [[ -z "$matched_doc" ]]; then
            continue
        fi

        local obj_token doc_title
        obj_token=$(echo "$matched_doc" | jq -r '.obj_token')
        doc_title=$(echo "$matched_doc" | jq -r '.title')

        local content=""
        if [[ -n "$obj_token" ]]; then
            content=$(lark-cli docs +fetch --doc "$obj_token" 2>/dev/null \
                | jq -r '.data.markdown // ""' 2>/dev/null) || content=""
        fi

        reports=$(echo "$reports" | jq -c --arg name "$name" --arg title "$doc_title" --arg content "$content" \
            '. + [{author: $name, title: $title, content: $content}]')
    done < <(echo "$people_nodes" | jq -c '.[]')

    local watch_list_json='[]'
    if [[ -n "${WATCH_LIST:-}" ]]; then
        watch_list_json=$(echo "$WATCH_LIST" | python3 -c "import sys,json; print(json.dumps([x.strip() for x in sys.stdin.read().split(',') if x.strip()]))")
    fi

    jq -n \
        --arg date "$target_date" \
        --arg user_name "${USER_NAME:-}" \
        --arg my_role "${MY_ROLE:-}" \
        --argjson watch_list "$watch_list_json" \
        --argjson reports "$reports" \
        '{
            date: $date,
            user: { name: $user_name, role: $my_role },
            watch_list: $watch_list,
            reports: $reports,
            report_count: ($reports | length)
        }'
}

cmd_credits() {
    cat << 'EOF'
日报自动化 v1.0
作者：远夏（邱一鸣）
技术栈：bash + lark-cli + AI Agent

本工具接受咖啡形式的 star ⭐
EOF
}

usage() {
    cat << EOF
日报自动化工具

用法：
  bash $0 <命令> [选项]

命令：
  collect [日期]       收集会议、待办、对话、工作区变更，输出 JSON
  create [--title T]   从 stdin 读取 markdown，创建到个人空间（草稿）
  auto [--draft] [日期] 自动收集 + 生成 + 创建（非工作日自动存本地草稿）
  publish <wiki_token> 将草稿从个人空间移到公共目录 + 授权
  digest [日期]        读取团队所有人的日报，输出 JSON 供 AI 生成摘要
  clear-pending        清除已消费的非工作日草稿

示例：
  bash $0 collect                              # 查看今日数据
  bash $0 auto                                 # 一键生成日报（非工作日自动存草稿）
  bash $0 auto --draft                         # 生成草稿日报
  bash $0 auto 2026-04-05                      # 补生成指定日期日报
  echo "## 自定义内容" | bash $0 create         # 从自定义内容创建

配置：$CONF_FILE
EOF
}

main() {
    case "${1:-help}" in
        collect)       shift; cmd_collect "$@" ;;
        create)        shift; cmd_create "$@" ;;
        publish)       shift; cmd_publish "$@" ;;
        auto)          shift; cmd_auto "$@" ;;
        digest)        shift; cmd_digest "$@" ;;
        clear-pending) shift; cmd_clear_pending "$@" ;;
        credits)       cmd_credits ;;
        help|-h|--help) usage ;;
        *) echo "未知命令: $1" >&2; usage; exit 1 ;;
    esac
}

main "$@"
