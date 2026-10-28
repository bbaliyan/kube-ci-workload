#!/usr/bin/env bash
# Tests for what the charts render: the GitLab address settings, the tailnet Ingress and the LAN route.
# Run: tests/render.sh
# shellcheck disable=SC2319 # "$?" right after a test command is the point of the is() helper
set -uo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
failures=0

command -v helm >/dev/null || { echo "tests/render.sh needs helm (it is in the kube-devenv image)" >&2; exit 2; }

report() { # name, ok or the reason
  if [ "$2" = ok ]; then echo "ok: $1"; else echo "FAIL: $1 ($2)"; failures=$((failures + 1)); fi
}
is() { # name, condition result (0 = pass), detail
  if [ "$2" -eq 0 ]; then report "$1" ok; else report "$1" "${3:-failed}"; fi
}

gitlab() { helm template gitlab "$repo/apps/gitlab" "$@"; }

out="$(gitlab --set externalUrl=https://git-ci.example.ts.net)"
grep -q "external_url 'https://git-ci.example.ts.net'" <<<"$out" && grep -q "nginx\['listen_https'\] = false" <<<"$out" \
  && grep -q "letsencrypt\['enable'\] = false" <<<"$out" && grep -q '"X-Forwarded-Proto" => "https"' <<<"$out"
is "an https address makes GitLab listen on plain HTTP behind the proxy, with no Let's Encrypt" "$?" "$out"

out="$(gitlab --set externalUrl=http://git.example.test)"
! grep -q 'listen_https' <<<"$out" && ! grep -q 'letsencrypt' <<<"$out"
is "an http address adds no proxy settings" "$?" "$out"

out="$(gitlab)"
! grep -q 'kind: Ingress' <<<"$out" && ! grep -q 'kind: IngressRoute' <<<"$out"
is "by default GitLab has no Ingress and no LAN route" "$?" "$out"

out="$(gitlab --set tailnet.enabled=true --set externalUrl=https://git-ci.example.ts.net)"
grep -q 'ingressClassName: tailscale' <<<"$out" && grep -q 'tailscale.com/proxy-group: ci-proxy' <<<"$out" \
  && ! grep -q 'tailscale.com/hostname' <<<"$out" && grep -A2 'tls:' <<<"$out" | grep -q -- '- git-ci'
is "the tailnet Ingress takes its host name from the first label of externalUrl, through a ProxyGroup, and asks for a certificate" "$?" "$out"
grep -q 'kind: ProxyGroup' <<<"$out" && grep -q 'type: ingress' <<<"$out" && grep -A1 'tags:' <<<"$out" | grep -q -- '- tag:ci'
is "a ProxyGroup of type ingress carries the tag" "$?" "$out"
grep -q 'replicas: 2' <<<"$out" && grep -q 'hostnamePrefix: ci-proxy' <<<"$out"
is "the ProxyGroup runs two pods named ci-proxy-0 and ci-proxy-1" "$?" "$out"
! grep -q 'kind: ProxyGroup' <<<"$(gitlab)"
is "without the tailnet switch there is no ProxyGroup" "$?"

out="$(gitlab --set lanHost=git.example.test)"
grep -q 'Host(`git.example.test`)' <<<"$out" && grep -q 'kind: IngressRoute' <<<"$out"
is "a LAN host name makes a Traefik route" "$?" "$out"

out="$(helm template b "$repo/bootstrap" --set gitlab.externalUrl=https://git-ci.example.ts.net --set gitlab.lanHost=git.example.test)"
grep -q 'externalUrl: https://git-ci.example.ts.net' <<<"$out" && grep -q 'lanHost: git.example.test' <<<"$out" && grep -q 'enabled: true' <<<"$out"
is "the bootstrap passes the tailnet address, the LAN name and the tailnet switch to GitLab" "$?" "$out"
grep -q 'name: tailscale-operator' <<<"$out" && grep -q 'path: apps/tailscale-operator' <<<"$out" && grep -q 'Prune=false,Delete=false' <<<"$out"
is "the bootstrap installs the Tailscale operator and never prunes it" "$?" "$out"

[ "$failures" -eq 0 ] && echo "all render tests passed" || { echo "$failures render test(s) failed"; exit 1; }
