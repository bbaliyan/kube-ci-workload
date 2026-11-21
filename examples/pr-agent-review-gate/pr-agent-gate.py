#!/usr/bin/env python3
"""Ask pr-agent for a review of a merge request and fail the job if the review is incomplete.

The job sends a comment event to pr-agent, polls the notes of the merge request until the final
review note appears, and fails if that note reports a failed chunk, a failed review or files that
were not reviewed. It uses only the standard library, so it runs the same on a Linux and on a
Windows runner. Test the decision logic with: python3 pr-agent-gate.py --self-test
"""
import json
import os
import re
import ssl
import sys
import time
import urllib.request
from datetime import datetime, timezone

# A final note that contains one of these is not a complete review.
INCOMPLETE = ("Failed to review PR", "chunk(s) failed", "were not included in this review")
FINAL = re.compile(r"PR Reviewer Guide|Failed to review PR")
ANY_REVIEW_NOTE = re.compile(r"PR Reviewer Guide|Failed to review PR|Preparing review")
DETAILS = re.compile(r"^- (Model|Tokens|Time cost|AI calls):")


def is_final(note):
    return "Preparing review" not in note and bool(FINAL.search(note))


def judge(note):
    """Return (lines to print, reasons the review is incomplete) for a final note."""
    lines = [line for line in note.splitlines() if "Chunked review" in line]
    lines = lines or ["Chunked review: none (one model call)"]
    lines += [line for line in note.splitlines() if DETAILS.match(line)]
    return lines, [text for text in INCOMPLETE if text in note]


def call(url, headers, data=None, insecure=False):
    # insecure: a lab ingress may serve a self-signed certificate. With a real one, leave it off.
    context = ssl._create_unverified_context() if insecure else None
    request = urllib.request.Request(url, data=data, headers=headers)
    with urllib.request.urlopen(request, timeout=200, context=context) as response:
        return response.read().decode()


def newest_bot_note(env, since):
    url = (f"{env['GITLAB_API_URL']}/projects/{env['CI_PROJECT_ID']}/merge_requests/"
           f"{env['CI_MERGE_REQUEST_IID']}/notes?order_by=updated_at&sort=desc&per_page=20")
    notes = json.loads(call(url, {"JOB-TOKEN": env["CI_JOB_TOKEN"]}))
    bot = re.compile(env.get("PR_AGENT_BOT_PATTERN", "_bot_"))
    for note in notes:  # newest first
        if (not note["system"] and bot.search(note["author"]["username"])
                and note["updated_at"][:19] > since and ANY_REVIEW_NOTE.search(note["body"])):
            return note["body"]
    return None


def main(env):
    wait = int(env.get("PR_AGENT_WAIT_MINUTES", "25")) * 60
    poll = int(env.get("PR_AGENT_POLL_SECONDS", "20"))
    insecure = env.get("PR_AGENT_INSECURE") == "1"
    event = {
        "object_kind": "note", "event_type": "note",
        "user": {"id": int(env["GITLAB_USER_ID"]), "username": env["GITLAB_USER_LOGIN"]},
        "merge_request": {"url": f"{env['CI_MERGE_REQUEST_PROJECT_URL']}/-/merge_requests/{env['CI_MERGE_REQUEST_IID']}"},
        "object_attributes": {"note": "/review --config.reaction_on_start="},
    }
    since = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")
    try:
        call(env["PR_AGENT_URL"], {"Authorization": f"Bearer {env['PR_AGENT_ID_TOKEN']}",
                                   "Content-Type": "application/json"}, json.dumps(event).encode(), insecure)
    except Exception as error:
        print(f"GATE FAILED: pr-agent refused the review request: {error}", file=sys.stderr)
        return 1
    print(f"Review requested at {since} UTC. Waiting up to {wait // 60} minutes.")
    waited = 0
    while waited < wait:
        time.sleep(poll)
        waited += poll
        try:
            note = newest_bot_note(env, since)
        except Exception as error:
            print(f"Could not read the notes (retrying): {error}")
            continue
        if note is None:
            continue
        if not is_final(note):
            print(note.splitlines()[0])
            continue
        lines, reasons = judge(note)
        print(f"Final note after {waited}s.", *lines, sep="\n")
        for reason in reasons:
            print(f'GATE FAILED: the review note says "{reason}".', file=sys.stderr)
        return 1 if reasons else 0
    print(f"GATE FAILED: no final review note after {wait // 60} minutes.", file=sys.stderr)
    return 1


def self_test():
    ok = "## PR Reviewer Guide\n- Model: m\n- AI calls: 2"
    chunked = "## PR Reviewer Guide\nℹ️ **Chunked review:** reviewed in 4 chunks\n- Tokens: 10 in / 2 out"
    cases = [  # note, final?, reasons
        (ok, True, []),
        (chunked, True, []),
        ("## PR Reviewer Guide\n3 chunk(s) failed", True, ["chunk(s) failed"]),
        ("## PR Reviewer Guide\nThe following files were not included in this review because of the token budget",
         True, ["were not included in this review"]),
        ("Failed to review PR: model server unreachable", True, ["Failed to review PR"]),
        ("Preparing review... analyzed 4 of 8 chunks", False, None),
        ("Preparing review... a PR Reviewer Guide is coming", False, None),
    ]
    bad = 0
    for note, final, reasons in cases:
        got = is_final(note), (judge(note)[1] if is_final(note) else None)
        if got != (final, reasons):
            bad += 1
            print(f"FAIL {note[:40]!r}: got {got}, expected {(final, reasons)}")
    lines = judge(chunked)[0]
    if lines != ["ℹ️ **Chunked review:** reviewed in 4 chunks", "- Tokens: 10 in / 2 out"]:
        bad += 1
        print(f"FAIL report lines: {lines}")
    print("self-test:", "FAILED" if bad else f"{len(cases) + 1} checks passed")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(self_test() if "--self-test" in sys.argv else main(dict(os.environ)))
