#!/bin/bash
# Model Bar's automatic Claude setup reuses the official bridge installer at a
# pinned revision. It never copies logins, replaces an existing bridge service,
# or restarts Codex. Retain the checkout: launchd runs the bridge from there.
set -euo pipefail
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
BASE="$HOME/Library/Application Support/Codex Model Bar"
COMPLETE="$BASE/claude-setup-complete"
REVISION=6c05c310455601fde62fc10257011b484c498f0d
if [ -f "$COMPLETE" ]; then echo 'Claude setup already completed'; exit 0; fi
if [ -f "$HOME/Library/LaunchAgents/com.codex-claude-bridge.plist" ]; then
  INSTALLED=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:1' "$HOME/Library/LaunchAgents/com.codex-claude-bridge.plist" 2>/dev/null || true)
  case "$INSTALLED" in
    "$BASE/Claude Bridge/"*)
      # Retry only our own failed setup. A healthy service may have live sessions.
      if curl --max-time 2 -fsS http://127.0.0.1:18787/health >/dev/null 2>&1; then
        echo 'Healthy existing Claude bridge left unchanged'; exit 0
      fi ;;
    *) echo 'Existing Claude bridge left unchanged'; exit 0 ;;
  esac
fi
if ! command -v claude >/dev/null 2>&1; then echo 'Claude Code not installed; setup skipped'; exit 0; fi
for tool in node npm git; do
  if ! command -v "$tool" >/dev/null 2>&1; then echo "Claude setup needs $tool"; exit 1; fi
done
TARGET="$BASE/Claude Bridge/$REVISION"
mkdir -p "$(dirname "$TARGET")"
# A PID lock recovers from a crashed setup and prevents two Model Bar instances from competing on setup.
LOCK="$BASE/claude-setup.lock"
if ! /usr/bin/shlock -p "$$" -f "$LOCK"; then echo 'Claude setup already running'; exit 1; fi
trap 'rm -f "$LOCK"' EXIT
if [ ! -d "$TARGET/.git" ]; then
  if [ -e "$TARGET" ]; then echo 'Incomplete checkout left unchanged; inspect setup.log'; exit 1; fi
  git -c core.hooksPath=/dev/null -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30 clone --no-checkout https://github.com/EthanSK/claude-in-codex.git "$TARGET"
  git -c core.hooksPath=/dev/null -C "$TARGET" checkout --detach "$REVISION"
fi
[ "$(git -C "$TARGET" rev-parse HEAD)" = "$REVISION" ]
[ -z "$(git -C "$TARGET" status --porcelain)" ]
# The bridge owns provider routing, config backups, npm dependencies and launchd.
/bin/bash "$TARGET/scripts/install.sh"
printf '%s\n' "$REVISION" > "$COMPLETE"
echo 'Claude bridge configured. Restart Codex to load Opus 5.5 and Fable 5.1.'
