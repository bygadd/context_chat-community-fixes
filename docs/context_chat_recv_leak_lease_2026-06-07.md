# Context Chat backend freeze #3 — `exec_in_proc` recv-leak orphans the `_indexing` lock (fix: `cconn.close()`+poll + `_indexing` lock-lease)

## Summary
After the fork-deadlock fix (`forkserver` + `join(timeout=900)`), a **residual** permanent freeze remained: ~20 mail sources stuck in the process-global `_indexing` map (unchanging), `PUT /loadSources` returning `503 "... already being processed"` indefinitely, **no embedding child alive**, only a restart clearing it. Root cause: `exec_in_proc` (`context_chat_backend/utils.py`) passes the worker pipe's write-end (`cconn`) to the child but the **parent never closes its own copy** after `p.start()`. If the child dies WITHOUT sending a result (OOM-kill/segfault, or `exception_wrap`'s `resconn.send(...)` raises on a **non-picklable exception**), `pconn.recv()` blocks **forever** (pipe not at EOF — parent still holds a write-end) → the request thread never reaches its `finally` → the per-source `_indexing` lock + the `doc_parse_semaphore` slot leak permanently → the whole pipeline freezes. The existing `join(timeout)` only covers an ALIVE, hung child — not a DEAD child that never sent.

## Environment
- `context_chat_backend` 5.3.0, Python 3.11, NC33 host `the host`, Docker `nc_app_context_chat_backend` (network=host, uvicorn 127.0.0.1:23004), forkserver workers. Embedding via remote IONOS bge-m3.

## Root cause (proven by a reproduction test, not inferred)
A standalone test ran `exec_in_proc(target=os._exit-without-send)` against the **unpatched** code: it **HUNG >30s** (watchdog) → the recv-leak reproduced. Same test on normal/error targets passed (return value + picklable-exception propagation both work). So the leak is the dead-child-without-result `recv()` hang, confirmed.

## Fix (two composable components; `# CCB-PATCH-recv` / `# CCB-PATCH-lease`)

### Component 1 — `utils.py` `exec_in_proc` (closes the exact leak)
```python
p.start()
cconn.close()  # CCB-PATCH-recv: parent drops its copy of the child's write-end so
# pconn.recv() raises EOFError instead of hanging forever if the child dies without sending
p.join(timeout=900)  # CCB-PATCH-join
if p.is_alive():
    p.kill(); p.join(10); raise TimeoutError('exec_in_proc worker timed out / deadlocked; killed')
if not pconn.poll(10):  # CCB-PATCH-recv: dead child that never sent a result must not hang recv()
    raise RuntimeError('CCB-PATCH: exec_in_proc worker exited without sending a result (crash/OOM/unpicklable error?)')
try:
    result = pconn.recv()
except EOFError as e:  # CCB-PATCH-recv
    raise RuntimeError('CCB-PATCH: exec_in_proc worker pipe closed before sending a result') from e
```
`cconn.close()` is the real fix (dead child → EOF → raise, not hang); `poll(10)`+EOFError is the explicit defensive bound. Any raise propagates to the `/loadSources` handler `except Exception → DbException`, whose `finally` releases the `_indexing` lock + semaphore. The lock is **always** released.

### Component 2 — `_indexing` lock-lease (robust catch-all; covers any other missed-`finally` path)
Helpers added in `utils.py` (no heavy import side-effects → unit-testable):
```python
from time import monotonic, perf_counter_ns
INDEXING_LEASE_TTL = 1200  # > the 900s worker timeout (+ margin); older = orphan -> reclaim
def lease_is_stale(entry, now, ttl=INDEXING_LEASE_TTL) -> bool: ...   # entry = (size, acquired_monotonic)
def reclaim_stale_indexing(indexing, lock, now, ttl=INDEXING_LEASE_TTL) -> list: ...  # pops stale under lock, returns reclaimed
```
`controller.py` wiring: import `monotonic` + the helpers; store a timestamped lease `_indexing[fn] = (source.size, monotonic())`; lease-aware 503-check (`... and not lease_is_stale(...)` → stale entry falls through and the request reclaims it); and a sweep in the existing 10s `background_thread_task` (`reclaim_stale_indexing(...)` + a `CCB-PATCH: reclaimed N orphaned ... ` warning). So a single missed `finally` can freeze a source for at most `TTL`, never permanently — no restart.

