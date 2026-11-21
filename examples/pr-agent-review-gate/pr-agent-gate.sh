#!/bin/sh
# Asks pr-agent for a review of a merge request, waits for the final review note, and fails
# the job if the review is incomplete. A shell script, because the decision is plain text
# matching and the job image holds only curl and jq. Source it with PR_AGENT_GATE_SOURCE_ONLY=1
# to test the functions.

# Exit 0 if the text is the final review or failure note, 1 if it is a progress note or other text.
is_final_note() {
  note=$1
  case $note in *"Preparing review"*) return 1 ;; esac
  case $note in *"PR Reviewer Guide"* | *"Failed to review PR"*) return 0 ;; esac
  return 1
}

# Reads a final note on stdin. Prints the chunk line and the run details.
# Exit 1 with a reason if the review failed or is incomplete, else exit 0.
check_review_note() {
  note=$(cat)
  printf '%s\n' "$note" | grep -E 'Chunked review' || echo "Chunked review: none (one model call)"
  printf '%s\n' "$note" | grep -E '^- (Model|Tokens|Time cost|AI calls):'
  verdict=0
  for reason in 'Failed to review PR' 'chunk(s) failed' 'were not included in this review'; do
    case $note in
      *"$reason"*) echo "GATE FAILED: the review note says \"$reason\"." >&2; verdict=1 ;;
    esac
  done
  return $verdict
}

# Prints the newest note of the review bot updated after $1 (an ISO time), as JSON, or nothing.
newest_bot_note() {
  curl -sS --fail-with-body -m 60 -H "JOB-TOKEN: $CI_JOB_TOKEN" \
    "$GITLAB_API_URL/projects/$CI_PROJECT_ID/merge_requests/$CI_MERGE_REQUEST_IID/notes?order_by=updated_at&sort=desc&per_page=20" |
    jq -c --arg since "$1" --arg bot "${PR_AGENT_BOT_PATTERN:-_bot_}" \
      '[.[] | select(.system == false and (.author.username | test($bot)) and (.updated_at[0:19] > $since)
        and (.body | test("PR Reviewer Guide|Failed to review PR|Preparing review")))] | first // empty'
}

main() {
  wait_seconds=$((${PR_AGENT_WAIT_MINUTES:-25} * 60))
  poll=${PR_AGENT_POLL_SECONDS:-20}
  printf '{"object_kind":"note","event_type":"note","user":{"id":%s,"username":"%s"},"merge_request":{"url":"%s/-/merge_requests/%s"},"object_attributes":{"note":"/review --config.reaction_on_start="}}' \
    "$GITLAB_USER_ID" "$GITLAB_USER_LOGIN" "$CI_MERGE_REQUEST_PROJECT_URL" "$CI_MERGE_REQUEST_IID" > event.json
  since=$(date -u +%Y-%m-%dT%H:%M:%S)
  # -k: the ingress serves the default self-signed certificate of Traefik, and the job
  # image holds no CA for it. With a real certificate, drop -k or pass --cacert.
  if ! curl --fail-with-body -sS -k -m 200 -H "Authorization: Bearer $PR_AGENT_ID_TOKEN" \
    -H "Content-Type: application/json" --data-binary @event.json "$PR_AGENT_URL"; then
    echo; echo "GATE FAILED: pr-agent refused the review request." >&2
    return 1
  fi
  echo; echo "Review requested at $since UTC. Waiting up to ${PR_AGENT_WAIT_MINUTES:-25} minutes."
  waited=0
  while [ "$waited" -lt "$wait_seconds" ]; do
    sleep "$poll"; waited=$((waited + poll))
    found=$(newest_bot_note "$since") || { echo "Could not read the notes (retrying)."; continue; }
    [ -n "$found" ] || continue
    body=$(printf '%s' "$found" | jq -r .body)
    if is_final_note "$body"; then
      echo "Final note after ${waited}s."
      printf '%s\n' "$body" | check_review_note
      return $?
    fi
    printf '%s\n' "$body" | head -n 1
  done
  echo "GATE FAILED: no final review note after ${PR_AGENT_WAIT_MINUTES:-25} minutes." >&2
  return 1
}

[ "${PR_AGENT_GATE_SOURCE_ONLY:-}" = 1 ] || main
