#!/bin/zsh
# Agent PM — local weekly consolidation runner
# Invoked by launchd at 09:00 every Monday (see ~/Library/LaunchAgents/com.mssanwel.agent-pm.weekly.plist)

set -u
set -o pipefail

REPO_DIR="${HOME}/code/agent-pm"
TRIGGER_FILE="${REPO_DIR}/.claude/triggers/agent-pm-weekly.md"
LOG_DIR="${REPO_DIR}/.claude/agent-pm/logs"
PAUSE_FLAG="${REPO_DIR}/.claude/agent-pm/pause.flag"

mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/weekly-$(date +%Y-%m-%d).log"

if [[ -f "${PAUSE_FLAG}" ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] paused — exit" >> "${LOG_FILE}"
  exit 0
fi

if [[ ! -f "${TRIGGER_FILE}" ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: trigger file missing" >> "${LOG_FILE}"
  exit 1
fi

if ! command -v claude >/dev/null 2>&1; then
  if [[ -x /opt/homebrew/bin/claude ]]; then
    PATH="/opt/homebrew/bin:${PATH}"
  elif [[ -x /usr/local/bin/claude ]]; then
    PATH="/usr/local/bin:${PATH}"
  else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: claude CLI not found" >> "${LOG_FILE}"
    exit 1
  fi
fi

CONFIG_FILE="${REPO_DIR}/.claude/agent-pm/config.yaml"
MODEL="$(python3 -c "
import yaml
try:
    c = yaml.safe_load(open('${CONFIG_FILE}'))
    print((c.get('model') or {}).get('dispatch', 'claude-sonnet-4-6'))
except Exception:
    print('claude-sonnet-4-6')
" 2>/dev/null)"
MODEL="${MODEL:-claude-sonnet-4-6}"

echo "===" >> "${LOG_FILE}"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] weekly start (model=${MODEL})" >> "${LOG_FILE}"

PROMPT="Read and execute the instructions in ${TRIGGER_FILE}. This is the scheduled Monday weekly consolidation run. Follow every step exactly as written."

cd "${REPO_DIR}"
claude -p "${PROMPT}" \
  --model "${MODEL}" \
  --dangerously-skip-permissions \
  --allowedTools 'mcp__claude_ai_Linear__*,Read,Write,Edit,Bash,Grep,Glob' \
  >> "${LOG_FILE}" 2>&1

STATUS=$?

echo "[$(date '+%Y-%m-%d %H:%M:%S')] weekly end (exit=${STATUS})" >> "${LOG_FILE}"
exit ${STATUS}
