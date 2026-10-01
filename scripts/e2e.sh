#!/usr/bin/env bash
# End-to-end proof against the BUILT image: the hardening holds in the image that ships, and a
# negative control (upstream, unpatched) shows each check can actually fail. The last section
# forwards for real, to a throwaway push service, to prove a clustered mail server's identical
# pushes reach the device once (patch 0002).
#   usage: e2e.sh <patched image> <upstream image>
set -euo pipefail
IMAGE="$1"
UPSTREAM="$2"
WORK=$(mktemp -d)
cleanup() {
  docker rm -f e2e-relay e2e-upstream e2e-push e2e-dd e2e-dd-up >/dev/null 2>&1 || true
  docker network rm e2e-net >/dev/null 2>&1 || true
}
trap 'cleanup; rm -rf "$WORK"' EXIT
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
echo "== duplicate pushes from a cluster reach the device once (patch 0002)"
# A throwaway push service at https://e2e-push, with a CA the relays trust, that logs one line per
# push it receives. The relays send real, encrypted Web Push to it, so this is the forward that
# ships, not a mock of it.
docker network create e2e-net >/dev/null
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/ca.key" -out "$WORK/ca.pem" -days 1 \
  -subj "/CN=e2e CA" -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout "$WORK/push.key" -out "$WORK/push.csr" -subj "/CN=e2e-push" 2>/dev/null
printf 'subjectAltName=DNS:e2e-push\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n' > "$WORK/push.ext"
openssl x509 -req -in "$WORK/push.csr" -CA "$WORK/ca.pem" -CAkey "$WORK/ca.key" -CAcreateserial \
  -out "$WORK/push.pem" -days 1 -extfile "$WORK/push.ext" 2>/dev/null
chmod 755 "$WORK"; chmod a+r "$WORK"/*
docker run -d --name e2e-push --network e2e-net --user root -v "$WORK:/tls:ro" --entrypoint node "$IMAGE" -e '
  const fs = require("fs");
  require("https").createServer({ key: fs.readFileSync("/tls/push.key"), cert: fs.readFileSync("/tls/push.pem") },
    (req, res) => { req.resume(); req.on("end", () => { console.log("PUSH " + req.url); res.writeHead(201); res.end(); }); }
  ).listen(443);' >/dev/null
pushes() { docker logs e2e-push 2>&1 | grep -c '^PUSH /dd-'"$1"'$' || true; }
# A real P-256 key and auth secret, so the relay can encrypt the payload.
SUBKEYS=$(docker run --rm --entrypoint node "$IMAGE" -e '
  const c = require("crypto"); const e = c.createECDH("prime256v1"); e.generateKeys();
  console.log(JSON.stringify({ p256dh: e.getPublicKey().toString("base64url"), auth: c.randomBytes(16).toString("base64url") }))')
realweb() { # id path
  printf '{"subscriptionId":"%s","subscription":{"endpoint":"https://e2e-push/%s","keys":%s}}' "$1" "$2" "$SUBKEYS"
}
# Two copies of one delivery, posted CONCURRENTLY as two cluster nodes do (milliseconds apart),
# then a different message. Prints each response.
burst() { # name id
  docker exec -e ID="$2" "$1" node -e '
    const post = (ids) => fetch("http://127.0.0.1:3003/api/push/jmap/" + process.env.ID, { method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ "@type": "EmailPush", accountId: "a1", emails: ids.map((id) => ({ id, threadId: "t" })), state: "s" }) })
      .then(async (r) => r.status + " " + (await r.text()));
    (async () => {
      const copies = await Promise.all([post(["m1"]), post(["m1"])]);
      const next = await post(["m2"]);
      console.log(JSON.stringify({ copies, next }));
    })();'
}
ddcase() { # name image id -> "<pushes after the two copies> <pushes after the next message>"
  start "$1" "$2" --network e2e-net -v "$WORK:/tls:ro" -e NODE_EXTRA_CA_CERTS=/tls/ca.pem -e WEBPUSH_ALLOWED_HOSTS=e2e-push
  expect "$1: register a real subscription" "200" "$(call "$1" POST /api/push/register/web "$(realweb "$3" "dd-$3")")" >&2
  expect "$1: confirm it"                   "200" "$(call "$1" POST "/api/push/jmap/$3" '{"@type":"PushVerification","pushSubscriptionId":"p","verificationCode":"c"}')" >&2
  burst "$1" "$3" > "$WORK/$3.out"
  sleep 1
  echo "$(pushes "$3") $(cat "$WORK/$3.out")"
}
got=$(ddcase e2e-dd "$IMAGE" e2e-dd-A1)
case "$got" in
  '2 {"copies":["200 {\"ok\":true}","200 {\"ok\":true,\"duplicate\":true}"],"next":"200 {\"ok\":true}"}'|\
  '2 {"copies":["200 {\"ok\":true,\"duplicate\":true}","200 {\"ok\":true}"],"next":"200 {\"ok\":true}"}')
    echo "ok   patched: two copies forwarded once, the next message forwarded -> $got" ;;
  *) echo "::error::patched: want 2 pushes (one per message) and one copy answered duplicate, got $got"; exit 1 ;;
esac
got=$(ddcase e2e-dd-up "$UPSTREAM" e2e-dd-B1)
case "$got" in
  3\ *) echo "ok   control: upstream forwards both copies -> $got" ;;
  *) echo "::error::control: upstream should forward both copies and the next message (3 pushes), got $got"; exit 1 ;;
esac
echo "e2e: OK"
