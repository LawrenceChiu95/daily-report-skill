#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  grep -Eq "$pattern" "$file" || fail "$label"
}

assert_not_contains() {
  local pattern="$1"
  local label="$2"
  shift 2
  if grep -En "$pattern" "$@" >/tmp/daily-report-self-test-match.txt; then
    cat /tmp/daily-report-self-test-match.txt >&2
    fail "$label"
  fi
}

bash -n scripts/setup.sh
bash -n scripts/daily-report.sh
python3 -m py_compile scripts/collect-conversations.py scripts/collect-gitlab.py
WORKSPACE_DIR="" python3 scripts/collect-conversations.py 2099-01-01 >/dev/null

assert_contains scripts/setup.sh '@larksuite/cli' "setup must install the official @larksuite/cli package"
assert_not_contains 'npm install -g lark-cli' "setup must not install the unrelated lark-cli npm package" scripts/setup.sh README.md references/*.md SKILL.md

assert_contains scripts/setup.sh 'calendar,docs,drive,contact,vc,im' "setup must request all default Lark domains used by the collector"
assert_contains scripts/setup.sh 'search:message' "setup must request/check message search scope"
assert_contains scripts/setup.sh 'im:message\.group_msg:get_as_user' "setup must request/check group message read scope"
assert_contains scripts/setup.sh 'im:message\.p2p_msg:get_as_user' "setup must request/check p2p message read scope"
assert_not_contains 'im:message:search' "docs must not mention obsolete im:message:search scope" README.md references/*.md SKILL.md

assert_contains scripts/setup.sh 'read -rsp "GitLab Token' "GitLab token input must be hidden"
assert_contains scripts/setup.sh 'umask 077' "config writes must use a private umask"
assert_contains scripts/setup.sh 'chmod 600 "\$CONF_FILE"' "config file permissions must be restricted"
assert_contains scripts/setup.sh 'shell_quote' "config values must be shell-escaped before writing"

assert_contains scripts/setup.sh 'FEISHU_BASE_URL' "setup must write configurable Feishu base URL"
assert_contains scripts/daily-report.sh 'FEISHU_BASE_URL' "daily-report must use configurable Feishu base URL"
assert_not_contains 'xd\.feishu\.cn' "scripts must not hardcode the xd.feishu.cn tenant" scripts/setup.sh scripts/daily-report.sh
assert_not_contains 'env_args\[@\]' "conversation collection must not expand an empty array under set -u" scripts/daily-report.sh

assert_not_contains '远夏|邱一鸣|TapTap' "shareable files must not contain personal or company-specific examples" README.md SKILL.md references/*.md scripts/setup.sh scripts/daily-report.sh agents/*.yaml

echo "self-test ok"
