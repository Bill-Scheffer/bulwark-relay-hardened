# bulwark-relay-hardened

The [Bulwark push relay](https://github.com/bulwarkmail/relay), built from a pinned upstream commit
with one patch that makes it safe to expose publicly. Published as
`ghcr.io/bill-scheffer/bulwark-relay-hardened`. A second patch keeps a clustered mail server from
notifying every device once per node.

Upstream publishes no image and no tags, so this repo pins a commit (`RELAY_SHA` in
`.github/workflows/build.yml`) and builds it with upstream's own Dockerfile.

## The patch (`patches/0001-harden-for-public-exposure.patch`)

The relay's endpoints are unauthenticated by design: any browser registers a push subscription. The
patch adds three things:

1. **Web Push endpoints must be on a known push service.** These are FCM, Mozilla autopush, Apple,
   and WNS (`*.notify.windows.com`); `WEBPUSH_ALLOWED_HOSTS` overrides the list. Upstream accepts any
   `https` URL. A caller could register their own URL, then POST to `/api/push/jmap/<their id>` and
   make the relay send a request to it. That is server-side request forgery from the relay's network.
2. **Unconfirmed subscriptions are capped and expire.** A subscription is *pending* until the JMAP
   server first reaches it (its verification, or a push). Pending ones expire after the 10-minute
   verification window, and at most `MAX_PENDING` (default 1000) exist at once: past that, new ids get
   503. Upstream rewrites its whole JSON store on every change and has no limit, so registrations
   alone could grow it until the relay stalls. A flat cap would only trade that for a lockout,
   because anyone could fill it. With this rule a flood can delay new sign-ups while it lasts, but
   never evicts or blocks a confirmed subscription. ⚠️ **It holds only if nothing but your own mail
   server can reach `/api/push/jmap/`**, because anything that can post there can confirm an id. Our
   deployment restricts that path at the proxy to the mail server's addresses.
3. **UnifiedPush is off unless `UNIFIEDPUSH_ENABLED=true`.** Its endpoints are arbitrary `https`
   URLs by design, which is the same forgery risk as 1.

## Patch 0002: one notification per message from a clustered mail server

A mail server running as a cluster sends each push from EVERY node: Stalwart gives each node with
the push role every subscription unless push sharding is set, and sharding means an account gets no
push while its node is down. So with two nodes every new message arrived twice. Android hid it
(Bulwark's service worker replaces the notification by tag), and iOS showed both.

`src/dedupe.ts` forwards a push once and answers its identical copies `200 {"duplicate":true}`, so the
mail server does not retry them. EmailPush copies are identical when they list the same message ids;
StateChange copies when they carry the same states. A new message is always a new push. The check and
the claim are synchronous, because the copies arrive milliseconds apart. A failed forward releases
its claim. A copy that arrived while that forward was in flight has already been dropped, so the
mail server's retry of the failed push goes through instead: late, not lost. Claims expire after
`DEDUPE_TTL_MS` (10 minutes), and at most `DEDUPE_MAX_KEYS` (10,000) are held, oldest dropped first.
`relay_pushes_deduplicated_total` counts the dropped copies.

## How a build is proven

The workflow runs these steps, and pushes the image only if all of them pass:

- It applies 0001 and checks it changed exactly its six files, then 0002 and its four.
- It runs upstream's tests plus the patch's, and the typecheck.
- It builds the image and runs `scripts/e2e.sh` against it. That script registers a push-service
  endpoint (accepted), an arbitrary URL and a look-alike host (both refused), UnifiedPush (refused),
  and a third pending id past a cap of 2 (503). It checks a verification round trip, and that
  a confirmed id no longer counts against the cap. Expiry is covered by a unit test.
- The e2e then forwards for real: encrypted Web Push to a throwaway push service the relay trusts.
  Two copies of one delivery, posted concurrently, reach it once, and the next message reaches it.
- **Negative control:** the unpatched upstream image, built from the same commit, must accept every
  one of the refused cases, and forwards both copies. So each check can actually fail.

## License

AGPL-3.0-only, as upstream (`LICENSE`). The source for every image is upstream at `RELAY_SHA` plus
the patches in this repository.
