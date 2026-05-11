#!/usr/bin/env bash
# block-secret-writes.sh — PreToolUse hook. Blocks Edit/Write calls
# that target classic secret-bearing paths (.env, **/secrets/**, *.pem)
# or contain assignment lines that look like real credentials. Catches
# the Claude-side mistake before it ever reaches a commit; gitleaks
# in pr-review.yml is the second line of defence.
#
# Allows .example files (intentional templates) and obvious
# placeholders (anything <16 chars, anything containing $/{/<).

set -euo pipefail

input="$(cat)"
file_path="$(jq -r '.tool_input.file_path // empty' <<<"$input")"
content="$( jq -r '.tool_input.content // .tool_input.new_string // empty' <<<"$input")"

block() {
  printf 'block-secret-writes: %s\n' "$1" >&2
  exit 2
}

# Path-based block. Allow .example variants.
case "$file_path" in
  *.example|*.example.*) ;;
  */.env|*/.env.*|.env|.env.*)
    block "${file_path}: .env-style path. Move secrets into Doppler (\`doppler run --\` injects them) or ~/.config/tod/secrets/."
    ;;
  */secrets/*|*/.secrets/*)
    block "${file_path}: matches **/secrets/** path pattern. Don't commit secret material."
    ;;
  *.pem|*.key)
    block "${file_path}: .pem/.key files are typically private keys — don't commit."
    ;;
esac

# Content-based block. Pattern: KEY=value where KEY looks token-y and
# value is plausibly real (≥16 chars from a token-shaped charset).
# Misses base64-with-padding edge cases on purpose — gitleaks catches those in CI.
if [[ -n "$content" ]] \
   && printf '%s\n' "$content" \
      | grep -qE '(TOKEN|SECRET|API_KEY|PASSWORD|PRIVATE_KEY|ACCESS_KEY)=["'"'"']?[A-Za-z0-9+/=:._-]{16,}'
then
  block "content contains a TOKEN/SECRET/API_KEY/PASSWORD assignment with a plausibly-real value. Move it to Doppler."
fi

exit 0
