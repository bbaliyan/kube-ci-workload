#!/usr/bin/env bash
# git calls this with the prompt as $1, for example
#   Password for 'https://oauth2@gitlab.example:8443':
# It answers with the token for the host named in the prompt. A prompt for any
# other host gets no answer, so a token never goes to the wrong server.
set -eu

case "$1" in
  "Password for '"*"@${SYNC_DST_HOST:?}'"*) token="${DST_TOKEN:?}" ;;
  "Password for '"*"@${SYNC_SRC_HOST:?}'"*) token="${SRC_TOKEN:?}" ;;
  *) echo "askpass: no token for this prompt (mirror host ${SYNC_DST_HOST}, source host ${SYNC_SRC_HOST}): $1" >&2; exit 1 ;;
esac
# The length shows an empty token in a log. It does not show the token.
echo "askpass: answering with a token of ${#token} characters" >&2
printf '%s\n' "$token"
