#!/usr/bin/env bash
# Copy the branches and tags of one repository from the source to the mirror.
#
#   SRC_BASE=... DST_BASE=... SRC_TOKEN=... DST_TOKEN=... ./sync-repo.sh <name> <cache-dir>
#
# Inputs (environment):
#   SRC_BASE   required. Where the source repositories live, for example https://github.com/<owner>.
#   DST_BASE   required. Where the mirror projects live, for example https://<gitlab>/<group>.
#   SRC_TOKEN  required. A read-only token for the source.
#   DST_TOKEN  required. A token that can push to the mirror project.
#   SRC_USER, DST_USER  optional. The user name git sends with each token.
#
# Optional guards:
#   SYNC_MAX_PRUNE    most refs one run may delete on the mirror. Default 5.
#   SYNC_ALLOW_PRUNE  set to 1 to lift the limit and the default-branch guard for one run.
#
# Output: the last line is "unchanged" or "synced".
#
# Never use --mirror. It would also copy hosting refs such as refs/pull/*, which
# hold other people's commits. The refspecs below name the only refs that move.
# The tokens reach git through askpass.sh. They are never in an argument, a URL
# or a git config file.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
fail() { echo "sync-repo: $*" >&2; exit 1; }

name="${1:?usage: sync-repo.sh <name> <cache-dir>}"
cache="${2:?usage: sync-repo.sh <name> <cache-dir>}"
: "${SRC_BASE:?set SRC_BASE}" "${DST_BASE:?set DST_BASE}" "${SRC_TOKEN:?set SRC_TOKEN}" "${DST_TOKEN:?set DST_TOKEN}"

[[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || fail "bad repository name: $name"

repo_url() { # base, user, name
  local base="${1%/}"
  [[ "$base" =~ ^https?://[^/@]+(/[^@]*)?$ ]] || fail "base must be http(s)://host/path with no user or token: $base"
  printf '%s://%s@%s/%s.git' "${base%%://*}" "$2" "${base#*://}" "$3"
}
host_of() { local rest="${1#*://}"; printf '%s' "${rest%%/*}"; }

src="$(repo_url "$SRC_BASE" "${SRC_USER:-x-access-token}" "$name")"
dst="$(repo_url "$DST_BASE" "${DST_USER:-oauth2}" "$name")"
SYNC_SRC_HOST="$(host_of "$SRC_BASE")"
SYNC_DST_HOST="$(host_of "$DST_BASE")"
[ "$SYNC_SRC_HOST" != "$SYNC_DST_HOST" ] || fail "source and mirror are on the same host. askpass cannot tell their tokens apart."
export SYNC_SRC_HOST SYNC_DST_HOST
export GIT_ASKPASS="$here/askpass.sh" GIT_TERMINAL_PROMPT=0

refspecs=('+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*')
git_() { git -c credential.helper= "$@"; }
list_refs() { # url: "sha<TAB>ref" lines for branches and tags, without peeled tag lines
  local out
  out="$(git_ ls-remote "$1" 'refs/heads/*' 'refs/tags/*')" || return 1
  { grep -v '\^{}$' <<<"$out" || true; } | sort
}
local_refs() { git_ -C "$cache" for-each-ref --format='%(objectname)%09%(refname)' refs/heads refs/tags | sort; }

src_refs="$(list_refs "$src")" || fail "cannot read the source $name"
dst_refs="$(list_refs "$dst")" || fail "cannot read the mirror project $name"
[ -n "$src_refs" ] || fail "the source $name has no branches or tags. Refusing to prune the mirror."

if [ "$src_refs" = "$dst_refs" ]; then
  echo unchanged
  exit 0
fi

# A prune that removes many refs, or the default branch, means a wrong or
# shrunken source far more often than a real clean-up.
pruned="$(LC_ALL=C comm -13 <(cut -f2 <<<"$src_refs" | LC_ALL=C sort) <(cut -f2 <<<"$dst_refs" | LC_ALL=C sort))"
if [ -n "$pruned" ] && [ "${SYNC_ALLOW_PRUNE:-}" != 1 ]; then
  max_prune="${SYNC_MAX_PRUNE:-5}"
  count="$(grep -c . <<<"$pruned")"
  [ "$count" -le "$max_prune" ] || fail "the sync of $name would delete $count refs on the mirror (limit $max_prune). Set SYNC_ALLOW_PRUNE=1 for one run if that is right."
  mirror_head="$(git_ ls-remote --symref "$dst" HEAD | sed -nE 's/^ref: ([^[:space:]]+)[[:space:]]+HEAD$/\1/p')"
  if [ -n "$mirror_head" ] && grep -qxF "$mirror_head" <<<"$pruned"; then
    fail "the sync of $name would delete the default branch ${mirror_head#refs/heads/} of the mirror. Set SYNC_ALLOW_PRUNE=1 for one run if that is right."
  fi
fi

git init --quiet --bare "$cache"
git_ -C "$cache" fetch --quiet --prune --force --no-tags "$src" "${refspecs[@]}"
fetched="$(local_refs)"
git_ -C "$cache" for-each-ref --count=1 refs/heads | grep -q . || fail "the fetch of $name returned no branch. Refusing to push."
[ "$fetched" = "$src_refs" ] || fail "the source $name changed during the fetch. The next run will try again."
git_ -C "$cache" push --quiet --prune "$dst" "${refspecs[@]}"
echo synced
