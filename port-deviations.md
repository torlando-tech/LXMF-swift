# LXMF-swift port deviations

All logic in this swift port mirrors `../LXMF/LXMF/` (python reference).
Any deviation from the python reference must be documented here with the
file:line, the python reference site, and the reason.

## Active deviations

### `LXStamper.generateStampSync` — pre-fed SHA256 digest (perf-equivalent rewrite)

**Site:** `Sources/LXMFSwift/Protocol/LXStamper.swift` — `generateStampSync`
inner loop, `SHA256_PrimedDigest` helper alongside it.

**Python reference:** `LXMF/LXStamper.py:160-165` — `job_simple`'s `sv()`:

```python
def sv(s, c, w):
    target = 0b1<<256-c; m = w+s
    result = RNS.Identity.full_hash(m)
    if int.from_bytes(result, byteorder="big") > target: return False
    else:                                                return True
```

Python rebuilds `m = w+s` (workblock + stamp) and SHA256-hashes the whole
thing on every attempt. At cost=16 with the 1000-round PN workblock
(~256 KB), that's ~65k * full-SHA-of-256KB on the inner loop — multi-
minute on phones, single-second on dev boxes. Python tolerates the
cost because `multiprocessing.Process` spreads it across cores
(`job_linux`).

**Swift change:** pre-feed the workblock into a single `SHA256` context
(`SHA256_PrimedDigest`) once. Each attempt clones the in-progress digest
state, finalizes with the stamp suffix, and reads the 32-byte hash.
Output is byte-for-byte identical to `SHA256.hash(workblock + stamp)`.

