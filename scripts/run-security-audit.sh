#!/bin/zsh
# Agent PM — daily security audit
# Invoked by launchd at 19:00 local time (~/Library/LaunchAgents/com.mssanwel.agent-pm.security.plist)
#
# Flow:
#   1. Collect raw system snapshot (no LLM)
#   2. Pass to `claude -p` with the security trigger prompt
#   3. Claude writes a dated report and emits SECURITY_STATUS: CLEAR | ANOMALIES
#   4. On ANOMALIES, this script reads the report and creates a Linear issue
#   5. Append heartbeat JSON line to heartbeat.jsonl

set -u
set -o pipefail

REPO_DIR="${HOME}/code/agent-pm"
TRIGGER_FILE="${REPO_DIR}/.claude/triggers/agent-pm-security.md"
BASELINE="${REPO_DIR}/.claude/agent-pm/security-baseline.yaml"
REPORTS_DIR="${REPO_DIR}/.claude/agent-pm/security-reports"
LOG_DIR="${REPO_DIR}/.claude/agent-pm/logs"
HEARTBEAT_FILE="${REPO_DIR}/.claude/agent-pm/heartbeat.jsonl"
CONFIG_FILE="${REPO_DIR}/.claude/agent-pm/config.yaml"

mkdir -p "${REPORTS_DIR}" "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/security-$(date +%Y-%m-%d).log"
SNAPSHOT_FILE="$(mktemp -t agent-pm-security-XXXXXX)"
trap 'rm -f "${SNAPSHOT_FILE}"' EXIT INT TERM

echo "===" >> "${LOG_FILE}"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] security audit start" >> "${LOG_FILE}"

# --- PATH for launchd (same pattern as other runners) ---
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

#############################################
# 1. COLLECT raw snapshot (bash only, no LLM)
#############################################

{
  echo "# Agent PM security snapshot — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# Baseline: ${BASELINE}"
  echo

  echo "[processes]"
  ps -eo pid,user,comm | grep -iE 'claude|agent-pm' | grep -v grep | head -30
  echo

  echo "[launchd]"
  launchctl list | awk 'NR==1 || /com\./' | head -60
  echo

  echo "[network]"
  # Established TCP connections from claude processes
  lsof -iTCP -sTCP:ESTABLISHED -P -n 2>/dev/null | awk '/claude/ {print $1, $2, $9}' | head -50
  echo

  echo "[files_protected_paths]"
  # Any modifications in the last 24h under the protected paths from baseline
  for p in ~/.ssh ~/.aws ~/.gnupg ~/Library/Keychains /etc /usr/local/bin /opt/homebrew/bin; do
    if [[ -e "$p" ]]; then
      find "$p" -type f -mtime -1 2>/dev/null | head -10 | while read -r f; do
        ts=$(stat -f '%Sm' -t '%Y-%m-%dT%H:%M:%S' "$f" 2>/dev/null)
        printf '%s  %s\n' "$ts" "$f"
      done
    fi
  done
  echo

  echo "[files_allowed_paths]"
  # Recent writes in agent-pm + workspace — for visibility, not anomaly
  find ~/code/agent-pm ~/Documents/AI-Workspace -type f -mtime -1 2>/dev/null \
    ! -path '*/.git/*' ! -path '*/node_modules/*' ! -path '*/logs/*' \
    | head -30
  echo

  echo "[git_state]"
  if [[ -d "${REPO_DIR}/.git" ]]; then
    cd "${REPO_DIR}"
    echo "remotes:"
    git remote -v
    echo "status:"
    git status --short | head -20
    echo "commits_last_24h:"
    git log --since='24 hours ago' --format='%H | %an <%ae> | %s'
    echo "untracked:"
    git ls-files --others --exclude-standard | head -10
  fi
  echo

  echo "[agent_pm]"
  echo "pause_flag=$([[ -f "${REPO_DIR}/.claude/agent-pm/pause.flag" ]] && echo PRESENT || echo ABSENT)"
  echo "config_yaml=$([[ -f "${CONFIG_FILE}" ]] && echo OK || echo MISSING)"
  echo "registry_yaml=$([[ -f "${REPO_DIR}/.claude/agent-pm/skill-registry.yaml" ]] && echo OK || echo MISSING)"
  echo "dispatch_trigger=$([[ -f "${REPO_DIR}/.claude/triggers/agent-pm-dispatch.md" ]] && echo OK || echo MISSING)"
  # Forbidden files
  for fp in "${REPO_DIR}/.claude/agent-pm/.env" "${REPO_DIR}/.claude/agent-pm/secrets.yaml" "${REPO_DIR}/.claude/agent-pm/auth.json"; do
    if [[ -e "${fp}" ]]; then echo "forbidden_file_found=${fp}"; fi
  done
  echo

  echo "[cost]"
  if [[ -f "${HEARTBEAT_FILE}" ]]; then
    TODAY_UTC=$(date -u +%Y-%m-%d)
    YESTERDAY_UTC=$(date -u -v-1d +%Y-%m-%d 2>/dev/null || date -u --date='yesterday' +%Y-%m-%d)
    TODAY_COST=$(grep "\"ts\":\"${TODAY_UTC}" "${HEARTBEAT_FILE}" 2>/dev/null \
      | python3 -c "import sys,json; print(sum(json.loads(l).get('cost_usd',0) for l in sys.stdin if l.strip()))" 2>/dev/null || echo "0")
    YDAY_COST=$(grep "\"ts\":\"${YESTERDAY_UTC}" "${HEARTBEAT_FILE}" 2>/dev/null \
      | python3 -c "import sys,json; print(sum(json.loads(l).get('cost_usd',0) for l in sys.stdin if l.strip()))" 2>/dev/null || echo "0")
    echo "today_usd=${TODAY_COST}"
    echo "yesterday_usd=${YDAY_COST}"
  else
    echo "today_usd=0"
    echo "yesterday_usd=0"
    echo "note=no heartbeat file yet"
  fi

} > "${SNAPSHOT_FILE}"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] snapshot collected → $(wc -l <"${SNAPSHOT_FILE}") lines" >> "${LOG_FILE}"

