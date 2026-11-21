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
import urllib.error
import urllib.request
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime

# A review is incomplete if the note starts with the failure text, or if a notice line of the note
# (a line that starts with the info or the warning sign) says so. Code quoted in a review does not count.
INCOMPLETE = ("Failed to review PR", "chunk(s) failed", "were not included in this review")
NOTICE_LINE = re.compile("^[ℹ⚠]")
DETAILS = re.compile(r"^- (Model|Tokens|Time cost|AI calls):")


def heading(env):
    """The title of the final note. pr-agent can change it with the setting review_heading."""
    return env.get("PR_AGENT_REVIEW_HEADING", "PR Reviewer Guide")


def is_final(note, title="PR Reviewer Guide"):
    return "Preparing review" not in note and (title in note or "Failed to review PR" in note)


def is_review_note(note, title="PR Reviewer Guide"):
    return is_final(note, title) or "Preparing review" in note


def judge(note):
    """Return (lines to print, reasons the review is incomplete) for a final note."""
    lines = [line for line in note.splitlines() if "Chunked review" in line]
    lines = lines or ["Chunked review: none (one model call)"]
    lines += [line for line in note.splitlines() if DETAILS.match(line)]
    notices = [line for line in note.splitlines() if NOTICE_LINE.match(line)]
    return lines, [text for text in INCOMPLETE
                   if note.startswith(text) or any(text in line for line in notices)]


def describe(error):
    if isinstance(error, urllib.error.HTTPError):
        return f"HTTP {error.code} {error.read().decode(errors='replace')[:200]}"
    return str(error)


def call(url, headers, data=None, insecure=False):
    """Return (body, Date header). insecure: a lab ingress may serve a self-signed certificate."""
    context = ssl._create_unverified_context() if insecure else None
    request = urllib.request.Request(url, data=data, headers=headers)
    with urllib.request.urlopen(request, timeout=200, context=context) as response:
        return response.read().decode(), response.headers.get("Date")


def newest_bot_note(env, since):
    url = (f"{env['GITLAB_API_URL']}/projects/{env['CI_MERGE_REQUEST_PROJECT_ID']}/merge_requests/"
           f"{env['CI_MERGE_REQUEST_IID']}/notes?order_by=updated_at&sort=desc&per_page=20")
    notes = json.loads(call(url, {"JOB-TOKEN": env["CI_JOB_TOKEN"]})[0])
    bot = re.compile(env.get("PR_AGENT_BOT_PATTERN", "_bot_"))
    for note in notes:  # newest first
        if (not note["system"] and bot.search(note["author"]["username"])
                and note["updated_at"][:19] > since and is_review_note(note["body"], heading(env))):
            return note["body"]
    return None


def main(env):
    # A Windows runner pipes the output as cp1252, which cannot print the signs in the notes.
    for stream in (sys.stdout, sys.stderr):
        stream.reconfigure(encoding="utf-8", errors="replace")
    wait = int(env.get("PR_AGENT_WAIT_MINUTES", "25")) * 60
    poll = int(env.get("PR_AGENT_POLL_SECONDS", "20"))
    insecure = env.get("PR_AGENT_INSECURE") == "1"
    event = {
        "object_kind": "note", "event_type": "note",
        "user": {"id": int(env["GITLAB_USER_ID"]), "username": env["GITLAB_USER_LOGIN"]},
        "merge_request": {"url": f"{env['CI_MERGE_REQUEST_PROJECT_URL']}/-/merge_requests/{env['CI_MERGE_REQUEST_IID']}"},
        "object_attributes": {"note": "/review --config.reaction_on_start="},
    }
    started = time.monotonic()
    try:
        _, server_date = call(env["PR_AGENT_URL"], {"Authorization": f"Bearer {env['PR_AGENT_ID_TOKEN']}",
                                                    "Content-Type": "application/json"},
                              json.dumps(event).encode(), insecure)
    except Exception as error:
        print(f"GATE FAILED: pr-agent refused the review request: {describe(error)}", file=sys.stderr)
        return 1
    # Use the clock of the server, not of this runner, so clock skew cannot hide or fake a note.
    now = parsedate_to_datetime(server_date) if server_date else datetime.now(timezone.utc)
    since = now.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")
    print(f"Review requested at {since} UTC. Waiting up to {wait // 60} minutes.")
    while time.monotonic() - started < wait:
        time.sleep(poll)
        try:
            note = newest_bot_note(env, since)
        except urllib.error.HTTPError as error:
            if 400 <= error.code < 500:
                print(f"GATE FAILED: GitLab refused to list the notes: {describe(error)}. "
                      "Use a project access token (see the README).", file=sys.stderr)
                return 1
            print(f"Could not read the notes (retrying): {describe(error)}")
            continue
        except Exception as error:
            print(f"Could not read the notes (retrying): {describe(error)}")
            continue
        if note is None:
            continue
        if not is_final(note, heading(env)):
            print(note.splitlines()[0])
            continue
        lines, reasons = judge(note)
        print(f"Final note after {int(time.monotonic() - started)}s.", *lines, sep="\n")
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
        ("## PR Reviewer Guide\nℹ️ 3 chunk(s) failed", True, ["chunk(s) failed"]),
        ("## PR Reviewer Guide\n⚠️ The following files were not included in this review because of the token budget",
         True, ["were not included in this review"]),
        ("## PR Reviewer Guide\n```\nprint('chunk(s) failed')\n```", True, []),
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
    if not is_final("## Review Summary", "Review Summary") or is_final("## PR Reviewer Guide", "Review Summary"):
        bad += 1
        print("FAIL custom heading")
    print("self-test:", "FAILED" if bad else f"{len(cases) + 2} checks passed")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(self_test() if "--self-test" in sys.argv else main(dict(os.environ)))
