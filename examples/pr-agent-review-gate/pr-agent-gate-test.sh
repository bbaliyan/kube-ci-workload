#!/bin/sh
# Tests the decision functions of pr-agent-gate.sh against saved review notes.
export PR_AGENT_GATE_SOURCE_ONLY=1
. "$(dirname "$0")/pr-agent-gate.sh"
dir=$(dirname "$0")/fixtures
bad=0

expect_check() { # file, expected exit code
  if check_review_note < "$dir/$1" > /dev/null 2>&1; then got=0; else got=1; fi
  if [ "$got" = "$2" ]; then echo "ok   check  $1 -> $got"; else echo "FAIL check  $1 -> $got, expected $2"; bad=1; fi
}
expect_final() { # file, expected exit code
  if is_final_note "$(cat "$dir/$1")"; then got=0; else got=1; fi
  if [ "$got" = "$2" ]; then echo "ok   final  $1 -> $got"; else echo "FAIL final  $1 -> $got, expected $2"; bad=1; fi
}

expect_check review-chunked-pass.md 0
expect_check review-not-included.md 1
expect_check review-chunks-failed.md 1
expect_check review-failed.md 1
expect_final review-chunked-pass.md 0
expect_final review-failed.md 0
expect_final review-progress.md 1
exit $bad
