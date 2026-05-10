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

## Resolved deviations

(none yet — this file was created during the iOS smoke-pipeline
work on 2026-05-10 to document the Stamper perf rewrite. Future
re-syncs should append entries here when introducing language-driven
or perf-driven divergences.)
