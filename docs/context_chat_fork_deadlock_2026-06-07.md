# Context Chat backend: indexing permanently freezes — fork-deadlock in `exec_in_proc` (multithreaded fork) + `join()` without timeout

## Summary
`exec_in_proc` (`context_chat_backend/utils.py`) runs embedding in a child process started with the **default `fork`** start method, **from the multithreaded uvicorn process**. Forking a multithreaded process can copy a **locked mutex** into the child (the lock's owner thread does not exist in the child) → the child deadlocks in `futex_wait`. Because `Process.join()` is called **with no timeout**, the parent request then blocks **forever**, never releasing the per-source `_indexing` lock or the `doc_parse_semaphore` slot. This permanently freezes **all** indexing (503 "already being processed" storm; queues stop draining; semaphore slots exhausted as deadlocked children accumulate). Restarting the container only clears it until the next intermittent fork-deadlock — i.e. **not a stable fix**.

## Environment
- `context_chat_backend` 5.3.0, Python 3.11, Linux (where `fork` is the default start method before 3.14).
- Nextcloud 33, AppAPI/HaRP. Embedding via a remote OpenAI-compatible endpoint.

## Evidence
- Multiple child `main.py` processes stuck simultaneously, **all** `State=S, Threads=1, wchan=futex_wait_queue`, ages up to ~5h.
- The embedding HTTP call (`network_em.py`) already has a timeout (`niquests.post(timeout=request_timeout)`) + retries → the hang is **not** the network; the children are blocked on a **mutex** (an inherited lock).
- `/loadSources` returns `503 "... is already being processed in another request"` indefinitely for the affected sources; with all `doc_parse_semaphore` slots held by deadlocked children, the whole pipeline stops.
- `utils.py` `exec_in_proc`: `mp.Process(...)` (no start method set → `fork` on Linux) then `p.start(); p.join()` (no timeout).

## Root cause
1. **`fork()` of a multithreaded process is unsafe.** CPython docs: *"safely forking a multithreaded process can be problematic."* macOS made `spawn` the default in 3.8 for this reason, and **Python 3.14 changed the POSIX default from `fork` to `forkserver` "to maintain performance while avoiding common multithreaded process incompatibilities."** When a thread (logging lock, allocator arena, import lock, …) holds a lock at the instant of `fork`, the child inherits it **locked with no owner** → deadlock on first acquisition.
2. **`Process.join()` has no timeout.** A deadlocked (or otherwise hung) child blocks the parent forever → the `_indexing` lock and `doc_parse_semaphore` are never released → permanent, cascading freeze.

## Proposed fix
1. **Prevent** — use a non-`fork` start method for the embedding worker:
   `ctx = multiprocessing.get_context("forkserver"); p = ctx.Process(...)` (this is exactly the new 3.14 default). Requires picklable target+args: pass source payloads as `bytes`/temp-file paths and reconstruct heavy objects (the vector-DB loader) inside the child instead of inheriting them.
2. **Defense-in-depth (recover)** — bound the wait and reap hung children regardless of cause:
   ```python
   p.start()
   p.join(timeout=WORKER_TIMEOUT)
   if p.is_alive():
       logger.error("exec_in_proc worker %s exceeded %ss; killing (likely fork-deadlock)", p.pid, WORKER_TIMEOUT)
       p.kill(); p.join(10)
       raise EmbeddingException("embedding worker timed out / deadlocked; killed")
   result = pconn.recv()
   ```
   This guarantees the `_indexing` lock + semaphore are always released, so no single hung child can freeze the whole pipeline (covers fork-deadlock, hung embeds, OOM-killed children, etc.).

## Workaround (until fixed)
- Restarting the backend clears stuck children — **temporary** (recurs).
- The `join(timeout)`+`kill` change alone (defense-in-depth, no start-method refactor) turns the permanent freeze into a self-recovering, time-bounded blip.

_Filed after a production freeze; happy to submit the PR._
