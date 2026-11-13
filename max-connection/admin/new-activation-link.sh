#!/bin/bash
# macOS/Linux twin of New-ActivationLink.ps1. Needs wrangler signed in to the Cloudflare account.
#   ./new-activation-link.sh [hours] [note]
set -euo pipefail
HOURS="${1:-24}"; NOTE="$(printf '%s' "${2:-}" | tr -cd 'A-Za-z0-9 ._-')"
CODE="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n')"
HASH="$(printf '%s' "$CODE" | shasum -a 256 | awk '{print $1}')"
NOW="$(date +%s)"; EXP=$(( NOW + HOURS * 3600 ))
cd "$(dirname "$0")/../worker"
npx --yes wrangler@4 d1 execute max-connection --remote \
  --command "INSERT INTO invites (code_hash, created_at, expires_at, note, state) VALUES ('$HASH', $NOW, $EXP, '$NOTE', 'new');" >/dev/null
LINK="https://enroll.akior.io/activate#$CODE"
if command -v pbcopy >/dev/null; then printf '%s' "$LINK" | pbcopy; echo "Activation link created (valid ${HOURS}h, single use) and copied to the clipboard."
else echo "$LINK"; fi
