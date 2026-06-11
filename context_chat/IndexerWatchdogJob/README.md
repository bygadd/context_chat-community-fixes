# Patch: IndexerWatchdogJob — indexing-chain self-heal

## Problem

The context_chat indexing chain (SchedulerJob → StorageCrawlJob → IndexerJob) is
one-shot and self-removing by design. The sole creator of IndexerJob entries is
`QueueService::scheduleJob()`, which is only reached from `insertIntoQueue()` — but
`insertIntoQueue()` early-returns at `existsQueueItem()` before calling `scheduleJob()`.
This means files already in `oc_context_chat_queue` can be left with no IndexerJob
consumer: `last_indexed_time` never latches, and the "initial indexing still running"
banner persists indefinitely.

## Root cause

Two compounding faults:

1. **`QueueService::insertIntoQueue()` short-circuit bug** — the early-return on
   `existsQueueItem()` also skips `scheduleJob()`, so duplicate-file paths never re-seed
   the consumer.

2. **No persistent watchdog** — once an IndexerJob self-removes from `oc_jobs`, nothing
   re-creates it for existing queue rows. The chain is permanently stalled.

## Fix

### `lib/Service/QueueService.php` — `insertIntoQueue()` (short-circuit fix)

Move `scheduleJob()` out of the `existsQueueItem` guard. The INSERT is still skipped on
duplicates; `scheduleJob()` now runs unconditionally. `scheduleJob()` is already
idempotent — it wraps `jobList->has()` before `add()`.

See `lib/Service/QueueService.insertIntoQueue.diff`.

### `lib/BackgroundJobs/IndexerWatchdogJob.php` (new persistent TimedJob)

A 1-hour timed background job that:

- Fires only when `app_api` is enabled, `auto_indexing` is not `'false'`, and
  `last_indexed_time` is still `0` (i.e., initial indexing is not yet complete).
- Calls `QueueMapper::getQueuedStorageRootTuples()` to find distinct `(storage_id,
  root_id)` pairs that have rows in the queue.
- For each tuple, calls `jobList->has(IndexerJob::class, $arg)` and, if absent, adds a
  new IndexerJob. The arg key order (`storageId` first, then `rootId`) matches IndexerJob
  exactly — this is load-bearing because `jobList->has()` hashes `json_encode($arg)` and
  PHP preserves insertion order.

Registered in `appinfo/info.xml` `<background-jobs>` so Nextcloud re-adds it on every
upgrade and never removes it.

### `lib/Db/QueueMapper.php` — new `getQueuedStorageRootTuples()` method

A `SELECT DISTINCT storage_id, root_id FROM oc_context_chat_queue` query returning a
typed list of tuples. See `lib/Db/QueueMapper.partial.php`.

### `appinfo/info.xml` changes

- Add `<job>OCA\ContextChat\BackgroundJobs\IndexerWatchdogJob</job>` to
  `<background-jobs>`.
- Remove the `<post-migration>` block (the earlier, rejected `EnsureIndexingJobsStep`
  approach) so `<repair-steps>` has only `<install>`.

See `info.xml.diff`.

## Tests

`tests/IndexerWatchdogJobTest.php` — 5 PHPUnit cases:

| Test | What it verifies |
|---|---|
| `testRevivesMissingConsumers` | Happy path: orphaned tuple → `add()` called once, arg key order asserted |
| `testIdempotentWhenConsumerAlive` | `has()=true` → `add()` never called |
| `testSilentWhenAppApiDisabled` | `isEnabledForAnyone=false` → no queue read, no add |
| `testSilentWhenAlreadyLatched` | `last_indexed_time != 0` → no queue read, no add |
| `testSilentWhenQueueEmpty` | `tuples=[]` → no add |

## Files in this patch dir

```
lib/BackgroundJobs/IndexerWatchdogJob.php   — new TimedJob (full file)
lib/Db/QueueMapper.partial.php              — new method only (reference)
lib/Service/QueueService.insertIntoQueue.diff — short-circuit fix
tests/IndexerWatchdogJobTest.php            — PHPUnit test (full file)
info.xml.diff                               — background-jobs add + post-migration removal
```
