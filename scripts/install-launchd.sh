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

LABELS=(
  "com.mssanwel.agent-pm.dispatch"
  "com.mssanwel.agent-pm.weekly"
  "com.mssanwel.agent-pm.security"
)

ACTION="${1:-install}"

if [[ "${ACTION}" == "uninstall" ]]; then
  echo "→ Unloading launchd jobs…"
  for LABEL in "${LABELS[@]}"; do
    PLIST="${DST_DIR}/${LABEL}.plist"
    launchctl unload "${PLIST}" 2>/dev/null || true
    rm -f "${PLIST}"
    echo "  ✓ Removed ${PLIST}"
  done
  echo "✓ Uninstalled"
  exit 0
fi

echo "→ Installing Agent PM launchd jobs…"
mkdir -p "${DST_DIR}"

for LABEL in "${LABELS[@]}"; do
  SRC="${SRC_DIR}/${LABEL}.plist"
  DST="${DST_DIR}/${LABEL}.plist"
  if [[ ! -f "${SRC}" ]]; then
    echo "  ✗ Missing source plist: ${SRC}"
    continue
  fi
  cp "${SRC}" "${DST}"
  launchctl unload "${DST}" 2>/dev/null || true
  launchctl load "${DST}"
  echo "  ✓ Loaded ${LABEL}"
done

# Verify
echo
echo "→ Status:"
launchctl list | grep -E "agent-pm" || echo "  (neither job found — check ${DST_DIR})"

echo
echo "✓ Install complete."
echo
echo "Next steps:"
echo "  • If pause.flag is in place, dispatcher will exit cheap until you remove it:"
echo "      rm ${REPO_DIR}/.claude/agent-pm/pause.flag"
echo "  • Tail dispatch log:"
echo "      tail -f ${REPO_DIR}/.claude/agent-pm/logs/dispatch-\$(date +%Y-%m-%d).log"
echo "  • Tail security log:"
echo "      tail -f ${REPO_DIR}/.claude/agent-pm/logs/security-\$(date +%Y-%m-%d).log"
echo "  • Force an immediate dispatch run:"
echo "      launchctl start com.mssanwel.agent-pm.dispatch"
echo "  • Force an immediate security audit:"
echo "      launchctl start com.mssanwel.agent-pm.security"
