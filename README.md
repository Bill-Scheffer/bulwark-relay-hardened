# bulwark-relay-hardened

The [Bulwark push relay](https://github.com/bulwarkmail/relay), built from a pinned upstream commit
(`e077c33`, 2026-11-13) with two patches: one keeps a clustered mail server from notifying every device once per
node, and one sends every push at high urgency with no Topic, as the relay did before `e077c33`. Published as `ghcr.io/bill-scheffer/bulwark-relay-hardened`.

Upstream publishes no image and no tags, so this repo pins a commit (`RELAY_SHA` in
`.github/workflows/build.yml`) and builds it with upstream's own Dockerfile. The pin was reviewed as a commit:
`d4f34c0..e077c33` is upstream's November security audit (journal store, a data-directory lock, per-device and
per-address limits, endpoint guards), followed by two dependency bumps (MainThrive MAI-1442).

## Patch 0001, retired at `e077c33`

`0001-harden-for-public-exposure.patch` made the relay safe to expose publicly in three ways. Upstream's audit now does
each, so it was dropped (MainThrive MAI-1442):

| 0001 did | Upstream at `e077c33` |
|---|---|
| Web Push endpoints only on a known push service, so the relay could not be made to call an arbitrary URL | only `https` on public addresses, a name without a dot or `.local`/`.internal` refused at registration, the address checked again on every connection, no redirect followed, 4 KB of an answer read (README, "Which endpoints it calls"). ⚠️ Weaker in one way: any public `https` host is accepted, not only the push services, so a mail user who registers their own endpoint and points a JMAP push subscription at the relay can make it POST a sealed, size-capped push to a public host of their choosing. It can no longer reach a private network either way |
| unconfirmed subscriptions capped and expired, so a flood could not fill the store or lock out real devices | `PUSH_MAX_SUBSCRIPTIONS`, a per-address cap and a registration rate limit, and an eviction order that never drops a device that delivered in the last 30 days (README, "Limits"). ⚠️ The per-address cap and rate only work when the relay can tell clients apart (`TRUST_PROXY`); behind a proxy that forwards no client address, only the store cap and its eviction order apply, and a flood of fresh registrations (which may not be evicted for 10 minutes) refuses new devices with `507` while it lasts, as 0001's cap refused them with `503` |
| UnifiedPush off unless opted in | its endpoints pass the same public-address guard |

⚠️ **What it rests on, unchanged:** the relay calls an endpoint only when `/api/push/jmap/:id` is posted to, and
MainThrive's proxy admits that path only from the mail server's addresses (MainThrive
`infra/k8s/mail/tests/check-push-relay-route.sh`). A registration alone never makes the relay call out. `scripts/e2e.sh`
checks the guard that replaced the allowlist in the image that ships: a private address and a name without a dot are
refused.

## Patch 0002: one notification per message from a clustered mail server

A mail server running as a cluster sends each push from EVERY node: Stalwart gives each node with
the push role every subscription unless push sharding is set, and sharding means an account gets no
push while its node is down. So with two nodes every new message arrived twice. Android hid it
(Bulwark's service worker replaces the notification by tag), and iOS showed both.

`src/dedupe.ts` forwards a push once and answers its identical copies `200 {"duplicate":true}`, so the
mail server does not retry them. The claim is taken just before upstream's hold (its rate limits, and a
backoff a push service asked for), with no `await` between the two, so a copy spends none of the hold's tokens; and it
is given back when the push is held, or its forward fails or throws: a push that went out is the only one its copies are
dropped for, so the mail server's retry of a held or refused push goes through. `src/dedupe-server.test.ts` proves both
through the real relay: eight messages sent twice at once all go out (with the claim after the hold, the sixth is held),
and a held or refused push's retry is forwarded (with the release removed, that case fails). EmailPush copies are identical when they list the same message ids;
StateChange copies when they carry the same states. A new message is always a new push. The check and
the claim are synchronous, because the copies arrive milliseconds apart. A failed forward releases
its claim. A copy that arrived while that forward was in flight has already been dropped, so the
mail server's retry of the failed push goes through instead: late, not lost. Claims expire after
`DEDUPE_TTL_MS` (10 minutes), and at most `DEDUPE_MAX_KEYS` (10,000) are held, oldest dropped first.
`relay_pushes_deduplicated_total` counts the dropped copies.

## Patch 0003: every push at high urgency, with no Topic

`e077c33` decides each push's delivery headers (upstream `7c84025`, `2aea6e6`): `high` urgency and a Topic (an
RFC 8030 replacement key, FCM's collapse key) for a push it reads as new mail, `normal` for one that only names
`Email`, and `low` for the rest. The relay before it sent every push at `high`, with no Topic and the same one-hour
TTL. Once MainThrive ran `e077c33`, a user's two Android phones showed no notification for new mail while their iPhone
did. The relay had forwarded every push, and the push service had accepted each one (MainThrive MAI-1442). An Android phone may hold
a push below `high` urgency until it next wakes.

`src/forward-policy.ts`'s `deliveryOptions` now returns `{ urgency: 'high' }` for every push, whatever the push
says and whatever urgency the mail server asked for. Web Push and UnifiedPush are the transports that send an urgency; the native FCM and APNs paths take none.
Upstream's own tests of the old behaviour are replaced in `src/server.test.ts` by two that pin the new one, and both
fail on unpatched `e077c33`. What it costs: a device that was offline gets every queued ping, not only the latest
new-mail one, and a ping that is only a read flag wakes the phone as new mail does.

## How a build is proven

The workflow runs these steps, and pushes the image only if all of them pass:

- It applies 0002, checks it changed exactly its five files, that the claim comes before the hold, and that it is given
  back when the push is held or its forward fails.
- It applies 0003, checks it changed exactly `src/forward-policy.ts` and `src/server.test.ts`, and that
  `deliveryOptions` returns high urgency.
- It runs upstream's tests plus the patches', and the typecheck.
- It builds the image and runs `scripts/e2e.sh` against it: a push-service endpoint registers, a private address and a
  name without a dot are refused (upstream's guard, which 0001's allowlist was replaced by), and then, forwarding for
  real with encrypted Web Push to a throwaway push service, two copies of one delivery posted concurrently reach it
  once, and the next message reaches it. The push service also records each push's `Urgency`, `Topic` and `TTL`:
  every push the patched image sends, two new messages and two state changes, reads `high`, no Topic, `3600`.
- **Negative control:** the unpatched upstream image, built from the same commit, forwards both copies, and sends a
  ping that names only a mailbox at `low` urgency.

## Publishing and pinning

A pull request runs every step but the registry login and the push. A dispatch from a branch pushes the tested
image as `branch-<short sha>` only. `main` publishes `VERSION`'s tag, and only once: a tag that already exists is
never re-pushed, so a change to what is built must bump `VERSION`. The build fails a pull request that changes
`patches/`, a value in `env:`, a step up to and including the image build, or a repo file such a step names, without
the bump. Pin the image **by digest**, and the digest you pin keeps its tag (MainThrive MAI-1021).

A digest pinned without a tag of its own is protected by tagging it `pinned-<first 12 hex>`. The workflow copies
the manifest as-is and never moves a tag:

```bash
gh workflow run protect-digest.yml -R Bill-Scheffer/bulwark-relay-hardened -f digest=sha256:<64 hex>
```

## License

AGPL-3.0-only, as upstream (`LICENSE`). The source for every image is upstream at `RELAY_SHA` plus
the patches in this repository.