#############################################
# 2. INVOKE claude to analyze + write report
#############################################

MODEL="$(python3 -c "
import yaml
try:
    c = yaml.safe_load(open('${CONFIG_FILE}'))
    print((c.get('model') or {}).get('dispatch', 'claude-sonnet-4-6'))
except Exception:
    print('claude-sonnet-4-6')
" 2>/dev/null)"
MODEL="${MODEL:-claude-sonnet-4-6}"

PROMPT="Read and execute the instructions in ${TRIGGER_FILE}. The raw system snapshot to analyze is at: ${SNAPSHOT_FILE}. Today is $(date +%Y-%m-%d) in ${TZ:-local time}. This is an unattended scheduled run — do not ask for confirmation on any step. Write the report file as instructed and emit the SECURITY_STATUS marker line and the HEARTBEAT_JSON line on separate lines in your output."

echo "[$(date '+%Y-%m-%d %H:%M:%S')] analyze (model=${MODEL})" >> "${LOG_FILE}"

cd "${REPO_DIR}"
claude -p "${PROMPT}" \
  --model "${MODEL}" \
  --dangerously-skip-permissions \
  --allowedTools 'mcp__claude_ai_Linear__*,Read,Write,Edit,Bash,Grep,Glob' \
  >> "${LOG_FILE}" 2>&1

ANALYZE_STATUS=$?
echo "[$(date '+%Y-%m-%d %H:%M:%S')] analyze exit=${ANALYZE_STATUS}" >> "${LOG_FILE}"

#############################################
# 3. Parse SECURITY_STATUS and act
#############################################

STATUS_LINE="$(grep -m1 '^SECURITY_STATUS: ' "${LOG_FILE}" | tail -1)"
REPORT_PATH="${REPORTS_DIR}/$(date +%Y-%m-%d).md"

if [[ "${STATUS_LINE}" == *"ANOMALIES"* ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ANOMALIES detected — creating Linear issue" >> "${LOG_FILE}"
  # Extract report path from marker if provided, else use dated default
  MARKER_PATH="$(printf '%s' "${STATUS_LINE}" | sed -n 's/.*report_path=\([^ ]*\).*/\1/p')"
  [[ -n "${MARKER_PATH}" ]] && REPORT_PATH="${MARKER_PATH}"
  # Create Linear issue via claude (short invocation, just the write)
  REPORT_BODY="$(cat "${REPORT_PATH}" 2>/dev/null || echo "Report file not found: ${REPORT_PATH}")"
  ESCAPED_BODY="$(printf '%s' "${REPORT_BODY}" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))")"
  CREATE_PROMPT="Create a Linear issue via mcp__claude_ai_Linear__save_issue: team='Mssanwel', title='Agent PM — security anomaly $(date +%Y-%m-%d)', labels=['agent-pm','ops'], state='Human Review', priority=2, description=${ESCAPED_BODY}. Do not do anything else. Reply only 'done' or the error."
  claude -p "${CREATE_PROMPT}" \
    --model "${MODEL}" \
    --dangerously-skip-permissions \
    --allowedTools 'mcp__claude_ai_Linear__save_issue' \
    >> "${LOG_FILE}" 2>&1
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Linear issue created" >> "${LOG_FILE}"
elif [[ "${STATUS_LINE}" == *"CLEAR"* ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] CLEAR — report at ${REPORT_PATH}" >> "${LOG_FILE}"
else
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: no SECURITY_STATUS marker in output" >> "${LOG_FILE}"
fi

#############################################
# 4. Heartbeat append (from bash, same pattern as dispatch)
#############################################

HEARTBEAT_LINE="$(grep -m1 '^HEARTBEAT_JSON: ' "${LOG_FILE}" | tail -1 | sed 's/^HEARTBEAT_JSON: //')"
if [[ -n "${HEARTBEAT_LINE}" ]]; then
  printf '%s\n' "${HEARTBEAT_LINE}" >> "${HEARTBEAT_FILE}"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] heartbeat appended" >> "${LOG_FILE}"
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] security audit end (exit=${ANALYZE_STATUS})" >> "${LOG_FILE}"
exit ${ANALYZE_STATUS}
