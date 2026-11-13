#!/bin/bash
# Max Connection connection helper (macOS).
# Watches the clipboard for 30 minutes. When you press Copy next to a plugin URL in
# Chat On Steroids (http://127.0.0.1:<port>/mcp/<surface>/<secret>), it swaps the local
# address for this Mac's permanent hostname and puts the result back on the clipboard.
HOST="$1"; PORT="$2"; NAME="${3:-$(scutil --get ComputerName)}"
open "https://chatgpt.com/plugins"
open -a "Chat On Steroids" || true
osascript -e "display notification \"Chat On Steroids > Settings > Setup > step 5: press Copy next to each MCP SERVER URL. It is converted to https://$HOST automatically. In ChatGPT name them 'Max Connection - $NAME - Core' / '- Desktop', No authentication.\" with title \"Max Connection connected\""
end=$(( $(date +%s) + 1800 ))
while [ "$(date +%s)" -lt "$end" ]; do
  clip="$(pbpaste 2>/dev/null)"
  if [[ "$clip" =~ ^http://127\.0\.0\.1:${PORT}/mcp/(core|desktop)/([A-Za-z0-9_-]{43})$ ]]; then
    surface="${BASH_REMATCH[1]}"
    printf 'https://%s/mcp/%s/%s' "$HOST" "$surface" "${BASH_REMATCH[2]}" | pbcopy
    osascript -e "display notification \"The $surface URL is ready - paste it into ChatGPT.\" with title \"Max Connection\""
  fi
  sleep 1
done
