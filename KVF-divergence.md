# KVF divergence from upstream LXMF-swift

Living record of every change this fork (`kishontivf/LXMF-swift`) carries on top of
upstream (`torlando-tech/LXMF-swift`). **Keep this file current: any commit that adds,
changes, or drops a divergence must update the matching section — and its commit list —
in the same commit.**

These are our own product requirements — there is no intent to upstream them. The point of
this file is to know exactly what to re-apply and what to watch for when pulling upstream
work *in*.

Scope note: this file tracks *fork vs. upstream*. `port-deviations.md` tracks
*Swift port vs. python LXMF* and is upstream's document — entries we add there are
themselves a divergence and are listed under [D3](#d3) below.

- **Upstream base:** `6018671` (`Merge pull request #11 … fix/issue-10-direct-early-close`)
- **Fork HEAD at last update:** `457eb4e` (Deep messaging test fixes)
- **Upstream commits not in this fork:** none — the fork is strictly ahead.
- **Last reviewed:** 2026-08-19 — see [Status at generation](#status) for the measured
  upstream age, commit counts, and unmerged upstream branches.

## Summary

| ID | Area | Change | Commits | Depends on |
|----|------|--------|---------|------------|
| [D1](#d1) | Package.swift | Depend on the `kishontivf` reticulum-swift fork (≥ 0.4.3) | `ce27afc`, `7e4f0d8`, `9c28e09`, `8e0cd70`, `e26f9c6`, `e719af4`, `ed7ee1d`, `457eb4e` | — |
| [D2](#d2) | MessagePack | Depth cap + bounded `reserveCapacity` in the decoder | `1e740b1` | — |
| [D3](#d3) | Router (inbound) | Reject unverified-source messages by default (`acceptUnverifiedMessages`) | `69e48e3` | — |
| [D4](#d4) | Router (outbound) | `PATH_DEMOTE_ATTEMPTS` failover assist | `fbd8a74` | D1 |
| [D5](#d5) | Router (outbound) | Dual-dispatch carrier copy on opportunistic send | `e26f9c6` | D1 |
| [D6](#d6) | Storage | `exportDatabase` / `importDatabase` | `ce27afc` | — |
| [D7](#d7) | Repo hygiene | `.gitignore` additions | `facae56` | — |
| [D8](#d8) | Diagnostics | Outbound-queue / link / resource / proof markers into ReticulumSwift's `NetworkLog` | `457eb4e` | D1 |
| [D9](#d9) | Router (outbound) | Pathless retry: attempt refund, exponential backoff, unproven-route invalidation | `457eb4e` | D1, D4 |
| [D10](#d10) | Storage | `countMessages(forConversation:)` conversation counter | `ed7ee1d` | — |
| [D11](#d11) | Package.swift, Storage | GRDB 7 + SWCompression 4.9; platform floor macOS 14 / iOS 17 | _uncommitted_ | — |
| [D12](#d12) | Router (inbound) | Host delivery policy (`setDeliveryPolicy`) before dedup/storage; proof sent after admission | _uncommitted_ | D3 |
| [D13](#d13) | Storage | `pin_changes` table and its queries, for Intercom's message pinning | _uncommitted_ | — |

### Commit ledger

Every fork commit since the upstream base, oldest first. Merge commits (`413640a`,
`cd2317c` — the PR merges for `feature/fable-security-fixes` and `feature/improvements`)
carry no changes of their own and are omitted.

| Commit | Date | Subject | Divergence |
|--------|------|---------|------------|
| `facae56` | 2026-05-20 | Updates | [D7](#d7) |
| `ce27afc` | 2026-05-30 | Import/Export support | [D6](#d6), [D1](#d1) (repoint + 0.1.1, SWCompression pin) |
| `69e48e3` | 2026-06-23 | Verify messages before storing (it can be optionally disable this) | [D3](#d3) |
| `7e4f0d8` | 2026-06-28 | Version bump | [D1](#d1) (0.1.2) |
| `fbd8a74` | 2026-06-29 | Demote attempts after having multiple failed delivery | [D4](#d4) |
| `9c28e09` | 2026-06-30 | Version bump | [D1](#d1) (0.2.0) |
| `1e740b1` | 2026-07-06 | Fable security fixes | [D2](#d2) |
| `8e0cd70` | 2026-07-09 | Version bump | [D1](#d1) (0.3.0) |
| `e26f9c6` | 2026-07-13 | Dual dispatch | [D5](#d5), [D1](#d1) (0.4.0) |
| `e719af4` | 2026-07-14 | Version bump | [D1](#d1) (0.4.1) |
| `20d3ede` | 2026-08-02 | Divergence collection | This document; no source change |
| `ed7ee1d` | 2026-08-18 | Add the ability to count the messages for a given conversation | [D10](#d10), [D1](#d1) (reticulum 0.4.2) |
| `457eb4e` | 2026-08-19 | Deep messaging test fixes | [D8](#d8), [D9](#d9), [D1](#d1) (reticulum 0.4.3, SWCompression re-widened) |
| _uncommitted_ | 2026-09-15 | GRDB 7 / SWCompression 4.9 bump, export/import tests | [D11](#d11), [D6](#d6) (tests) |

The D-sections below cover **logic/behaviour** divergence. Anything that changes the
*shape* of the data — DB schema or domain model — is tracked separately in
[Schema & domain changes](#schema) and must be logged there too.

---

## Schema & domain changes {#schema}

Standing register for structural changes: new/renamed/dropped **tables**, **columns**,
**indexes**, and new/changed **persisted properties** on domain types. Logic-only changes
do not belong here — this chapter answers "did the stored data shape change, and can an
older or newer build still read it?"

**Current state: two fork migrations** on top of upstream's `v6_add_replies_reactions`:

| Migration | Origin |
|-----------|--------|
| `v1_initial` | upstream |
| `v2_add_favorite` | upstream |
| `v3_add_icon_appearance` | upstream |
| `v4_add_receiving_interface` | upstream |
| `v5_add_pinned` | upstream |
| `v6_add_replies_reactions` | upstream |
| `v7_message_annotations` | fork ([S1](#schema)) — predates rule 2, so it lacks the `kvf` tag |
| `v8_kvf_pin_changes` | fork ([S2](#schema)) |

`acceptUnverifiedMessages` ([D3](#d3)) is in-memory router config, never persisted, and
[D6](#d6) only moved the migrator into `makeMigrator()` and added export/import.

### Ledger

Append one row per structural change. Keep it even after upstream adopts the same idea —
the point is to be able to reconstruct what our stored data looks like at any commit.

| ID | Commit | Date | Migration | Structure changed | Domain property | Reason |
|----|--------|------|-----------|-------------------|-----------------|--------|
| S1 | `5605dd6` | 2026-09-21 | `v7_message_annotations` | `messages` + `edited_content`, `edited_at`, `deleted_at` | `MessageRecord.editedContent`, `.editedAt`, `.deletedAt` | Intercom's edit and delete-for-everyone. Logged late, 2026-11-12. |
| S2 | _uncommitted_ | 2026-11-12 | `v8_kvf_pin_changes` | New table `pin_changes` (`hash` PK, `conversation_hash`, `target`, `actor`, `is_pinned`, `timestamp`, `placed_at`); indexes on `target`, `actor`, (`conversation_hash`, `placed_at`) | `PinChangeRecord` | Intercom's message pinning ([D13](#d13)). New table only: an older build ignores it; restore forward-migrates. |

### Rules for adding one

1. **Append, never edit.** A registered migration has already run on user devices —
   changing its body is silently a no-op there. Add `vN_…` instead.
2. **Pick a fork-safe name.** Upstream will keep adding `v7`, `v8`… against the same
   counter. Name ours `vN_kvf_<what>` so a re-sync produces a visible conflict at the
   migration list instead of two different schemas sharing one identifier.
3. **Log the domain side too.** If the column backs a new property on `LXMessage`,
   `Conversation`, etc., name it in the ledger — that property is part of the public API
   surface consumers compile against.
4. **Check the read-only reader.** Only the writer migrates ([D6](#d6),
   `LXMFDatabase.init`). Under Model B the NE writes and the app reads read-only, and the
   two binaries can be at different versions: a column the app *reads* must be added by a
   migration that has already shipped in the NE. Adding a column and reading it in the same
   release is a crash waiting for whichever process updates second.
5. **Check restore.** `importDatabase(from:)` forward-migrates an older snapshot, so every
   migration must apply cleanly to a database taken before it existed (no assumptions about
   pre-existing rows). Restoring a *newer* snapshot into an older build is not handled —
   note it here if a change makes that scenario worse.
6. **Update the summary table** with a `S<n>` row and this chapter's entry in the same commit.

---

## D1 — Dependency repointing {#d1}

**Commits:** `ce27afc` (repoint to the fork at 0.1.1 + SWCompression exact pin), then the
reticulum floor bumps `7e4f0d8` (0.1.2), `9c28e09` (0.2.0), `8e0cd70` (0.3.0),
`e26f9c6` (0.4.0), `e719af4` (0.4.1), `ed7ee1d` (0.4.2), `457eb4e` (0.4.3 + SWCompression
back to a range)

**Files:** `Package.swift`

- `reticulum-swift` now resolves to `https://github.com/kishontivf/reticulum-swift.git`,
  `from: "0.4.3"` (upstream: `torlando-tech/reticulum-swift`, `from: "0.3.0"`).
- A commented-out `.package(path: "../reticulum-swift")` line is kept for local development.
- SWCompression went to `exact: "4.8.7"` in `ce27afc` and back to upstream's `"4.8.0" ..< "4.9.0"`
  range in `457eb4e`. It diverges again since the 4.9 bump — see [D11](#d11).

**Why it matters:** D4 and D5 call APIs that exist only in the forked reticulum-swift
(`PathTable.markPathUnresponsive`, `ReticulumTransport.sendFallbackCopy`), so the two forks
must be re-synced in lockstep — bumping LXMF-swift to a newer upstream base means checking
that our reticulum-swift fork still carries both APIs.

## D2 — MessagePack decoder hardening {#d2}

**Commits:** `1e740b1` (merged as `413640a`)

**Files:** `Sources/LXMFSwift/Protocol/LXMFMessagePack.swift`,
`Tests/LXMFSwiftTests/LXMFMessagePackHardeningTests.swift`

The decoder runs on raw inbound bytes before any signature or source check
(`LXMessage.unpackFromBytes`), so a crafted header is pre-auth attacker-controlled input.

- **Depth bomb:** `decodeValue` now threads a `depth` parameter and throws past
  `lxmfMessagePackMaxDepth = 64`. Unbounded recursion overflows the native stack, which is
  an uncatchable crash in Swift.
- **Width bomb:** `decodeArray`/`decodeMap` bound `reserveCapacity` by the bytes actually
  remaining (`min(count, remaining)` / `min(count, remaining / 2)`). `reserveCapacity` is
  eager, so a 5-byte `dd ff ff ff ff` would otherwise trap on a multi-billion-slot
  allocation before the loop's end-of-data guard fires.

Four tests cover both bombs plus a shallow-nesting acceptance case.

## D3 — Reject unverified-source inbound messages by default {#d3}

**Commits:** `69e48e3`

**Files:** `Sources/LXMFSwift/Router/LXMRouter.swift` (`lxmfDelivery`),
`Sources/LXMFSwift/Router/LXMRouterDelegate.swift`, `port-deviations.md`,
`Tests/LXMFSwiftTests/LXMRouterDeliveryTests.swift`

Upstream (and python LXMF) drops a present-but-invalid signature and *accepts* a message
whose source identity is not recalled, storing it with `signatureValidated == false`.
This fork additionally drops `.sourceUnknown` messages, because the 16-byte source hash on
the wire is unauthenticated and therefore spoofable.

- New `acceptUnverifiedMessages` (default `false`) + `setAcceptUnverifiedMessages(_:)`
  restores python behaviour.
- `.signatureInvalid` is always rejected regardless of the flag.
- The drop happens **before** `recordDelivered`, so the hash is not blacklisted in the
  dedup set.
- Full rationale is recorded in `port-deviations.md` (that entry is itself part of this
  divergence).

**Known gap:** the "transient, sender retries" argument holds for `.direct` and
`.opportunistic`, but **not** for `.propagated`. `LXMRouter+Sync.swift` ACKs *all*
transient IDs from the LIST regardless of `lxmfDelivery`'s return value, so the
propagation node deletes a message we rejected and nobody retries it — an unverified
source over propagation is a permanent loss. Not yet fixed; see the review notes.

## D4 — `PATH_DEMOTE_ATTEMPTS` failover assist {#d4}

**Commits:** `fbd8a74`

**Files:** `Sources/LXMFSwift/Router/LXMRouter.swift`

New constant `PATH_DEMOTE_ATTEMPTS = 3`. In the outbound processing loop, when a message's
`deliveryAttempts` hits exactly that threshold, the router calls
`pathTable.markPathUnresponsive(destinationHash)` once. `PathTable.record()`'s Path-5 rule
lets a same-emission announce over a *different* interface replace an unresponsive entry,
so a half-dead direct route (e.g. a stale MPC session) can fail over to TCP on the next
announce, with the remaining attempts (up to `MAX_DELIVERY_ATTEMPTS = 8`) using the new path.

**Known gap:** the demotion is method-agnostic. For a `.propagated` message the failure is
with the propagation node, but the *recipient's* path is what gets demoted —
mis-attribution of the same kind already documented for `pendingPropagationSends`.
Impact is limited to announce-acceptance policy.

## D5 — Dual dispatch (carrier copy) on opportunistic send {#d5}

**Commits:** `e26f9c6` (merged as `cd2317c`; same commit bumps reticulum to 0.4.0 for
`sendFallbackCopy`)

**Files:** `Sources/LXMFSwift/Router/LXMRouter+Delivery.swift` (`sendOpportunistic`)

After a successful `transport.send(packet:)`, the router also calls
`transport.sendFallbackCopy(packet:)`. The transport gates it: it fires only when the
destination was heard on a carrier (BLE) interface within 120s and the best path is not
already that carrier. The receiver dedups by packet hash, so the loser is a no-op.

Motivation: the normal route may be a multi-hop TCP path that cannot actually reach the
peer (e.g. it is on 5G behind carrier NAT); the carrier copy delivers directly without
waiting for delivery-failure demotion (D4) to reroute.

**Known gap:** the call sits on the success path only — if `transport.send` throws, the
carrier copy is never attempted, which is arguably when it is most useful. Applies to
`sendOpportunistic` only; `sendDirect` (link-based) has no equivalent.

## D6 — Database export / import {#d6}

**Commits:** `ce27afc`

**Files:** `Sources/LXMFSwift/Storage/LXMFDatabase.swift`

- The schema migrator was extracted from `init` into `private static func makeMigrator()`
  so it can be reused by the restore path. Behaviour in `init` is unchanged (still
  writer-only).
- `exportDatabase(to:)` — `VACUUM INTO ?` via `writeWithoutTransaction`, producing a single
  consistent file with no WAL/SHM sidecars, safe to take while live. The destination must
  not already exist.
- `importDatabase(from:)` — opens the snapshot as a `DatabaseQueue`, `backup(to: dbPool)`
  copies every page into the live pool (so the on-disk path and all existing connections
  stay valid), then re-runs the migrator to forward-migrate an older snapshot.

**Known gaps:** no `readonly` guard on either call; `backup` uses a plain
`writeWithoutTransaction` rather than a barrier write, so pool readers can observe a torn
intermediate state mid-restore; the exported file carries no explicit iOS file-protection
class; and the router's in-memory state (`pendingOutbound`, `deliveredTransientIDs`) is not
reset after a restore, so callers must reload the router.

**Tests:** `Tests/LXMFSwiftTests/LXMFDatabaseExportImportTests.swift` (fork-only file, added with
[D11](#d11)) — export writes one file with no WAL/SHM sidecars, export refuses an existing
destination, import replaces the live contents and conversation counts, the same instance stays
writable, and an unmigrated snapshot is forward-migrated. The known gaps above are not covered.

## D7 — Repo hygiene {#d7}

**Commits:** `facae56`

**Files:** `.gitignore`

Adds `Derived/*`, `*.xcodeproj`, `*.xcworkspace`. Nothing previously tracked became
ignored — `LXMFSwift.xcodeproj`, `Derived/` and `Package.resolved` are untracked locally.

---

## D8 — Outbound-queue diagnostics {#d8}

**Commits:** `457eb4e`

**Files:** `Sources/LXMFSwift/Router/LXMRouter+NetworkDiagnostics.swift` (new, 153 lines),
call sites in `LXMRouter.swift` and `LXMRouter+Delivery.swift`, plus two stored properties
on `LXMRouter` (`lastQueueSummary`, `lastQueueSummaryAt`)

Routes the outbound queue's behaviour into ReticulumSwift's `NetworkLog` — the shared
`<device>-network.log` the on-device test fleet collects. Markers: `[QUEUE]` (census,
enqueue, dequeue, slow attempt, pass duration, no-path, route-exhausted), `[LINK]`
(establishment outcome + duration), `[RES]` (resource lifecycle + throughput), `[PROOF]`
(delivery proof with end-to-end age).

**Why it exists:** the rest of LXMFSwift logs through `os.log`, which never reaches the
on-device log files the automated tests collect — so the outbound queue, the component most
implicated in every "messaging is unreliable" report, was the one part of the send path
nobody could see after the fact.

**Cost when disabled:** every emitter opens with `guard NetworkLog.isEnabled else { return }`,
so the census walk and all hex/byte/rate formatting are skipped; the eight inline
`NetworkLog.debug(…)` sites rely on that function's `@autoclosure`, so no string is built.
The log is off unless the process sets `RETICULUM_NETWORK_LOG` (reticulum-swift `a7909a0`) —
one flag governs the diagnostics in both forks. **Residual cost:** `LXMRouter.swift:793`
builds an 8-byte hex string per queued message per pass, before `shouldAttemptDelivery` and
outside any guard. Same pattern at `:784`, `:1153`, `:1162`, `:1412`, `:1489`, `:1553`,
`:1979`, but those sit on already-rare branches.

**Removal:** the file carries a `[TEMPORARY]` header and every helper and call site is
marked, so `grep -rn '\[TEMPORARY\]'` lists the whole set. Confined to one file plus a
handful of call sites by design, so it can be dropped wholesale or re-applied after an
upstream refresh without untangling it from real logic.

## D9 — Pathless retry and unproven-route invalidation {#d9}

**Commits:** `457eb4e`

**Files:** `Sources/LXMFSwift/Router/LXMRouter.swift`

Extends [D4](#d4). Three behaviours in the outbound loop:

1. **Attempt refund.** A message that could not be attempted *because no path existed* no
   longer spends a delivery attempt (`rescheduleWithoutPath`). `MAX_DELIVERY_ATTEMPTS`
   counts transmissions that were tried and failed; billing it for "the device had no route"
   made the 24 h `MAX_OUTBOUND_AGE` unreachable in exactly the case it exists for — a
   pathless message burned all 8 attempts in ~151 s and was discarded permanently. The
   2026-08-12 field test lost two messages this way 66 s and 82 s *before* WiFi returned.
2. **Exponential backoff while pathless.** `retryBackoff(step:)` = `RETRY_BACKOFF_BASE * 2^step`
   capped at `RETRY_BACKOFF_CAP` — 2 s, 4 s, 8 s … 256 s, then flat at 300 s, tracked per
   message hash in `pathlessBackoffSteps`. Starting at 2 s is deliberate: most interruptions
   are brief (a lift, a doorway, a carrier handover) and a fixed floor made recovery slower
   than the outage. `wakeMessagesWithFreshPath()` clears the step and re-arms a message the
   moment a path reappears, so the curve never outlives the outage.
3. **Unproven-route invalidation.** At `PATH_DEMOTE_ATTEMPTS`, and again at
   `MAX_DELIVERY_ATTEMPTS`, `invalidateUnprovenPath(_:)` removes the path-table entry and
   requests a fresh one, rate-limited per destination by `PATH_INVALIDATION_COOLDOWN` (30 s).
   At the second threshold the message is not failed: attempts reset to zero, it is re-queued
   `UNPROVEN_ROUTE_RETRY_WAIT` (300 s) out and recorded in `awaitingFreshPath`.

**New router state:** `pathlessBackoffSteps`, `awaitingFreshPath`, `lastPathInvalidation`
(all in-memory, none persisted — a restart loses the backoff curve and every message starts
due again).

**Tests:** `Tests/LXMFSwiftTests/LXMRouterPathlessRetryTests.swift` (156 lines) and
`LXMRouterUnprovenRouteTests.swift` (258 lines).

**Merge risk:** this is the highest-conflict divergence in the fork. It inserts branches
into the middle of `processOutbound`, the loop upstream actively maintains, and it now owns
the meaning of `deliveryAttempts` — any upstream change to attempt accounting will collide
here rather than merge.

## D10 — Conversation message count {#d10}

**Commits:** `ed7ee1d`

**Files:** `Sources/LXMFSwift/Storage/LXMFDatabase.swift`

`public func countMessages(forConversation hash: Data) throws -> Int`. Answered from
`idx_messages_conversation_timestamp`, whose leading column is `conversation_hash`, so it
reads the index rather than the rows and never decodes content, attachments or the packed
envelope — the alternative was `getMessages(forConversation:limit:offset:)`, which
materialises every blob to arrive at the same number.

Additive public API on the database type; registers no migration and changes no table — see
[Schema & domain changes](#schema).

## D11 — GRDB 7 and SWCompression 4.9 {#d11}

**Commits:** _uncommitted_ (2026-09-15)

**Files:** `Package.swift`, `Sources/LXMFSwift/Storage/LXMFDatabase.swift`

- `GRDB.swift` `from: "7.11.1"` (upstream: `from: "6.0.0"`).
- `SWCompression` `from: "4.9.1"` (upstream: `"4.8.0" ..< "4.9.0"`).
- Platform floor macOS 14 / iOS 17 (upstream: macOS 13 / iOS 16). SWCompression 4.9 requires
  it; this drops iOS 16 devices, which Analog (iOS 18 minimum) never ran on.
- `LXMFDatabase.init` no longer sets `config.defaultTransactionKind = .immediate` — upstream
  code whose property GRDB 7 removed. GRDB 7 manages the kind itself: writes IMMEDIATE, reads
  DEFERRED, so the Model B writer still takes write locks up front.

**Why:** done while getting the fork to build under Xcode 27 (2026-09-15).

**Checked against GRDB 7's migration guide:** every database access in the fork is a synchronous
`dbPool.read`/`write` inside the actor, so async-access cancellation doesn't apply; no
`ValueObservation`; no record type declares the removed static coding-strategy properties (which
would still compile but silently change the stored format). `swift test` passes (139 tests).

**Re-sync risk:** upstream is still on GRDB 6. Any upstream change using removed GRDB 6 API —
`defaultTransactionKind`, the static `database…Strategy` properties, `concurrentRead` — must be
adapted when pulled in, and the static strategies won't fail the build.

---

## D12 — Host delivery policy and proof-after-admission {#d12}

**Commits:** _uncommitted_

**Files:** `Sources/LXMFSwift/Router/LXMRouter.swift` (`LXDeliveryOutcome`, `LXDeliveryPolicy`,
`setDeliveryPolicy`, `deliver`, `shouldProve`; `lxmfDelivery` is now a Bool wrapper),
`Sources/LXMFSwift/Router/LXMRouter+Destinations.swift` (`deliveryPacket`),
`Sources/LXMFSwift/Router/LXMRouterDelegate.swift`, `port-deviations.md`,
`Tests/LXMFSwiftTests/LXMRouterDeliveryPolicyTests.swift`

Upstream (and python) proves an inbound packet before unpacking it and has no host admission
hook in the Swift port (python's `ignored_list` was never ported). The host app admits only its
contacts and must not prove to a blocked sender.

- `setDeliveryPolicy(_:)` installs an async `(sourceHash, fields) -> Bool`, consulted after the
  signature/unverified checks and **before** `recordDelivered`, so a rejected hash is not
  blacklisted and is accepted once the host allows the source.
- `deliveryPacket` now proves **after** `deliver`, and skips the proof only for
  `.rejectedByPolicy`; duplicates and parse failures still prove.
- Resource transfers are proved inside reticulum-swift (`Resource.assemble`) before LXMF runs,
  so a policy-rejected resource is still proved.

**Known gap:** same as [D3](#d3) for `.propagated` — the sync ACKs every transient ID, so a
policy-rejected message pulled from a propagation node is deleted there for good. That is the
intended outcome for a blocked or unknown sender.

## D13 — Pin changes {#d13}

**Commits:** _uncommitted_ (2026-11-12)

**Files:** `Sources/LXMFSwift/Storage/PinChangeRecord.swift`, `Sources/LXMFSwift/Storage/LXMFDatabase.swift`,
`Tests/LXMFSwiftTests/PinChangeTests.swift`

Storage for Intercom's message pinning: one `pin_changes` row per pin or unpin ([S2](#schema)).
The fork only stores and answers queries (`savePinChange`, `pinChanges(forConversation:)`,
`pinChanges(forTarget:)`, `pinLines(forConversation:)`, `latestPinLines()`,
`waitingPinChangeCount(fromActor:)`, `deleteWaitingPinChanges(olderThan:)`,
`deletePinChanges(forTarget:)`); the pinning rules live in Intercom.

- No foreign key: a change can wait for a message, or a conversation row, that hasn't arrived.
- `deleteConversation` also deletes the conversation's rows; `deleteMessage(id:)` deletes rows
  whose *target* is that message, never by the row's own hash, because command envelopes are
  discarded through it.

## Re-sync checklist

When pulling new upstream work:

1. `git fetch upstream && git log --oneline HEAD..upstream/main`
2. Re-sync `kishontivf/reticulum-swift` first if upstream moved its reticulum floor ([D1](#d1)).
3. Conflict-prone files, in order of likelihood:
   `Sources/LXMFSwift/Router/LXMRouter.swift` (D3, D4, **D9**, D8 call sites),
   `Sources/LXMFSwift/Router/LXMRouter+Delivery.swift` (D5, D8 call sites),
   `Sources/LXMFSwift/Storage/LXMFDatabase.swift` (D6, D10, D11, D13),
   `port-deviations.md` (D3), `Package.swift` (D1, D11).
   `LXMRouter+NetworkDiagnostics.swift` (D8) is a new file and cannot conflict; it is listed
   here only because its call sites live in the two files above.
   **Start with [D9](#d9)** — it rewrites the middle of `processOutbound` and redefines what
   `deliveryAttempts` counts, so an upstream change to attempt accounting lands there first.
4. Diff the migration list in `LXMFDatabase.makeMigrator()` against
   [Schema & domain changes](#schema). Upstream numbering ours by collision (two different
   `v7`s) is the failure mode to look for — resolve by renaming ours to a later
   `vN_kvf_…`, never by editing an already-shipped migration.
5. Grep incoming upstream storage code for GRDB 6-only API ([D11](#d11)): `defaultTransactionKind`,
   `static … database…Strategy`, `concurrentRead`.
6. `swift build && swift test`.
7. Update the base/HEAD/last-reviewed lines at the top of this file, append any new
   fork commits to the [commit ledger](#summary), and refresh
   [Status at generation](#status) + add a [Document changelog](#doc-changelog) row.

---

## Status at generation {#status}

**Generated:** 2026-08-02, **updated 2026-08-19** (all figures below measured on the update
date, against `upstream` = `git@github.com:torlando-tech/LXMF-swift.git` after
`git fetch upstream`).

| Metric | Value |
|--------|-------|
| Fork HEAD | `457eb4e` — 2026-08-19 |
| Upstream base we sit on | `6018671` — 2026-06-20 (**60 days old**) |
| Upstream `main` tip | `6018671` — identical to our base |
| Upstream commits we are missing | **0** — `upstream/main` has not moved since we branched |
| Our commits ahead of upstream | **15** (13 content commits + 2 PR merges) |

So the fork is strictly ahead: nothing to pull, 15 commits to carry. The "60 days old"
figure is the age of upstream's newest work, not a backlog — upstream `main` itself has
been idle since 2026-06-20.

**Unmerged upstream branches** (not on `main`, so not counted above, but they are where the
next re-sync conflict will come from):

| Branch | Ahead of `main` | Tip | Relevance |
|--------|-----------------|-----|-----------|
| `fix/reaction-nested-int-map` | 1 | `aeef5f3` — 2026-07-16 | Touches `LXMessage` pack/unpack of integer-keyed nested field maps; no overlap with our D-sections, but it is newer than our base |
| `chore/use-local-reticulum-swift-path` | 3 | `f953d40` — 2026-04-23 | Points reticulum at a local path + CI workflow — conflicts head-on with [D1](#d1) if ever merged |
| `chore/add-mpl-copyright-notice` | 2 | `c80b033` — 2026-03-23 | Licence headers; touches every source file, so expect broad textual conflicts |

**Ledger date note:** the commit ledger shows **author** dates. `facae56` and `ce27afc`
were authored 2026-05-20 / 2026-05-30 but rebased onto the current base on 2026-06-23
(their committer dates), which is why they read as older than the base they sit on.

## Document changelog {#doc-changelog}

Revisions to *this file*, newest first. One row per edit; the "Covers" column is the fork
HEAD the file described at that point.

| Date | Covers | Change |
|------|--------|--------|
| 2026-11-12 | `6a4962d` + uncommitted | Added [D13](#d13) and the schema ledger's S1 (`v7_message_annotations`, logged late) and S2 (`v8_kvf_pin_changes`). Commits since `3aa1b8b` are not yet audited into the commit ledger. |
| 2026-09-25 | `3aa1b8b` + uncommitted | Added [D12](#d12) (host delivery policy, proof after admission). |
| 2026-09-15 | `ef0c712` + uncommitted | Added [D11](#d11) (GRDB 7, SWCompression 4.9, macOS 14 / iOS 17) and [D6](#d6)'s tests; D1 no longer carries SWCompression; re-sync checklist gains the GRDB 6 API grep. Commits `19f7c6b`, `49061a6`, `93e3d0c` since `457eb4e` are not yet audited into the ledger. |
| 2026-08-19 | `457eb4e` | Added [D8](#d8) (queue diagnostics), [D9](#d9) (pathless retry / unproven-route invalidation) and [D10](#d10) (message count). Corrected [D1](#d1): reticulum floor is 0.4.3 and the SWCompression pin went back to upstream's range. Refreshed the ledger, re-sync checklist and status. |
| 2026-08-02 | `e719af4` | Added [Status at generation](#status) and this changelog. |
| 2026-08-02 | `e719af4` | Added commit IDs: `Commits` column in the summary table, the [commit ledger](#summary), per-section `**Commits:**` lines on D1–D7, and a `Commit` column in the schema ledger. |
| 2026-08-02 | `e719af4` | Initial version — D1–D7, [Schema & domain changes](#schema), re-sync checklist. |
