#!/usr/bin/env bash
# End-to-end proof against the BUILT image: the hardening holds in the image that ships, and a
# negative control (upstream, unpatched) shows each check can actually fail.
#   usage: e2e.sh <patched image> <upstream image>
set -euo pipefail
IMAGE="$1"
UPSTREAM="$2"
cleanup() { docker rm -f e2e-relay e2e-upstream >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

# A throwaway VAPID pair, from the image's own web-push library.
KEYS=$(docker run --rm --entrypoint node "$IMAGE" -e \
  'const w=require("web-push"); console.log(JSON.stringify(w.generateVAPIDKeys()))')
PUB=$(printf '%s' "$KEYS" | jq -r .publicKey)
PRIV=$(printf '%s' "$KEYS" | jq -r .privateKey)

start() { # name image extra-env...
  local name=$1 image=$2; shift 2
  docker run -d --name "$name" -e VAPID_PUBLIC_KEY="$PUB" -e VAPID_PRIVATE_KEY="$PRIV" \
    -e VAPID_SUBJECT=mailto:e2e@example.test "$@" "$image" >/dev/null
  for _ in $(seq 1 30); do
    docker exec "$name" wget -q -O /dev/null http://127.0.0.1:3003/api/health 2>/dev/null && return 0
    sleep 1
  done
  docker logs "$name" | tail -20; echo "::error::$name did not become healthy"; exit 1
}
call() { # name method path [json] -> "<status> <body>"
  docker exec -e M="$2" -e P="$3" -e B="${4:-}" "$1" node -e '
    const o = { method: process.env.M, headers: { "content-type": "application/json" } };
    if (process.env.B) o.body = process.env.B;
    fetch("http://127.0.0.1:3003" + process.env.P, o)
      .then(async r => console.log(r.status, await r.text()))
      .catch(e => { console.log("000", e.message); })'
}
expect() { # label want got
  case "$3" in "$2"*) echo "ok   $1 -> $3" ;; *) echo "::error::$1: want $2, got $3"; exit 1 ;; esac
}
KEYSJSON='"keys":{"p256dh":"'"$(printf 'B%.0s' $(seq 87))"'","auth":"'"$(printf 'a%.0s' $(seq 22))"'"}'
web() { # id endpoint
  printf '{"subscriptionId":"%s","subscription":{"endpoint":"%s",%s}}' "$1" "$2" "$KEYSJSON"
}

echo "== patched: $IMAGE"
start e2e-relay "$IMAGE" -e MAX_PENDING=2
expect "vapid key served"              "200"  "$(call e2e-relay GET /api/push/vapid-public-key)"
expect "a push-service endpoint"       "200"  "$(call e2e-relay POST /api/push/register/web "$(web e2e-sub-A1 https://fcm.googleapis.com/fcm/send/abc)")"
expect "an arbitrary endpoint (SSRF)"  "400"  "$(call e2e-relay POST /api/push/register/web "$(web e2e-sub-X1 https://attacker.example/collect)")"
expect "a look-alike host"             "400"  "$(call e2e-relay POST /api/push/register/web "$(web e2e-sub-X2 https://fcm.googleapis.com.attacker.example/x)")"
expect "UnifiedPush, not opted in"     "403"  "$(call e2e-relay POST /api/push/register/unifiedpush '{"subscriptionId":"e2e-sub-U1","endpoint":"https://attacker.example/up"}')"
expect "second pending id (cap of 2)"  "200"  "$(call e2e-relay POST /api/push/register/web "$(web e2e-sub-B1 https://updates.push.services.mozilla.com/wpush/v2/x)")"
expect "third pending id, past the cap" "503" "$(call e2e-relay POST /api/push/register/web "$(web e2e-sub-C1 https://web.push.apple.com/x)")"
expect "an existing id re-registers"   "200"  "$(call e2e-relay POST /api/push/register/web "$(web e2e-sub-A1 https://fcm.googleapis.com/fcm/send/abc)")"
expect "PushVerification accepted"     "200"  "$(call e2e-relay POST /api/push/jmap/e2e-sub-A1 '{"@type":"PushVerification","pushSubscriptionId":"p","verificationCode":"e2e-code-7"}')"
expect "verify returns the code"       '200 {"verificationCode":"e2e-code-7"}' "$(call e2e-relay GET /api/push/verify/e2e-sub-A1)"
expect "confirmed ids leave the cap"   "200"  "$(call e2e-relay POST /api/push/register/web "$(web e2e-sub-C1 https://web.push.apple.com/x)")"

echo "== negative control, upstream unpatched: $UPSTREAM"
start e2e-upstream "$UPSTREAM" -e MAX_PENDING=2
expect "control: arbitrary endpoint accepted" "200" "$(call e2e-upstream POST /api/push/register/web "$(web e2e-sub-X1 https://attacker.example/collect)")"
expect "control: UnifiedPush accepted"        "200" "$(call e2e-upstream POST /api/push/register/unifiedpush '{"subscriptionId":"e2e-sub-U1","endpoint":"https://attacker.example/up"}')"
expect "control: no cap (id 2)"               "200" "$(call e2e-upstream POST /api/push/register/web "$(web e2e-sub-B1 https://updates.push.services.mozilla.com/wpush/v2/x)")"
expect "control: no cap (id 3)"               "200" "$(call e2e-upstream POST /api/push/register/web "$(web e2e-sub-C1 https://web.push.apple.com/x)")"
echo "e2e: OK"
