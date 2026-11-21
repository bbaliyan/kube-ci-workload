#!/usr/bin/env bash
# Runs the webhook shim that apps/pr-agent-webhook renders, in Docker, against a stand-in
# router that needs a client certificate. It checks the token rules, the retry rules and the mTLS hop.
# With a stand-in key endpoint and a local RSA key pair, it checks the ID token rules of the pipeline route.
# See the README, "The webhook shim".
#
# Why a script: the steps depend on each other (make certificates and keys, sign tokens, start the
# containers, send requests, change the secret file, compare the answers). No declarative tool sequences
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
tls_port=18083
secret=correct-horse-battery
hop=test-hop-token

cleanup() {
  docker rm -f "$net-shim" "$net-router" "$net-shim-wrong" "$net-router-wrong" "$net-shim-badcert" "$net-shim-tls" "$net-jwks" >/dev/null 2>&1 || true
  docker network rm "$net" "$net-wrong" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

# The test shortens the time of one try, so a try that runs out of time takes seconds. The webhook tests
# run with the pipeline route on, so they also show that the route leaves the webhook route as it was.
issuer=https://gitlab.example.test
render() { # key endpoint, extra helm arguments...
  local jwks="$1"
  shift
  helm template x apps/pr-agent-webhook --set actor.atespace=reviews --set actor.name=pr-review --set "hopToken=$hop" \
    --set perTryTimeoutSeconds=4 --set pipeline.enabled=true --set "pipeline.issuer=$issuer" --set "pipeline.jwksUri=$jwks" \
    --set 'pipeline.namespacePaths={allowed-group,allowed-group/sub}' "$@" -s templates/shim.yaml
}
rendered="$(render http://jwks.test:8080/oauth/discovery/keys)"
rendered_tls="$(render https://jwks.test:8443/oauth/discovery/keys --set pipeline.jwksCa.name=gitlab-ca)"
image="$(sed -n 's/^ *image: //p' <<<"$rendered")"
test -n "$image" || { echo "no shim image in the render" >&2; exit 1; }

mkdir -p "$work/config" "$work/config-tls" "$work/secrets" "$work/router-client" "$work/router-certs" "$work/router-certs-wrong" \
  "$work/router-client-bad" "$work/jwks" "$work/jwks-ca"
extract() { # render, directory
  local file
  for file in envoy.yaml sds-client.yaml sds-ca.yaml; do
    awk -v key="  $file: |" '$0 == key {f=1; next} f && /^    / {sub(/^    /, ""); print; next} f {exit}' <<<"$1" >"$2/$file"
    test -s "$2/$file" || { echo "no $file in the render" >&2; exit 1; }
  done
}
extract "$rendered" "$work/config"
extract "$rendered_tls" "$work/config-tls"
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
issue jwks "DNS:jwks.test"
cp "$work/jwks.pem" "$work/jwks/server.pem"
cp "$work/jwks.key" "$work/jwks/server.key"
cp "$work/ca.pem" "$work/jwks-ca/ca.pem"

# The ID tokens: RS256, signed with a local key pair. The key endpoint serves the public half.
openssl genrsa -out "$work/signer.key" 2048 2>/dev/null
openssl genrsa -out "$work/stranger.key" 2048 2>/dev/null
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
modulus="$(openssl rsa -in "$work/signer.key" -noout -modulus | sed 's/^Modulus=//')"
n="$(printf '%b' "$(sed 's/../\\x&/g' <<<"$modulus")" | b64url)"
printf '{"keys":[{"kty":"RSA","kid":"test-key","use":"sig","alg":"RS256","n":"%s","e":"AQAB"}]}' "$n" >"$work/jwks/keys.json"
now="$(date +%s)"
token() { # signing key, then optional: audience, issuer, namespace path, pipeline source, expiry time
  local aud="${2:-pr-agent}" iss="${3:-$issuer}" ns="${4:-allowed-group}" source="${5:-merge_request_event}" exp="${6:-$((now + 300))}"
  local header body
  header="$(printf '{"alg":"RS256","typ":"JWT","kid":"test-key"}' | b64url)"
  body="$(printf '{"iss":"%s","aud":"%s","namespace_path":"%s","project_path":"%s/app","pipeline_source":"%s","iat":%d,"nbf":%d,"exp":%d}' \
    "$iss" "$aud" "$ns" "$ns" "$source" "$now" "$((now - 10))" "$exp" | b64url)"
  printf '%s.%s.%s' "$header" "$body" "$(printf '%s.%s' "$header" "$body" | openssl dgst -sha256 -sign "$1" -binary | b64url)"
}
chmod -R a+rX "$work"

docker network create "$net" >/dev/null
docker run -d --name "$net-router" --network "$net" --network-alias "$host" \
  -v "$here/router.yaml:/etc/envoy/envoy.yaml:ro" -v "$work/router-certs:/certs:ro" \
  "$image" -c /etc/envoy/envoy.yaml --disable-hot-restart --concurrency 1 >/dev/null
docker run -d --name "$net-jwks" --network "$net" --network-alias jwks.test \
  -v "$here/jwks.yaml:/etc/envoy/envoy.yaml:ro" -v "$work/jwks:/jwks:ro" \
  "$image" -c /etc/envoy/envoy.yaml --disable-hot-restart >/dev/null
start_shim() { # name, network, host port, client directory, config directory (default config)
  docker run -d --name "$1" --network "$2" -p "127.0.0.1:$3:8080" \
    --user 101:101 --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
    -v "$work/${5:-config}:/etc/envoy:ro" -v "$work/secrets:/secrets:ro" -v "$4:/run/router-client:ro" \
    -v "$work/jwks-ca:/etc/jwks-ca:ro" \
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

# A shim that fetches the keys over HTTPS and trusts the CA of the mounted ConfigMap.
start_shim "$net-shim-tls" "$net" "$tls_port" "$work/router-client" config-tls

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

for ready_port in "$port" "$wrong_port" "$badcert_port" "$tls_port"; do
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
check "the webhook route keeps its path and gets no Authorization header" 200 "path=/hook auth=none" -X POST -H "X-Gitlab-Token: $secret" -d '{}'
check "a valid ID token does not open the webhook route" 401 "unauthorized" -X POST -H "Authorization: Bearer $(token "$work/signer.key")" -d '{}'

path=/pipeline check "a valid ID token reaches the actor at /webhook with the hop token and without the ID token" 200 \
  "actor=reviews/pr-review token=$hop path=/webhook auth=none" -X POST -H "Authorization: Bearer $(token "$work/signer.key")" -d '{}'
path=/pipeline check "a token of a listed subgroup is accepted" 200 "actor=reviews/pr-review" \
  -X POST -H "Authorization: Bearer $(token "$work/signer.key" "" "" allowed-group/sub)" -d '{}'
path=/pipeline check "a request without an ID token is refused" 401 "Jwt is missing" -X POST -d '{}'
path=/pipeline check "the webhook secret does not open the pipeline route" 401 "Jwt is missing" -X POST -H "X-Gitlab-Token: $secret" -d '{}'
path=/pipeline check "a token with a wrong signature is refused" 401 "Jwt verification fails" \
  -X POST -H "Authorization: Bearer $(token "$work/stranger.key")" -d '{}'
# jwt_authn answers a valid token for another audience with 403, not 401.
path=/pipeline check "a token for another audience is refused" 403 "Audiences in Jwt are not allowed" \
  -X POST -H "Authorization: Bearer $(token "$work/signer.key" other)" -d '{}'
path=/pipeline check "a token of another issuer is refused" 401 "Jwt issuer is not configured" \
  -X POST -H "Authorization: Bearer $(token "$work/signer.key" "" https://other.example.test)" -d '{}'
path=/pipeline check "an expired token is refused" 401 "Jwt is expired" \
  -X POST -H "Authorization: Bearer $(token "$work/signer.key" "" "" "" "" $((now - 120)))" -d '{}'
path=/pipeline check "a token of another group is refused" 403 "RBAC: access denied" \
  -X POST -H "Authorization: Bearer $(token "$work/signer.key" "" "" other-group)" -d '{}'
path=/pipeline check "a token of a group whose name starts with a listed group is refused" 403 "RBAC: access denied" \
  -X POST -H "Authorization: Bearer $(token "$work/signer.key" "" "" allowed-group-2)" -d '{}'
path=/pipeline check "a token of a branch pipeline is refused" 403 "RBAC: access denied" \
  -X POST -H "Authorization: Bearer $(token "$work/signer.key" "" "" "" push)" -d '{}'
path=/pipeline port="$tls_port" check "a shim that fetches the keys over HTTPS accepts a valid token" 200 "path=/webhook auth=none" \
  -X POST -H "Authorization: Bearer $(token "$work/signer.key")" -d '{}'

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
