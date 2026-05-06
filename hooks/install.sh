#!/usr/bin/env bash
# install.sh —— 把桌宠 hook 注入 ~/.claude/settings.json。
# 幂等：重复执行只会覆盖自己的条目。
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_BIN="$SCRIPT_DIR/claude-pet-hook"

if [ ! -f "$HOOK_BIN" ]; then
  echo "错误：找不到 $HOOK_BIN"
  exit 1
fi
chmod +x "$HOOK_BIN"

SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

if ! command -v jq >/dev/null 2>&1; then
  echo "错误：需要 jq。请先 brew install jq"
  exit 1
fi

# 备份
cp "$SETTINGS" "${SETTINGS}.bak.$(date +%s)"

TMP="$(mktemp)"
jq --arg cmd "$HOOK_BIN" '
  def hook(name): {hooks: [{type: "command", command: ($cmd + " " + name)}]};
  .hooks = (.hooks // {})
  | .hooks.SessionStart     = [hook("SessionStart")]
  | .hooks.UserPromptSubmit = [hook("UserPromptSubmit")]
  | .hooks.PreToolUse       = [hook("PreToolUse")]
  | .hooks.PostToolUse      = [hook("PostToolUse")]
  | .hooks.Notification     = [hook("Notification")]
  | .hooks.Stop             = [hook("Stop")]
  | .hooks.SubagentStop     = [hook("SubagentStop")]
  | .hooks.PreCompact       = [hook("PreCompact")]
' "$SETTINGS" > "$TMP"
mv "$TMP" "$SETTINGS"

echo "✓ 已注入 hook 到 $SETTINGS"
echo "✓ 备份在 ${SETTINGS}.bak.*"
echo ""
echo "下一步：在项目根目录运行  swift run ClaudePet"