## Tests (run in-container; standalone, no pytest)
`docker exec nc_app_context_chat_backend python3 /app/test_ccb_lease_recv.py` (file `/app/test_ccb_lease_recv.py`, helpers `context_chat_backend/_ccb_test_helpers.py`). Red→green proven: t3 (recv-leak) HUNG on unpatched → raises after Component 1; t1/t2 (lease) red until Component 2 → green; t4/t5 (normal return / picklable-exception) green throughout. **Final: 5/5 PASS.**

## Live verification (2026-06-07, after restart, NO further restart)
Before: last ccb.log lines were `PUT /loadSources 503` (frozen). After restart (fix loaded): clean boot (`Application startup complete`, bg thread alive, `_indexing` now stores `[size, monotonic]` tuples = Component 2 active, zero traceback). Over ~7 min: cycled through **380+ distinct mail sources**, 23+ `loadSources 200`, `_indexing` repeatedly back to **0** (no stuck), zero `Traceback`/`exited without`/`reclaimed`. The 503s present are normal backpressure (deep bge-m3 re-index backlog + slow remote embed; NC retries with `cc-retry`), not the freeze (which was 0-progress-forever).

## Re-apply runbook (⛔ ALL CCB live patches are LOST on `occ app_api:app:update` / redeploy — re-apply ALL THREE)
The three freeze patches live in the container's writable layer. After ANY backend redeploy, re-apply in order, then `rm` the matching `__pycache__/*.pyc`, then `docker restart nc_app_context_chat_backend`:
1. **multipart-CR** — `python_multipart/multipart.py` (Freeze 1 report).
2. **fork-deadlock** — `utils.py` forkserver + `join(900)`+kill (Freeze 2 report).
3. **recv-leak + lease (this report)** — `utils.py` (`cconn.close()`+poll/EOFError around `recv()`; `INDEXING_LEASE_TTL`+`lease_is_stale`+`reclaim_stale_indexing`; `monotonic` import) + `controller.py` (import helpers+`monotonic`; sweep in `background_thread_task`; lease-aware 503-check; `_indexing[fn]=(size, monotonic())`).
- **Backups (this fix):** `utils.py.ccb-bak-recv` (TRUE original, pre-any-patch this fix), `utils.py.ccb-bak-lease` (post-recv/pre-lease), `controller.py.ccb-bak-lease`. To fully revert THIS fix, restore the `.ccb-bak-recv`/`.ccb-bak-lease` originals; do NOT restore them as "the fix".
- **Post-re-apply check:** `python3 /app/test_ccb_lease_recv.py` → 5/5 PASS; then restart; then watch ccb.log for `Currently indexing` cycling + `loadSources 200` + no 503-only-storm. Forkserver children don't log to `docker logs`; monitor via ccb.log + the pgvector `docs` count.

##Work-ticket (context_chat umbrella). **Problem #678** (recv-leak root cause) + **** (this patch), both with requester Group "AI Team" #171 + assignee Yoan #8 + ITIL category (P→40 "Проблем > Софтуер", C→31 "Услуга > Инсталиране на софтуер"). Links: Problem↔ (856), Change↔ (14), Change↔Problem (7). Design/diagnostic Task (executor Yoan #8).

## Upstream
Both components are general (the missing `cconn.close()` + unbounded `recv()` is a real upstream bug; a lock-lease is a standard robustness pattern). File a PR to `nextcloud/context_chat_backend` after a confirmed stability window, alongside the multipart + fork-deadlock issues.
