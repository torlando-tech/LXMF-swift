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

**Sub-deviation (PROPAGATED resource path DB write ORDERING, PR #7
round 3):** The in-flight `.outbound` write in `processOutbound`'s
PROPAGATED+RESOURCE branch AND the matching `.sent` write in
`handlePropagationAccepted` are both `await`-ed inside the actor
(NOT `Task.detached`). The actor's serial mailbox is the
ordering primitive — without it, the two `Task.detached` writes
would land on the global executor in indeterminate order, and a
fast RESOURCE_PRF (where `handlePropagationAccepted` is queued
before `processOutbound`'s `.outbound` write has even started)
could see its `.sent` write clobbered by a late-landing
`.outbound`, leaving a successfully-propagated message marked
`.outbound` for re-send on next launch.

Python has no analog because (a) python has no DB writes here at
all, (b) python's `process_outbound` is a single-threaded loop
with no async callbacks landing on a separate executor. The
actor-serialized `await` is the swift-runtime equivalent of
python's "the next process_outbound tick will see the in-memory
state mutation that just happened". Category (a) — language/
runtime needs.

**Re-sync note (concurrency):** if the longer-term refactor (above)
lands and `pendingOutbound` becomes the single source of truth
with `persistPendingState` covering durability, the explicit
per-write `await`s can collapse back to a single batched flush.
Until then, leave both writes awaited.

**Sub-deviation (`pendingPropagationSends` + `pendingPropagationRejections`
side-channel for `ERROR_INVALID_STAMP`, PR #7 round 4):** the
swift port maintains two router-side data structures —
`pendingPropagationSends: [Data]` (FIFO of in-flight prop-send
message hashes) and `pendingPropagationRejections: Set<Data>`
(hashes that received an `ERROR_INVALID_STAMP` signal while in
flight) — that have no python analog.

**Python reference:** `LXMF/LXMRouter.py:2498-2511` —
`propagation_transfer_signalling_packet`:

```python
if signal == LXMPeer.ERROR_INVALID_STAMP:
    if hasattr(packet, "link") and hasattr(packet.link, "for_lxmessage"):
        lxm = packet.link.for_lxmessage   # link → LXMessage back-pointer
        self.cancel_outbound(lxm.message_id, cancel_state=LXMessage.REJECTED)
```

Python attaches the in-flight LXMessage to the `RNS.Link` as
`link.for_lxmessage` before sending. The signal handler reads the
LXMessage directly off `packet.link.for_lxmessage` — O(1) lookup,
no scan, no race. The mutated `LXMessage.state` is observed by
the next `process_outbound` tick (because the LXMessage object
in `pending_outbound` IS the same object the link points to).

**Swift port reality:** reticulum-swift's `Link` has no
`for_lxmessage` (or equivalent) back-pointer to LXMF-side state.
Adding one would require an upstream reticulum-swift API change.
Additionally, the swift port's `processOutbound` operates on a
`var msg = pendingOutbound[i]` COPY and writes back only after the
per-method send returns; during that window
`pendingOutbound[i].state` is still `.outbound`, NOT `.sending`,
so a "scan pendingOutbound for state==.sending" approach (which
LXMF-swift originally used) is structurally dead code: the scan
never matches in the small-packet path because the in-array state
hasn't transitioned, and the scan never matches in the resource
path because the slot is already removed by `indicesToRemove`
before the async signal arrives.

**Swift change:** two router-side fields tracking in-flight
prop-sends by message HASH (stable across async boundaries),
populated at the top of `sendPropagated` (before any `await`) and
drained on success / timeout / signal:

  - `pendingPropagationSends: [Data]` — FIFO queue. The most-
    recent push is the most-recent in-flight send, which is the
    one a single arriving `ERROR_INVALID_STAMP` signal almost
    certainly refers to (the PN can't multiplex per-message
    signaling without the message_id in the payload, which python
    doesn't include).
  - `pendingPropagationRejections: Set<Data>` — populated by the
    signal handler, consulted by `sendPropagated`'s small-packet
    branch after `waitForPacketProof` returns. If the in-flight
    message's hash was added to the rejections set during the
    proof-wait window, sendPropagated overrides the normal
    `.sent` / `.outbound` outcome with `.rejected` and throws.

Together they restore python's `cancel_outbound(cancel_state=
REJECTED)` semantics: the signal handler updates DB state +
notifies the delegate immediately; sendPropagated's caller
sees the rejection on return AND a late-arriving proof (race
case where the PN both rejects the stamp and delivers the
message) is correctly classified as `.rejected` rather than
`.sent`.

**Reason:** Category (a) — language/runtime accommodation for
the missing reticulum-swift Link back-pointer plus swift's
copy-modify-writeback queue pattern. Python's mechanism doesn't
port directly. The pair of side-channel fields is the smallest
correct alternative.

**Residual risk (acknowledged):** the FIFO is GLOBAL (one queue
across all propagation node links). Two propagated messages in
flight in the same `processOutbound` pass, combined with a
stamp-rejection signal arriving >15s late (after the first
message's `waitForPacketProof` timeout drained its hash) can
mis-attribute the signal to the second message. Greptile-iterator
round 7 surfaced this on 2026-05-10; expert-lxmf REJECTED the
in-line mitigation as over-engineering for a low-exposure
residual risk. Real fix tracked as follow-up.

**Re-sync note:**
  - Lower-cost swift-side fix (preferred, no upstream blocker):
    scope the FIFO per-link by keying on `propagationLinks`
    nodeHash. The signal handler already receives the packet
    callback on a specific link; threading nodeHash through the
    handler signature lets us pop only from THAT link's FIFO.
    Reduces the mis-attribution window to "two messages in
    flight to the SAME PN simultaneously."
  - Full python parity (blocked upstream): if reticulum-swift
    gains a public `Link.userInfo` / `Link.attachedObject` hook,
    both fields can collapse into a single direct lookup,
    mirroring python's `link.for_lxmessage` exactly. Until
    then the global FIFO + rejections set is the
    path-of-least-divergence in this PR's scope.

**Sub-deviation (`pendingPropagationRejections` short-circuit in
`handleOutboundResourceFailed`, PR #7 round 5):** when the
propagation node sends `ERROR_INVALID_STAMP` mid-resource-upload,
the signal handler sets `.rejected` synchronously, then the
resource transfer concludes with `.failed` (the PN tore down the
link). `handleOutboundResourceFailed`'s default propagation
branch would overwrite the DB row with `.outbound` and re-enqueue
the message for retry — which is wrong, because the stamp config
is config-driven and the same rejection will repeat for every
retry until `MAX_DELIVERY_ATTEMPTS`, each time firing
`didFailMessage` and spamming any UI listener.

The new short-circuit (`Sources/LXMFSwift/Router/LXMRouter.swift`,
inside `handleOutboundResourceFailed` at the
`else if wasPropagation && pendingPropagationRejections.contains(messageHash)`
branch) routes the conclusion through the terminal path with
`newState = .rejected` (preserving the signal handler's DB write)
AND suppresses the duplicate delegate notify in the terminal
block (the signal handler already fired
`didFailMessage(.stampValidationFailed)`, which is more accurate
than the resource-failure path's
`"resource transfer rejected by peer"` reason).

**Python reference:** `LXMF/LXMessage.py:603-609` —
```
def __propagation_resource_concluded(self, resource):
    if resource.status == RNS.Resource.COMPLETE:
        self.__mark_propagated()
    else:
        if self.state != LXMessage.CANCELLED:
            resource.link.teardown()
            self.state = LXMessage.OUTBOUND
```

Python's guard checks `state != CANCELLED`, not `!= REJECTED` —
which means python's resource conclusion DOES overwrite REJECTED
with OUTBOUND when called after `cancel_outbound(REJECTED)`. The
reason python doesn't observe a retry-spam bug from this is
that python's `pending_outbound` removal happens through a
different mechanism: when the next `process_outbound` tick sees
`state == REJECTED` (LXMRouter.py:2552-2556) it removes the
LXMessage from the queue and fires the failed callback. By the
time the resource callback fires (post-teardown, async), the
LXMessage is no longer in `pending_outbound`; the late
`state = OUTBOUND` assignment lands on a dangling object
reference and is a no-op.

**Swift port has no such detachment.**
`handleOutboundResourceFailed` is the swift accommodation that
**reloads the message from the DB and re-appends to
`pendingOutbound`** (documented under "processOutbound
optimistic queue removal + handleOutboundResourceFailed
re-enqueue" earlier in this file). That swift-specific reload
turns python's harmless late assignment into an actively
harmful retry loop, which this sub-deviation prevents.

**Reason:** Category (a) — language/runtime accommodation
required because swift's DB-driven re-enqueue mechanism makes
visible what python's reference-detachment hides. The
`pendingPropagationRejections` check restores observable
end-of-line semantics for stamp-rejected propagated resources,
matching what python's user-visible behavior is (one failure
notification, no retry spam).

**Re-sync note:** if the long-term refactor of `processOutbound`
to a python-style state-driven keep-in-queue model (see the
"Re-sync note" under "processOutbound optimistic queue removal"
above) lands, the swift-specific re-enqueue path goes away and
this sub-deviation can be deleted along with it.

**Sub-deviation (DIRECT resource path DB write + ordering parity,
PR #7 round 6):** Greptile (4/5 confidence) flagged that the
DIRECT branch in `processOutbound` was writing `.sent` via
`Task.detached` immediately after `sendDirect` returned, without
the guarded `saveMessage(.outbound)` pattern the PROPAGATED
branch gained earlier in this PR. The same crash-recovery gap
greptile previously identified for PROPAGATED applied verbatim:
a large DIRECT resource transfer that crashes between
`sendDirect` returning and the resource conclusion firing left
the DB at `.sent` with no re-enqueue path on restart.

Fix applies the same three changes to the DIRECT path:

  1. `sendDirect` (`LXMRouter+Delivery.swift`) leaves
     `message.state = .sending` for the resource path (small-
     packet still sets `.sent` because the packet has already
     been transmitted). This matches python `LXMessage.send`
     (LXMessage.py:498-512) — `__as_packet().send()` is followed
     by `state = SENT` immediately; `__as_resource().advertise()`
     leaves state alone for the resource callback to update.
  2. `processOutbound` DIRECT case (`LXMRouter.swift`)
     branches on `snapshot.state == .sending`:
     resource → `saveMessage(.outbound)` (full record, carries
     `deliveryAttempts`); small-packet → `updateMessageState(.sent)`
     (state column only). Both awaited inside the actor.
  3. `handleDeliveryProofReceived` (`LXMRouter.swift`) is now
     `async` and `await`s its DB write of `.delivered`, so the
     actor mailbox serializes the `.outbound`→`.delivered`
     transition. Without this, a fast RESOURCE_PRF could land
     `.delivered` via `Task.detached` before `processOutbound`'s
     `.outbound` write, leaving the message marked `.outbound`
     for a duplicate re-send.

**Python reference:** `LXMessage.py:498-512` (`send`), :556-566
(`__mark_delivered`), :592-601 (`__resource_concluded`). Python's
DIRECT resource conclusion writes `state = DELIVERED` on COMPLETE
and `state = REJECTED`/`OUTBOUND` on failure; swift now mirrors
the COMPLETE branch with an awaited DB write and the failure
branches via `handleOutboundResourceFailed` (already wired).

**Reason:** Category (a) — same actor-isolation + DB-persistence
accommodation the PROPAGATED branch needed (since python doesn't
persist `pending_outbound` at all, the DB row is purely a
swift-port concern). The fix brings DIRECT into parity with the
PROPAGATED treatment that landed earlier in this PR.

**Re-sync note:** absorbed by the same long-term refactor — when
`processOutbound` moves to a python-style state-driven loop, the
in-flight `.outbound` DB write goes away and the resource
callbacks just mutate in-memory state.

**Sub-deviation (OPPORTUNISTIC keep-in-queue + `.sent` reload, 2026-06-19):**
This is the "long-term refactor" from the re-sync note above, landed for the
OPPORTUNISTIC path only. `processOutbound`'s opportunistic branch no longer
`indicesToRemove.insert(i)`s the message at `.sent`; it leaves it in
`pendingOutbound` and sets `nextDeliveryAttempt = now + DELIVERY_RETRY_WAIT`.
The message is now removed only by the `.delivered` check at the top of the loop
(set by `handleDeliveryProofReceived`, which also flips the in-memory entry to
`.delivered`) or the `MAX_DELIVERY_ATTEMPTS` check. This brings the opportunistic
path into **exact parity** with python `process_outbound`
(`LXMRouter.py:2566-2592`): keep in `pending_outbound`, re-send every
`DELIVERY_RETRY_WAIT` (new constant = 10, python `LXMRouter.py:32`) until
DELIVERED or `fail_message`. It is divergence-REDUCING (the prior dequeue-at-`.sent`
was the divergence). The explicit per-send `.sent` DB write is dropped — the
cycle-end `persistPendingState()` covers durability now that the message stays
queued.

  - **Why it was a bug:** advancement to `.delivered` depended ENTIRELY on the
    in-memory proof callback (`ReticulumTransport.pendingProofCallbacks`, not
    persisted). A single lost packet/proof — or, under Model B, the iOS NE being
    suspended/jetsammed during the proof window — stranded the message at one
    checkmark forever (user-reported: "sent messages don't always process the
    delivery proof").

  - **Swift-specific reload — Category (a), no python analog:**
    `loadPendingOutbound()` (`LXMFDatabase.swift`) now also reloads
    `state == .sent && method == .opportunistic`, not just `.outbound`. Python
    never reloads `pending_outbound` from disk (its process is long-lived,
    `LXMRouter.py:99`); the swift port MUST, because the NE is jetsammed
    mid-flight. The filter is SCOPED to `.opportunistic`: `.sent` is terminal for
    PROPAGATED (python removes it at `LXMRouter.py:2544` — no recipient proof is
    expected), so reloading propagated `.sent` would wrongly re-upload it every
    launch. DIRECT small-packet `.sent` is now ALSO reloaded (see the DIRECT
    sub-deviation below); a DIRECT RESOURCE transfer is persisted at `.outbound`
    (not `.sent`), so it is caught by the first clause and never double-handled.

  - **Duplicate-resend safety:** re-sending is inherent to python's design and is
    deduped recipient-side by the stable `message.hash` transient id
    (`LXMRouter.swift` `deliveredTransientIDs`, persisted via `recordDelivered`),
    so the recipient shows exactly one row. Because the recipient's delivery
    destination is PROVE_ALL, a duplicate resend still earns a proof, which is what
    clears a stuck single-check (a mere callback re-registration could not — the
    original packet's hash isn't persisted and re-encryption changes it).

**Sub-deviation (DIRECT small-packet keep-in-queue + proof-wait-timeout retry, 2026-06-19):**
DIRECT small-packet now uses the SAME poll-based keep-in-queue model as opportunistic,
rather than dequeuing at `.sent`. `processOutbound`'s `.direct` case keeps the message in
`pendingOutbound` at `.sent` with `nextDeliveryAttempt = now + DELIVERY_RETRY_WAIT` and a
full-record `saveMessage`; `loadPendingOutbound` reloads DIRECT `.sent`; `handleDeliveryProofReceived`
already flips the in-memory entry to `.delivered` (shared with opportunistic). On a pass where
the message is still `.sent` and the proof-wait window elapsed (`shouldAttemptDelivery` true),
the top of the `.direct` case tears down the delivery link (`closeAndRemoveDeliveryLink` →
`Link.close(.timeout)` + `transport.unregisterLink`), reverts `.sent`→`.outbound`, and re-sends
over a FRESH link in the same pass. This mirrors python's `__link_packet_timed_out`
(`destination.teardown()` + `state = OUTBOUND`, LXMessage.py:613-618) and `process_outbound`'s
link-CLOSED branch popping `direct_links` + re-establishing on the `DELIVERY_RETRY_WAIT` cadence
(LXMRouter.py:2628-2670). While awaiting the proof on a live link the message is SKIPPED by
`shouldAttemptDelivery`, so no duplicate goes out during the wait — matching python's "waiting for
proof" no-resend (LXMRouter.py:2618-2627). Removed only by the `.delivered` check or
`MAX_DELIVERY_ATTEMPTS` (`fail_message` parity).

**Two intentional divergences — Category (a):**
  1. reticulum-swift has NO `set_timeout_callback` primitive (python `PacketReceipt`,
     Packet.py:595-599): neither `pendingProofCallbacks` nor `receipts` fires on timeout — both
     expire silently. So the proof-wait timeout is detected by the LXMF `processOutbound` POLL,
     not by a transport callback. Faithful because python's DIRECT re-send is itself poll-driven
     by `process_outbound`, and RNS never retransmits link DATA at the packet layer (confirmed:
     no packet RETRIES in Packet.py/Link.py) — the transport callback would add no observable
     benefit and, being non-persisted, would not survive an NE jetsam anyway.
  2. python's receipt timeout is `max(rtt*6, ...)` (sub-second); the swift port collapses it into
     the single `DELIVERY_RETRY_WAIT` (10s) gate. Observably equivalent because `rtt*6 << 10s`, so
     the wire-visible inter-send interval (~10s) and total send count (~`MAX_DELIVERY_ATTEMPTS`)
     are preserved; keeping the link alive during the proof-wait is divergence-REDUCING (a late
     proof still lands on the existing link and clears the message).

Two swift-runtime concurrency accommodations guard against an actor-yield race that python
has no analog for (python mutates the queued `LXMessage` in place on a single-threaded
`process_outbound`; the swift actor releases its executor at every `await`, letting a queued
`handleDeliveryProofReceived` interleave):
  1. After the `inout` `sendDirect`/`sendOpportunistic` copy-out, the `pendingOutbound[i] = msg`
     write-back is GUARDED on `state != .delivered`, so a proof that landed during the send
     `await` (flipping the entry to `.delivered`) is not clobbered back to `.sent`.
  2. The DIRECT timeout-revert RE-CHECKS `state == .sent` AFTER `closeAndRemoveDeliveryLink`
     (which awaits link teardown), before reverting `.sent`→`.outbound`. Without the re-check,
     a proof flipping the entry to `.delivered` during the teardown awaits would be clobbered
     back to `.outbound`, re-entering the retry loop until `MAX_DELIVERY_ATTEMPTS` (caught by
     greptile on PR #9).

**Re-sync note:** two follow-ups remain for stricter parity (LXMF-swift issue #10): (a) an
optional shorter `max(link.rtt*6, floor)` gate for faster dead-link detection (accepting more link
churn), and (b) wiring `Link.setCloseCallback` so an UNEXPECTED early link close reverts
`.sent`→`.outbound` immediately instead of after the `DELIVERY_RETRY_WAIT` window (python's CLOSED
branch acts immediately, LXMRouter.py:2628-2647).

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

### `saveDeliveredTransientIDs` — off-actor serial write (concurrency adaptation)

**Site:** `Sources/LXMFSwift/Router/LXMRouter.swift` — `saveDeliveredTransientIDs`
(`localDeliveriesWriteQueue` serial queue + snapshot dispatch).

**Python reference:** `LXMF/LXMRouter.py:1177-1184`
(`save_locally_delivered_transient_ids`) — synchronously `msgpack.packb`s the whole
`locally_delivered_transient_ids` dict and `write()`s it inline on the calling thread.

**Cadence (faithful, NOT a deviation):** python adds to `locally_delivered_transient_ids`
**in-memory** on each delivery (`:1806`) and persists it only from the periodic
maintenance loop (`:1365`), after a propagation sync (`:1588`), and on exit
(`exit_handler`) — never per delivery. The swift port matches that: `recordDelivered`
adds in-memory + sets `deliveredCacheDirty`; the persist runs from the periodic
`processOutbound` maintenance tick (`persistDeliveredTransientIDsIfDirty`) and from
`notifySyncCompletion` (post-sync). This is what keeps a per-message DB-save failure
from durably blacklisting a hash — the in-memory entry is lost on restart, exactly as
in python.

**The actual deviation — Category (a):** `LXMRouter` is an `actor`, and python's inline
synchronous serialize+atomic-write would hold the actor's serial executor (its mailbox)
for the full I/O. So `saveDeliveredTransientIDs` snapshots the dict **on the actor**,
then serializes + writes it on a dedicated **serial** `DispatchQueue`
(`localDeliveriesWriteQueue`). The serial queue preserves submission order so the
most-recent snapshot wins the atomic write (a plain `Task.detached` per call would race
the global executor and could persist a stale snapshot). Only *where* the bytes are
written moves off the actor; the file format (msgpack `{transient_id(bin):
timestamp(float)}`) and load path are byte-compatible with python.

`flushPendingLocalDeliveries()` is a barrier on that serial queue for points where
durability must be guaranteed synchronously (a graceful shutdown, or a test asserting
the on-disk state); a real process restart drains the queue the same way. Python's
inline write needs no such barrier because it is already synchronous.

**Sub-deviation (dedup rollback on failed store — Category (b) robustness, 2026-06-20):**
`lxmfDelivery` calls `recordDelivered(message.hash)` BEFORE `database.saveMessage` (faithful
to python `LXMRouter.py:1802-1806`, which sets `locally_delivered_transient_ids[hash]` before
the delivery callback, so a concurrent duplicate arriving while the store is in flight is still
rejected). But if the swift `saveMessage` THROWS, the message was never persisted; python leaves
the dedup entry in place (a failed store there also blacklists the hash until the unpersisted
in-memory entry is lost on restart). The swift port instead ROLLS BACK — `deliveredTransientIDs.removeValue(forKey:)`
+ re-mark dirty + `return false` (no delegate fire) — so the sender's retry can still be accepted
and the message isn't permanently lost. Strictly more robust than python; flagged by greptile on PR #9.

**Sub-deviation (`shutdown()` flushes the dedup cache — python-parity, 2026-06-20):**
`shutdown()` is now `async` and calls `persistDeliveredTransientIDsIfDirty()` +
`await flushPendingLocalDeliveries()` before teardown, so deliveries recorded since the last
periodic flush reach disk on a graceful stop. Mirrors python's `exit_handler` calling
`save_locally_delivered_transient_ids()` (LXMRouter.py:1365). Making `shutdown()` async is
transparent — every caller already `await`s it (it's an actor method). Flagged by greptile on PR #9.

## Resolved deviations

(none yet — this file was created during the iOS smoke-pipeline
work on 2026-05-10 to document the Stamper perf rewrite. Future
re-syncs should append entries here when introducing language-driven
or perf-driven divergences.)
