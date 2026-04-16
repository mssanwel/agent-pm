#!/bin/zsh
# Agent PM — one-shot installer for launchd jobs
#
# Usage:
#   ./install-launchd.sh           # install + load
#   ./install-launchd.sh uninstall # unload + remove

set -eu

REPO_DIR="${HOME}/code/agent-pm"
SRC_DIR="${REPO_DIR}/scripts/launchd"
DST_DIR="${HOME}/Library/LaunchAgents"

DISPATCH_LABEL="com.mssanwel.agent-pm.dispatch"
WEEKLY_LABEL="com.mssanwel.agent-pm.weekly"

DISPATCH_PLIST="${DST_DIR}/${DISPATCH_LABEL}.plist"
WEEKLY_PLIST="${DST_DIR}/${WEEKLY_LABEL}.plist"

ACTION="${1:-install}"

if [[ "${ACTION}" == "uninstall" ]]; then
  echo "→ Unloading launchd jobs…"
  launchctl unload "${DISPATCH_PLIST}" 2>/dev/null || true
  launchctl unload "${WEEKLY_PLIST}" 2>/dev/null || true
  rm -f "${DISPATCH_PLIST}" "${WEEKLY_PLIST}"
  echo "→ Removed ${DISPATCH_PLIST}"
  echo "→ Removed ${WEEKLY_PLIST}"
  echo "✓ Uninstalled"
  exit 0
fi

echo "→ Installing Agent PM launchd jobs…"

# Copy plists from repo into ~/Library/LaunchAgents
mkdir -p "${DST_DIR}"
cp "${SRC_DIR}/${DISPATCH_LABEL}.plist" "${DISPATCH_PLIST}"
cp "${SRC_DIR}/${WEEKLY_LABEL}.plist"   "${WEEKLY_PLIST}"
echo "  ✓ Copied plists to ${DST_DIR}"

# Unload any previous version first (idempotent)
launchctl unload "${DISPATCH_PLIST}" 2>/dev/null || true
launchctl unload "${WEEKLY_PLIST}"   2>/dev/null || true

# Load
launchctl load "${DISPATCH_PLIST}"
launchctl load "${WEEKLY_PLIST}"
echo "  ✓ Loaded into launchctl"

# Verify
echo
echo "→ Status:"
launchctl list | grep -E "agent-pm" || echo "  (neither job found — check ${DST_DIR})"

echo
echo "✓ Install complete."
echo
echo "Next steps:"
echo "  • pause.flag is still in place — dispatcher will exit cheap until you remove it:"
echo "      rm ${REPO_DIR}/.claude/agent-pm/pause.flag"
echo "  • Tail logs:"
echo "      tail -f ${REPO_DIR}/.claude/agent-pm/logs/dispatch-\$(date +%Y-%m-%d).log"
echo "  • Force an immediate dispatch run:"
echo "      launchctl start ${DISPATCH_LABEL}"