**Reason:** Category (a) — language/runtime perf. The hash semantics
are unchanged (CryptoKit's `SHA256` is the same SHA-256 specified by
RFC 6234 that python's `RNS.Identity.full_hash` calls). What changed is
*how the swift inner loop computes that hash* — the algorithm is
identical, the byte buffer allocation pattern is not.

Mirrors the kotlin port's reticulum-kt#66 fix, which dropped cost=16
stamp gen from ~21s to ~400ms on phones with the same approach.

### `LXStamper.generateStampParallel` — concurrent worker variant (language-equivalent of `job_linux`)

**Site:** `Sources/LXMFSwift/Protocol/LXStamper.swift` — `generateStampParallel`,
`StampResultBox` shared-state container.

**Python reference:** `LXMF/LXStamper.py:179-258` — `job_linux` spawns N
`multiprocessing.Process` workers that each run the inner `sv()` loop on
its own RNG, racing to find a valid stamp. First worker to find one
publishes via `result_queue` and sets `stop_event`; others see the event
and exit. Python uses `cores if cores <= 12 else int(cores/2)`.

**Swift change:** uses `withTaskGroup(of: Int.self)` to spawn
`min(8, ProcessInfo.processInfo.activeProcessorCount)` worker tasks at
`.userInitiated` priority. Each task owns its own primed digest + RNG
(via `SecRandomCopyBytes`). `StampResultBox` is the swift
`stop_event + result_queue` — first writer wins, sets a flag; other
tasks check the flag at the top of each iteration and exit.

**Reason:** Category (a) — language/runtime accommodation. Swift on iOS
cannot use `multiprocessing` (no `fork()`, no IPC across processes from
inside an app sandbox). Swift Concurrency's `TaskGroup` is the standard
language-level equivalent and runs on the cooperative thread pool.
Worker count is capped at 8 because the python upstream caps at
`cores/2` for >12-core systems and we mirror that floor; modern A-series
SoCs have 4-8 performance cores and capping at 8 prevents thrash.

Algorithm + termination semantics are identical to `job_linux`:
- Each worker independently generates random 32-byte stamps until valid
- First valid stamp wins
- Other workers exit on next iteration
- Total rounds across all workers is summed and returned

The `job_simple` synchronous path (`generateStampSync`) is preserved
unchanged for callers that prefer single-threaded determinism (tests,
bridges) — also mirrors python's fall-back behavior on platforms
without multiprocessing.

### `processOutbound` optimistic queue removal + `handleOutboundResourceFailed` re-enqueue

**Site:** `Sources/LXMFSwift/Router/LXMRouter.swift` — `processOutbound`
(the `indicesToRemove.insert(i)` immediately after `sendOpportunistic`
/ `sendDirect` / `sendPropagated` returns) and
`handleOutboundResourceFailed` (the `pendingOutbound.append(msg)`
re-enqueue at the bottom).

**Python reference:** `LXMF/LXMF/LXMRouter.py:2513-2562` —
`process_outbound` is a STATE-DRIVEN loop. It iterates
`self.pending_outbound` on every tick and only `pending_outbound.remove(...)`s
when `lxmessage.state` is truly terminal: `DELIVERED` (line 2519),
`SENT` for PROPAGATED (line 2544), `CANCELLED` (line 2548), or
`REJECTED` (line 2554). For any other state — including the
intermediate `OUTBOUND` that `__resource_concluded` sets after a
failed resource transfer (LXMessage.py:600) — the message stays in
`pending_outbound` and the next `process_outbound` tick re-attempts.
The retry path naturally re-uses the same LXMessage object.

**Swift change:** the swift port removes from `pendingOutbound` via
`indicesToRemove` immediately after the per-method send function
returns successfully, regardless of whether the resulting state is
truly terminal or merely in-flight (e.g. `.sending` for a
resource-path PROPAGATED whose RESOURCE_PRF hasn't arrived). For
async failures discovered after this optimistic removal — most
prominently a resource transfer concluding in a non-`.complete`
state — `handleOutboundResourceFailed` now re-appends the message
to `pendingOutbound` and kicks `processOutbound` so the retry path
fires. The DB row's state is updated first so the re-loaded
LXMessage reflects `.outbound` (mirroring python's in-place state
transition on a still-queued message).

**Reason:** Category (a) — the broader optimistic-remove design
predates this PR (`indicesToRemove` is used to batch removals at the
end of each `processOutbound` iteration so we don't mutate the array
while iterating, which is harder in swift than python). Aligning
fully with python's state-driven keep-in-queue model would require
restructuring `processOutbound` to never call `indicesToRemove.insert`
unless the message hit a terminal state. That's a bigger refactor.
The `handleOutboundResourceFailed` re-enqueue is the targeted patch
that restores python's observable retry behavior for failed resource
transfers — the specific case greptile review flagged as silently
dropping messages on PR #7. Other in-flight async failures (link
timeout before any callback fires, send throws inside the per-method
function) are already handled by the existing throw/catch path in
`processOutbound` that schedules a `nextDeliveryAttempt` retry.

**Re-sync note:** the right long-term fix is restructuring
`processOutbound` to mirror python's lifecycle — only remove from
`pendingOutbound` on DELIVERED / SENT(PROPAGATED) / REJECTED /
CANCELLED. When that lands, both the `indicesToRemove` machinery and
the `handleOutboundResourceFailed` re-enqueue can be deleted; the
state-driven loop will handle resource-failure retries naturally.

**Sub-deviation (PROPAGATED resource path DB write, PR #7 round 2):**
The in-flight DB write for a PROPAGATED+RESOURCE message (immediately
after `sendPropagated` returns with `message.state == .sending`)
persists `state = .outbound` (not the in-memory `.sending`) and writes
the FULL message record via `saveMessage`, not the state column alone
via `updateMessageState`.

  - `.outbound` over `.sending` — `loadPendingOutbound()`
    (`LXMFDatabase.swift:459-468`) filters strictly on
    `state == .outbound`. Persisting `.sending` would make a
    crash-during-in-flight message invisible to the restart queue.
    `.outbound` is the safe fallback: on restart the message is
    re-enqueued and re-attempted; in steady state the resource
    callbacks (`handlePropagationAccepted` → `.sent`,
    `handleOutboundResourceFailed` → `.outbound`/`.rejected`/`.cancelled`)
    overwrite this with the real terminal state.
  - `saveMessage` over `updateMessageState` — the optimistic removal
    from `pendingOutbound` happens BEFORE `persistPendingState`'s
    full-record save, so without a full-record write here the DB
    misses the just-incremented `deliveryAttempts`. The resource-
    failure re-enqueue (`handleOutboundResourceFailed` reloads
    via `database.getMessage`) would otherwise see stale
    `deliveryAttempts = 0` and grant unlimited retries, defeating
    `MAX_DELIVERY_ATTEMPTS`.

Python has no analog because python doesn't persist `pending_outbound`
to disk at all. This sub-deviation is purely the swift port's
crash-recovery semantics. The re-sync note above still applies — once
the long-term refactor lands, this entire DB-write block goes away
(the message stays in `pendingOutbound`, `persistPendingState` covers
durability, and the callbacks just mutate in-memory state).

### `lxmfDelivery` — broadcast-echo-only self-echo gate

**Site:** `Sources/LXMFSwift/Router/LXMRouter.swift` — `lxmfDelivery(_:method:)`,
the `if sourceHash == localDeliveryHash && destinationHash != localDeliveryHash && method != .propagated` block.

**Python reference:** `LXMF/LXMF/LXMRouter.py` — there is **no** equivalent
self-echo gate anywhere in `lxmf_delivery`/`handle_outbound_completed`.
Python relies on the duplicate-hash check (`message.hash` lookup against
the local delivery store) to drop messages it has already seen, including
self-echoed ones.

**Swift change:** the swift port silently drops inbound messages whose
`sourceHash` equals the local LXMF delivery hash AND whose `destinationHash`
is NOT the local delivery hash AND whose method is not `.propagated`.
This is a doubly-narrowed form of the original 2026-02-05 fix
(commit `9992795` "fix(lxmf): prevent relay self-echo from overwriting
outbound messages").

The narrowing was applied iteratively as the iOS smoke pipeline
started exercising legitimate self-loop cases:

  1. **Original (2026-02-05)** — `sourceHash == localDeliveryHash`
     unconditionally rejected. Broke `propagated_bidirectional` smoke
     scenario (phone uploads to PN, syncs it back, gate rejected the
     sync delivery as self-echo).
  2. **First narrowing (2026-05-10 morning)** — added `&& method != .propagated`.
     Fixed propagated; still broke `direct_bidirectional` and
     `opp_bidirectional` (phone sends to its own destination over a
     link or single packet — TCP relay echoes the packet back, and
     the gate rejected it as self-echo even though the message was
     legitimately addressed to us).
  3. **Second narrowing (2026-05-10 afternoon)** — added
     `&& destinationHash != localDeliveryHash`. Now the gate only
     fires when the source is us AND the destination is someone
     else AND the method is non-propagated, which is exactly the
     TCP-relay-broadcast-of-our-outbound case.

**Reason:** Category (a) — language/runtime accommodation. Specifically:
swift's `Database` layer (`LXMFDatabase` SQLite store) treats hash as a
PRIMARY KEY; an inbound write of an already-stored outbound message
flips the row's `incoming` flag and overwrites `conversation_hash`,
which python's database (filesystem-of-pickles in
`storage_path/messagestore`) does not do because it doesn't have a
"row" with mutable state — each message is its own file.

The TCP-relay broadcast path (which pumps every outbound packet back
to the sender on the same TCPInterface — see `RNS.TCPInterface`) is
the failure mode that triggered the original gate. That path uses
`.direct`/`.opportunistic`, never `.propagated` (propagation goes via
the propagation-node link, not the broadcast bus). Excluding
`.propagated` from the gate restores the python behavior for the
sync-pull path while preserving the swift-DB-specific safety on the
broadcast path.

**Re-sync note:** if upstream python LXMF gains its own equivalent
gate (or if swift's `LXMFDatabase` is reworked so that a duplicate
hash insert is a true noop / error rather than an overwrite), this
deviation should be revisited and possibly removed.

## Resolved deviations

(none yet — this file was created during the iOS smoke-pipeline
work on 2026-05-10 to document the Stamper perf rewrite. Future
re-syncs should append entries here when introducing language-driven
or perf-driven divergences.)
