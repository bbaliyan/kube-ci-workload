#!/usr/bin/env bash
# Runs the webhook shim that apps/pr-agent-webhook renders, in Docker, against a stand-in
# router that needs a client certificate. It checks the token rules, the retry rules and the mTLS hop.
# See the README, "The webhook shim".
#
# Why a script: the steps depend on each other (make certificates, start two containers,
# send requests, change the secret file, compare the answers). No declarative tool sequences
# them. The shim config comes from helm template, so the test runs what the chart renders.
#
# Needs docker, helm, openssl and curl. It uses the Envoy image that the chart pins.
set -euo pipefail

cd "$(dirname "$0")/../.."
here="$PWD/tests/shim"
work="$(mktemp -d)"
net="shim-test-$$"
port=18080
wrong_port=18081
badcert_port=18082
secret=correct-horse-battery
hop=test-hop-token

cleanup() {
  docker rm -f "$net-shim" "$net-router" "$net-shim-wrong" "$net-router-wrong" "$net-shim-badcert" >/dev/null 2>&1 || true
  docker network rm "$net" "$net-wrong" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

# The test shortens the time of one try, so a try that runs out of time takes seconds.
rendered="$(helm template x apps/pr-agent-webhook --set actor.atespace=reviews --set actor.name=pr-review --set "hopToken=$hop" --set perTryTimeoutSeconds=4 -s templates/shim.yaml)"
image="$(sed -n 's/^ *image: //p' <<<"$rendered")"
test -n "$image" || { echo "no shim image in the render" >&2; exit 1; }

mkdir -p "$work/config" "$work/secrets" "$work/router-client" "$work/router-certs" "$work/router-certs-wrong" "$work/router-client-bad"
for file in envoy.yaml sds-client.yaml sds-ca.yaml; do
  awk -v key="  $file: |" '$0 == key {f=1; next} f && /^    / {sub(/^    /, ""); print; next} f {exit}' <<<"$rendered" >"$work/config/$file"
  test -s "$work/config/$file" || { echo "no $file in the render" >&2; exit 1; }
done
printf '%s' "$secret" >"$work/secrets/WEBHOOK_SECRET"

host=atenet-router.ate-system.svc
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 -subj "/CN=test-ca" \
  -keyout "$work/ca.key" -out "$work/router-client/router-ca.pem" 2>/dev/null
cp "$work/router-client/router-ca.pem" "$work/router-certs/ca.pem"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 -subj "/CN=other-ca" \
  -keyout "$work/other-ca.key" -out "$work/other-ca.pem" 2>/dev/null
cp "$work/router-client/router-ca.pem" "$work/ca.pem"
issue() { # name, subject alternative name, signing CA (ca or other-ca, default ca)
  local signer="${3:-ca}"
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -subj "/CN=$1" \
    -keyout "$work/$1.key" -out "$work/$1.csr" 2>/dev/null
  printf 'subjectAltName=%s\n' "$2" >"$work/$1.ext"
  openssl x509 -req -in "$work/$1.csr" -CA "$work/$signer.pem" -CAkey "$work/$signer.key" \
    -CAcreateserial -days 1 -extfile "$work/$1.ext" -out "$work/$1.pem" 2>/dev/null
}
issue server "DNS:$host"
issue wrongserver "DNS:wrong.example"
issue shim "DNS:shim"
issue badshim "DNS:shim" other-ca
cp "$work/server.pem" "$work/router-certs/server.pem"
cp "$work/server.key" "$work/router-certs/server.key"
cp "$work/ca.pem" "$work/router-certs-wrong/ca.pem"
cp "$work/wrongserver.pem" "$work/router-certs-wrong/server.pem"
cp "$work/wrongserver.key" "$work/router-certs-wrong/server.key"
cat "$work/shim.key" "$work/shim.pem" >"$work/router-client/credential-bundle.pem"
cat "$work/badshim.key" "$work/badshim.pem" >"$work/router-client-bad/credential-bundle.pem"
cp "$work/ca.pem" "$work/router-client-bad/router-ca.pem"
chmod -R a+rX "$work"

docker network create "$net" >/dev/null
docker run -d --name "$net-router" --network "$net" --network-alias "$host" \
  -v "$here/router.yaml:/etc/envoy/envoy.yaml:ro" -v "$work/router-certs:/certs:ro" \
  "$image" -c /etc/envoy/envoy.yaml --disable-hot-restart --concurrency 1 >/dev/null
start_shim() { # name, network, host port, client directory
  docker run -d --name "$1" --network "$2" -p "127.0.0.1:$3:8080" \
    --user 101:101 --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
    -v "$work/config:/etc/envoy:ro" -v "$work/secrets:/secrets:ro" -v "$4:/run/router-client:ro" \
    "$image" -c /etc/envoy/envoy.yaml --disable-hot-restart >/dev/null
}
start_shim "$net-shim" "$net" "$port" "$work/router-client"

# A router whose certificate names another host, on its own network.
docker network create "$net-wrong" >/dev/null
docker run -d --name "$net-router-wrong" --network "$net-wrong" --network-alias "$host" \
  -v "$here/router.yaml:/etc/envoy/envoy.yaml:ro" -v "$work/router-certs-wrong:/certs:ro" \
  "$image" -c /etc/envoy/envoy.yaml --disable-hot-restart >/dev/null
start_shim "$net-shim-wrong" "$net-wrong" "$wrong_port" "$work/router-client"

# A shim whose client certificate comes from a CA that the router does not trust.
start_shim "$net-shim-badcert" "$net" "$badcert_port" "$work/router-client-bad"

failures=0
check() { # name, expected status, expected body fragment, curl args...
  local name="$1" status="$2" fragment="$3" out code
  shift 3
  out="$(curl -s -m 20 -o - -w '\n%{http_code}' "$@" "http://127.0.0.1:$port${path:-/hook}" || true)"
  code="${out##*$'\n'}"
  if [ "$code" = "$status" ] && grep -qF -- "$fragment" <<<"$out"; then
    echo "ok: $name"
  else
    echo "FAIL: $name (status $code, want $status, output: $out)"
    failures=$((failures + 1))
  fi
}

for ready_port in "$port" "$wrong_port" "$badcert_port"; do
  for _ in $(seq 1 30); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$ready_port/healthz" || true)" = 200 ] && break
    sleep 1
  done
