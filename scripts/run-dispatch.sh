#!/bin/zsh
# Agent PM — local dispatch runner
# Invoked by launchd every 10 minutes (see ~/Library/LaunchAgents/com.mssanwel.agent-pm.dispatch.plist)
# Runs Claude Code against the dispatch trigger prompt with the repo as cwd.

set -u
set -o pipefail

REPO_DIR="${HOME}/code/agent-pm"
TRIGGER_FILE="${REPO_DIR}/.claude/triggers/agent-pm-dispatch.md"
LOG_DIR="${REPO_DIR}/.claude/agent-pm/logs"
LOCK_FILE="${REPO_DIR}/.claude/agent-pm/dispatch.lock"
PAUSE_FLAG="${REPO_DIR}/.claude/agent-pm/pause.flag"

mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/dispatch-$(date +%Y-%m-%d).log"

# --- pause flag: fastest exit path ---
if [[ -f "${PAUSE_FLAG}" ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] paused — exit" >> "${LOG_FILE}"
  exit 0
fi

# --- concurrency guard: don't stack runs ---
if [[ -f "${LOCK_FILE}" ]]; then
  # Stale-lock check: anything older than 20 min is considered crashed
  if [[ -n "$(find "${LOCK_FILE}" -mmin +20 2>/dev/null)" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] stale lock (>20min) — removing and continuing" >> "${LOG_FILE}"
    rm -f "${LOCK_FILE}"
  else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] previous run still in progress — skip" >> "${LOG_FILE}"
    exit 0
  fi
fi

# --- trigger file must exist ---
if [[ ! -f "${TRIGGER_FILE}" ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: trigger file missing at ${TRIGGER_FILE}" >> "${LOG_FILE}"
  exit 1
fi

# --- claude CLI must exist ---
if ! command -v claude >/dev/null 2>&1; then
  # launchd's PATH is minimal — fall back to Homebrew location explicitly
  if [[ -x /opt/homebrew/bin/claude ]]; then
    PATH="/opt/homebrew/bin:${PATH}"
  elif [[ -x /usr/local/bin/claude ]]; then
    PATH="/usr/local/bin:${PATH}"
  else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: claude CLI not found" >> "${LOG_FILE}"
    exit 1
  fi
fi

# --- take the lock ---
date > "${LOCK_FILE}"
trap 'rm -f "${LOCK_FILE}"' EXIT INT TERM

# --- log run start ---
echo "===" >> "${LOG_FILE}"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] dispatch start" >> "${LOG_FILE}"

# --- run dispatch ---
# Prompt: "Execute the dispatch trigger instructions at TRIGGER_FILE."
# -p = non-interactive (headless) mode
# --cwd sets project context so MCPs + .claude/ config resolve correctly
PROMPT="Read and execute the instructions in ${TRIGGER_FILE}. This is a scheduled dispatch run. Follow every phase exactly as written. Do not ask for confirmation on any step — this is unattended. Use dangerous-skip-permissions=false behaviour: if a tool is blocked, surface the error; never mutate beyond what the trigger authorises."

cd "${REPO_DIR}"
claude -p "${PROMPT}" \
  --dangerously-skip-permissions \
  --allowedTools 'mcp__claude_ai_Linear__*,Read,Write,Edit,Bash,Grep,Glob' \
  >> "${LOG_FILE}" 2>&1

STATUS=$?

echo "[$(date '+%Y-%m-%d %H:%M:%S')] dispatch end (exit=${STATUS})" >> "${LOG_FILE}"
exit ${STATUS}
