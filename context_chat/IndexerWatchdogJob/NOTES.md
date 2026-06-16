# IndexerWatchdogJob — deployment & upstream notes

## What it does
A `TimedJob` declared in `appinfo/info.xml <background-jobs>` that continuously self-heals
context_chat's file indexing. Each tick (1h) it reads `oc_context_chat_queue` and, for every
queued `(storageId, rootId)` tuple that has **no live IndexerJob consumer**, it creates that
IndexerJob directly — the exact operation the buggy `QueueService::insertIntoQueue()` skips
(it early-returns at `existsQueueItem()` *before* `scheduleJob()`, the only IndexerJob creator).
Gated by: `app_api` enabled, `auto_indexing != 'false'`, `last_indexed_time == 0`. It is inert
during a healthy crawl and quiesces once the queue drains / the flag latches.
Shipped together with a root-cause fix: `insertIntoQueue()` now calls `scheduleJob()`
**unconditionally** (idempotent), so a freshly-crawled tuple can't re-orphan.

## Root cause it heals
The chain `SchedulerJob → StorageCrawlJob → IndexerJob` is one-shot and self-removing. Once it
self-deletes (after the initial crawl, or on an app upgrade that doesn't re-seed it), nothing
re-creates the IndexerJob consumer for rows already in the queue → the queue never drains and
`last_indexed_time` stays 0 → the "initial indexing is still running" banner shows forever.

## Status
Deployed live on the host (context_chat **v5.3.1**), oc_jobs row bootstrapped. **Verified autonomous:**
cron ran the watchdog on its own → it revived **397 IndexerJobs** → the 24 596-row backlog began
draining (24570→24306 in 2 min); IndexerJobs self-remove as their tuple empties.

## Upstream PR status — NOT upstream-able as-is
- Upstream `nextcloud/context_chat` has **no `stable5.3` maintenance branch** — only `main`.
- `main` (→ **5.4.0**) **rearchitected indexing**: the PHP `IndexerJob` + schedule-on-insert were
  removed; the completion latch moved into the Python backend (`QueueController`, backend-pull).
  So this watchdog **fixes a bug that 5.4.0 structurally eliminated** — it is moot on `main`.
- ⇒ This is a **local 5.3.x stopgap** carried on the host until the deployment upgrades to 5.4.0.
  It is **excluded** from the comprehensive upstream contribution. The upstream-PR candidates are
  the *other* context_chat patches (the Python backend freeze/log fixes → `context_chat_backend`;
  the SMB-seek `CachingStream` fix → `context_chat`), to be evaluated against their current `main`.

## ⚠️ Persistence caveat (local patch)
The watchdog **survives NC-core `occ upgrade`** (NC re-reads the live `info.xml <background-jobs>`
and idempotently re-adds the job) and runs forever via cron. BUT, being a **local edit to a
store-managed app**, it is **lost when the context_chat *app* itself is updated** (the app dir,
incl. `info.xml` and `IndexerWatchdogJob.php`, is replaced by the store version) — the same caveat
as every other live context_chat patch. ⇒ Re-apply after any context_chat app update (until the
5.4.0 upgrade makes it obsolete).

## Re-apply runbook (after a context_chat app update, on the host, while still on 5.3.x)
1. Deploy files via docker-root (www-data 33:33):
   - `lib/BackgroundJobs/IndexerWatchdogJob.php` (new)
   - re-apply: `lib/Db/QueueMapper.php` (`getQueuedStorageRootTuples()`), `lib/Service/QueueService.php`
     (unconditional `scheduleJob()`), `appinfo/info.xml` (watchdog in `<background-jobs>`).
2. Seed the oc_jobs row (NC `id` is not auto-increment): mirror RotateLogsJob —
   `INSERT INTO oc_jobs (...) SELECT MAX(id)+1, REPLACE(class,'RotateLogsJob','IndexerWatchdogJob'),
   argument, argument_hash, 0, UNIX_TIMESTAMP(), 0, -1, 0 FROM oc_jobs WHERE class LIKE '%RotateLogsJob' LIMIT 1;`
3. Verify: next cron → IndexerJobs revived → queue drains → `last_indexed_time` latches.

Source files: see this directory (`lib/`, `tests/`, `info.xml.diff`).

## Upstream issue (the SchedulerJob re-seed question on main)
https://github.com/nextcloud/context_chat/issues/244 (opened 2026-06-11, issue-first; awaiting maintainer triage before any PR).