done

deliveries() { # path: how many POST requests with this path the router received
  curl -s -m 20 -H "X-Gitlab-Token: $secret" "http://127.0.0.1:$port/count$1" | sed -n 's/^count //p'
}

expect() { # name, wanted, got
  if [ "$3" = "$2" ]; then
    echo "ok: $1"
  else
    echo "FAIL: $1 (got $3, want $2)"
    failures=$((failures + 1))
  fi
}

path=/healthz check "the health route answers without a token" 200 ok -X GET
check "no token is refused" 401 "unauthorized" -X POST -d '{}'
check "a wrong token is refused" 401 "unauthorized" -X POST -H "X-Gitlab-Token: wrong" -d '{}'
check "the right token plus extra bytes is refused" 401 "unauthorized" -X POST -H "X-Gitlab-Token: ${secret}x" -d '{}'
check "the right token reaches the router with the target and the hop token" 200 "actor=reviews/pr-review token=$hop" -X POST -H "X-Gitlab-Token: $secret" -d '{}'
check "the real secret never reaches the router" 200 "token=$hop" -X POST -H "X-Gitlab-Token: $secret" -d '{}'

for code in 502 504; do
  path="/status/$code" check "the sender gets the $code of a router that never recovers" "$code" "status $code" -X POST -H "X-Gitlab-Token: $secret" -d '{}'
  expect "the shim tries the POST 3 times after a $code" 3 "$(deliveries "/status/$code")"
done

done_count() { # path: how many POST requests the router answered after its wait
  curl -s -m 20 -H "X-Gitlab-Token: $secret" "http://127.0.0.1:$port/done$1" | sed -n 's/^count //p'
}

path=/cold/a/1 check "after a 504 while the actor starts, the retry reaches the router and the sender gets the 200" 200 "actor=reviews/pr-review" -X POST -H "X-Gitlab-Token: $secret" -d '{}'
expect "the router receives the POST twice after a 504 while the actor starts" 2 "$(deliveries /cold/a/1)"

path=/cold/p/6 check "a try that runs out of time is retried and the sender gets the 200" 200 "actor=reviews/pr-review" -X POST -H "X-Gitlab-Token: $secret" -d '{}'
expect "the router receives the POST twice after a try that ran out of time" 2 "$(deliveries /cold/p/6)"

path=/slow/c/2 check "a slow start that succeeds reaches a sender that waits" 200 "actor=reviews/pr-review" -X POST -H "X-Gitlab-Token: $secret" -d '{}'
expect "the slow router answered once" 1 "$(done_count /slow/c/2)"

# The shim stops the request when the sender leaves. A sender with a short timeout, such as GitLab, loses the delivery.
curl -s -m 2 -o /dev/null -X POST -H "X-Gitlab-Token: $secret" -d '{}' "http://127.0.0.1:$port/slow/b/6" || true
sleep 7
expect "a sender that leaves early: the router received the POST" 1 "$(deliveries /slow/b/6)"
expect "a sender that leaves early: the router never finished the request" 0 "$(done_count /slow/b/6)"

port="$wrong_port" check "a router with a certificate for another name is refused" 503 "upstream connect error" -X POST -H "X-Gitlab-Token: $secret" -d '{}'
port="$badcert_port" check "a shim with a certificate from an unknown CA is refused by the router" 503 "upstream connect error" -X POST -H "X-Gitlab-Token: $secret" -d '{}'

printf '%s' "rotated-secret" >"$work/secrets/WEBHOOK_SECRET"
check "after a rotation the old token is refused" 401 "unauthorized" -X POST -H "X-Gitlab-Token: $secret" -d '{}'
check "after a rotation the new token is accepted" 200 "actor=reviews/pr-review" -X POST -H "X-Gitlab-Token: rotated-secret" -d '{}'

printf 'newline-secret\n' >"$work/secrets/WEBHOOK_SECRET"
check "a secret file that ends in a new line still matches" 200 "actor=reviews/pr-review" -X POST -H "X-Gitlab-Token: newline-secret" -d '{}'

: >"$work/secrets/WEBHOOK_SECRET"
check "an empty secret file refuses a token" 401 "unauthorized" -X POST -H "X-Gitlab-Token: anything" -d '{}'
check "an empty secret file refuses an empty token" 401 "unauthorized" -X POST -H "X-Gitlab-Token;" -d '{}'
printf ' \n' >"$work/secrets/WEBHOOK_SECRET"
check "a secret file of white space only refuses every request" 401 "unauthorized" -X POST -H "X-Gitlab-Token: x" -d '{}'

rm "$work/secrets/WEBHOOK_SECRET"
check "a missing secret file refuses every request" 401 "unauthorized" -X POST -H "X-Gitlab-Token: rotated-secret" -d '{}'

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  docker logs "$net-shim" 2>&1 | tail -20
  exit 1
fi
echo "all tests passed"
