# context_chat — indexing-job chain doesn't survive upgrades (self-heal)

**App:** context_chat **v5.3.1** (Nextcloud 33.0.5)

I hit a state where the admin banner "initial indexing is still running" (and the
Assistant's "has not finished indexing") stuck forever, the file queue never drained, and
`last_indexed_time` stayed `0` — even though the initial crawl had completed earlier.

## Root cause (read against the v5.3.1 source)

The indexing chain is one-shot and self-removing, and nothing re-creates it after an upgrade:

1. `appinfo/info.xml` `<background-jobs>` declares only `FileSystemListenerJob`, `ActionJob`,
   `RotateLogsJob`. Core re-seeds *those* idempotently on every `app:update`.
2. The crawl chain is **not** in `info.xml`. It is seeded only at runtime:
   - `AppInstallStep` (a repair step, **`<install>`-only** — it does **not** run on `occ upgrade`)
     adds `SchedulerJob` (the add is unguarded).
   - `SchedulerJob` (one-shot `QueuedJob`): resets `last_indexed_time`/`indexed_files_count`,
     fans out one `StorageCrawlJob` per mount, then `remove(self)` — deletes itself.
   - `StorageCrawlJob` (one-shot): enqueues files via `QueueService::insertIntoQueue`;
     re-schedules itself only while a mount still has new files, then deletes itself.
   - `IndexerJob` (`TimedJob`, the **only** writer of `last_indexed_time` via
     `setInitialIndexCompletion()`): created **only** as a side effect of
     `QueueService::scheduleJob`, which runs **only** when a *new* row is inserted into the queue.
3. `Application::boot()` is empty — there is no idempotent bootstrap-level re-seed.
4. **The trap:** `QueueService::insertIntoQueue()` early-returns on `existsQueueItem($file)`
   **before** calling `scheduleJob()`. So when the queue already has rows, no new `IndexerJob`
   is ever spawned.

Net effect: the first crawl completed under an earlier version, so `SchedulerJob`/`StorageCrawlJob`
had already self-deleted. The upgrade didn't touch `oc_jobs` and there is no `<post-migration>`
step, so nothing re-seeds the chain. The queue is left without a consumer and
`last_indexed_time` never advances → the banners hang permanently.

## Fix (shipped: `IndexerWatchdogJob`)

context_chat is a normal PHP server app, so a job registered in `info.xml` `<background-jobs>`
is re-seeded by core on every upgrade. I added an `IndexerWatchdogJob` (`TimedJob`, hourly)
declared there, so it survives every `app:update` and self-heals without manual re-registration:

- it reads the queue directly and, for any orphaned `(storageId, rootId)` with no live
  consumer, revives the `IndexerJob` path;
- paired with an `insertIntoQueue()` fix so the early-return path still calls `scheduleJob()`,
  closing the trap above.

(An earlier design used a `<post-migration>` `IRepairStep` that re-adds `SchedulerJob` behind a
`has()`-guard — the sibling **Recognize** app hooks its `InstallDeps` under both `<install>` and
`<post-migration>` as precedent. I moved to the watchdog because it also recovers a queue that is
already populated, which a re-seed alone does not.)

Code: `../context_chat/IndexerWatchdogJob/`.

## Draining an already-stuck backlog

A re-seed/re-crawl does not drain rows already in the queue (the `existsQueueItem` early-return),
so I drain explicitly with `occ context_chat:scan <user>` (re-enqueue → spawns `IndexerJob`s),
then verify the queue falls to 0, `last_indexed_time > 0`, and the banners clear.

## Testing

- Remove `SchedulerJob`/the watchdog row from `oc_jobs`, run the repair/upgrade path → exactly one
  job is (re-)added; running it again does not duplicate (the `has()`-guard).
- Live: queue drains, the completion flag latches, banners clear, no duplicate jobs.

*Prepared with AI assistance; verified on a live deployment.*
