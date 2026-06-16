# Draft reply — nextcloud/context_chat#244

> Status: DRAFT — pending Yoan's review/OK before posting (outward-facing + AI-disclosure).
> `<REPO_LINK>` to be filled once the repo is made public/genericized.

---

Thanks @kyteinsky — that clears up the design intent (re-enable deliberately not re-seeding the queue, so the indexer doesn't re-walk the whole list), and #227's re-queueing work looks like it covers the live-discovery side.

I went back and read the listener wiring to answer your question precisely. `CacheEntryInsertedEvent` **is** registered → `FileListener` (`lib/AppInfo/Application.php`), so a newly-mounted external storage that then gets scanned (`occ files:scan` / first web-UI visit) inserts `oc_filecache` rows, fires the event, and **does** get queued. So that sub-case is handled — thanks, that corrects my original assumption.

The gap that remains — and what the title feature is really for — is **files that are already in `oc_filecache`** before context_chat enumerates them: no insert event fires for those, so they rely solely on the one-shot `<install>` `StorageCrawlJob` seed. Concretely:

- **context_chat installed on an existing instance** (files already cached) → the only full enumeration is the install-time crawl.
- **Interrupted/incomplete initial crawl, then `occ upgrade`** → the seed is `<install>`, not `<post-migration>`, so there's no path to resume a full enumeration; event capture only covers files touched from then on.

So the request reduces to an **idempotent, on-demand full re-enumeration** — a CLI command and/or a `<post-migration>` re-seed of `SchedulerJob` — so operators can recover index completeness without an app reinstall. If #227 already exposes that, great; happy to test against it.

---

Separately: while stabilising context_chat on a production NC 33.0.5 (app 5.3.1 / backend) we diagnosed and fixed several backend/indexing issues that may be useful upstream:

- **multipart-CR indexing freeze** — `loadSources` rejected with `Did not find LF character at end of header (found 13)` after a provider change (CR/LF mangling); CR-tolerant multipart parsing.
- **`exec_in_proc` fork-deadlock** — parent `cconn` left open → `recv()` hangs on a child that dies without a result (no join-timeout).
- **recv-leak / orphaned `_indexing` lock** — the leak left the lock held → persistent 503 "already being processed"; fixed with a lease + poll.
- **child-log relay** — forkserver children lost their logging config; relayed embed logs to a backend log.
- **SMB non-seekable stream** — `IndexerJob` `fopen('rb')` on SMB external storage yields a non-seekable stream that reports `isSeekable()=true` → multipart send fails; wrapped unconditionally in `CachingStream` in `LangRopeService`.
- **HNSW selective-context 0 results** — for a user holding only a small fraction of the collection, once `id IN (...)` exceeds ~5.5k Postgres flips to an HNSW index scan that takes the global-nearest then post-filters by id → 0 documents; reworked the pgvector query.

Patches + per-issue write-ups are consolidated here: **<REPO_LINK>**. Happy to split any of them into focused PRs if useful.

*(Disclosure: this investigation and write-up were done with AI assistance; every fix above was diagnosed against the source and verified on our live deployment.)*
