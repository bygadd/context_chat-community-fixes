# Context Chat backend — Selective Context returns 0 results (HNSW post-filter bug)

## Summary

When Selective Context is enabled (any provider — Mail or Files), every context_chat
task fails with `"No documents retrieved, please index a few documents first"` for users
who have more than ~5500 indexed chunks. Users with small corpora are unaffected.

## Environment

- `context_chat_backend` 5.3.0, Python 3.11, Nextcloud 33
- Docker `nc_app_context_chat_backend` (network=host, uvicorn 127.0.0.1:23004)
- PostgreSQL 17.5 + pgvector 0.8.0, HNSW index
- HNSW index on `langchain_pg_embedding.embedding vector(1024)` with `vector_cosine_ops`
- Total: ~7.9M embeddings (single collection, uuid `<uuid>`)
- **`/dev/shm` = 64MB**, **`work_mem` = 4MB** — both matter for the fix (see below)
- Largest user: **2.8M chunks** (`<user>`, ~35% of the whole collection)

## Root cause

`VectorDB._similarity_search` builds an ORM query:
```python
session.query(EmbeddingStore, distance).filter(
    EmbeddingStore.collection_id == uuid,
    EmbeddingStore.id.in_(batch_chunk_ids),
).order_by('distance').limit(k)
```
PostgreSQL has two possible plans for the `ORDER BY embedding <=> q`:

| Batch size | Plan                     | Result  |
|-----------|--------------------------|---------|
| ≤ 5500    | Sort (seq-scan over IN)  | correct |
| ≥ 5600    | HNSW Index Scan          | **0 rows** |

When the planner chooses the HNSW Index Scan it (1) uses the index to find the globally
nearest ~`ef_search` (≈40) vectors, then (2) **post-filters** by `id IN (...)`. For any
user whose chunk-ids are < ~2% of total DB rows, the 40 globally-nearest vectors
statistically contain 0 of that user's chunks → 0 results → `ContextException`.

Confirmed by `EXPLAIN` bisect on prod: 5500 items = `Sort` (works); 5600 =
`Index Scan using langchain_pg_embedding_embedding_hnsw` (fails). The multi-batch loop
(`PG_BATCH_SIZE=50000`) makes large users *probabilistic*: each 50k batch triggers HNSW,
so a user only gets results when some batch happens to contain HNSW-found global ids.

I initially dismissed `hnsw.ef_search` / `hnsw.iterative_scan` because `SHOW` reported them as
unknown — but pgvector only registers those GUCs once its shared library is loaded into the
session (after the first vector operation), so a fresh-session `SHOW` is misleading. They are in
fact available here (pgvector 0.8.0; see *Long-term*). I kept the application-level CTE as the
validated fix because it is exact and plan-fenced; the native GUC is the lighter alternative.

## Fix (`# CCB-PATCH-hnsw-selective`)

Add `HNSW_ACTIVATION_THRESHOLD = 5000` and `CTE_STATEMENT_TIMEOUT_MS = 60000`, plus a new
method `_similarity_search_cte`. In `_similarity_search`, **short-circuit before the batch
loop**: when `len(chunk_ids) > HNSW_ACTIVATION_THRESHOLD`, run the CTE path and return.

The CTE uses `WITH filtered AS MATERIALIZED (… WHERE id = ANY(:chunk_ids))` to force a
btree id pre-filter (Bitmap Heap Scan) **before** similarity is computed, so HNSW is never
chosen. `EXPLAIN` on prod shows `CTE filtered → Bitmap Heap Scan → Sort` — no HNSW, no
Gather node.

```python
HNSW_ACTIVATION_THRESHOLD = 5000
CTE_STATEMENT_TIMEOUT_MS = 60000

def _similarity_search_cte(self, session, collection_uuid, embedding, chunk_ids, k):
    emb_literal = '[' + ','.join(str(x) for x in embedding) + ']'
    op = self._distance_op()  # one of {'<=>','<->','<#>'} from a fixed dict — safe to interpolate
    session.execute(sa.text('SET LOCAL max_parallel_workers_per_gather = 0'))
    session.execute(sa.text(f'SET LOCAL statement_timeout = {int(CTE_STATEMENT_TIMEOUT_MS)}'))
    result = session.execute(sa.text(f"""
        WITH filtered AS MATERIALIZED (
            SELECT id, document, cmetadata, embedding
            FROM langchain_pg_embedding
            WHERE collection_id = :coll_uuid AND id = ANY(:chunk_ids)
        )
        SELECT id, document, cmetadata,
               embedding {op} cast(:query_vec AS vector) AS distance
        FROM filtered ORDER BY distance LIMIT :k
    """), {'coll_uuid': str(collection_uuid), 'chunk_ids': chunk_ids,
           'query_vec': emb_literal, 'k': k})
    return [Document(id=str(r.id), page_content=r.document, metadata=r.cmetadata) for r in result]
```

### Why MATERIALIZED

Without `MATERIALIZED`, PostgreSQL may inline the CTE (merge it with the outer
`ORDER BY embedding <=> …`) and re-choose HNSW. `AS MATERIALIZED` (PG 12+) forces the CTE
to execute as an independent fence, so the id-filter always runs first.

### Two deployment constraints handled via `SET LOCAL` — these are the non-obvious part

Both were discovered empirically while validating the fix on the largest (2.8M-chunk) user;
the initial naive CTE *crashed in production conditions*. Do not drop these.

1. **`SET LOCAL max_parallel_workers_per_gather = 0` — avoids a `/dev/shm` DiskFull crash.**
   At ~300k+ materialized rows the planner chooses a **parallel** plan. Parallel workers
   allocate shared-memory segments in `/dev/shm`, which is only 64MB here → the query dies
   with `DiskFull: could not resize shared memory segment "/PostgreSQL.*" to … bytes:
   No space left on device` after ~1.6s. Forcing serial execution spills the sort to normal
   temp space instead. (Same 64MB-`/dev/shm` constraint that forces serial HNSW index builds
   on this host.)

2. **`SET LOCAL statement_timeout = 60000` — caps the inherent O(n) brute force.**
   The CTE computes an exact distance for every one of the user's chunks. Latency is linear
   (~9µs/chunk, measured serial on prod):

   | chunks | latency |
   |-------:|--------:|
   | 10k    | 0.14s   |
   | 100k   | 1.3s    |
   | 600k   | 5.0s    |
   | 1M     | 8.8s    |
   | 2.8M   | ~21–26s |

   Correct but slow for huge users. The 60s cap prevents a pathological corpus from pinning
   a forkserver worker; it fires well before the upstream `request_timeout` (1800s) and
   surfaces as a clean `DbException`.

`SET LOCAL` is **transaction-scoped**: it applies only within the current ORM transaction
(SQLAlchemy 2.0 begins one on first execute; verified `SHOW` returns `0` inside the txn) and
is cleared by the `ROLLBACK` SQLAlchemy issues when the session returns the connection to the
pool — verified no leak onto the next pooled user. The CTE is the last statement in
`doc_search`'s transaction, so the 60s cap never touches unrelated queries.

### Distance operator is derived, not hardcoded

`_distance_op()` reads `self.client.distance_strategy.__name__` (the bound langchain
comparator: `cosine_distance` / `l2_distance` / `max_inner_product`) and maps it to the
pgvector operator (`<=>` / `<->` / `<#>`). This keeps the CTE consistent with the ORM path
even if `distance_strategy` is ever reconfigured. The deployment default is COSINE → `<=>`,
matching the `vector_cosine_ops` HNSW index. The fallback catches both `AttributeError` and
`ValueError` (the property raises `ValueError` for an unknown enum).

## Behavior changes (expected, not regressions)

- **5001–~5500 chunks:** previously used the ORM Sort path (worked); now use the CTE.
  Single-query semantics are identical to the ORM path (same `ORDER BY`, same `LIMIT`),
  so results don't change — only the plan. Verified equal top-20 on a 6000-id sample.
- **>50000 chunks:** the old multi-batch path took `LIMIT k` *per 50k batch* then merge-sorted
  in Python — it could **miss** true top-k items when more than `k` of them fell in one batch.
  The CTE computes a single global top-k over the whole filtered set, so it is **strictly more
  correct**. Output for the 487k/2.8M-chunk users will differ from pre-patch — this is the
  fix working, not a regression.

## Verification (read-only, on prod DB)

- HNSW index opclass = `vector_cosine_ops`; langchain default strategy = `COSINE` → `<=>`.
- `EXPLAIN` of CTE path: `Bitmap Heap Scan` (btree), no HNSW Index Scan, no Gather.
- CTE top-20 == plain `id = ANY` ORDER-BY-distance top-20 (ids + distances exact match).
- Largest user (2.8M chunks): `SET LOCAL` takes effect (`SHOW` = 0), CTE returns 20 rows in
  ~21s, no DiskFull. Without the parallelism guard: DiskFull at ~300k rows in ~1.6s.
- No pool leak: second session on the returned connection sees server-default GUCs.

## Files changed

`/app/context_chat_backend/vectordb/pgvector.py`:
- Add `HNSW_ACTIVATION_THRESHOLD = 5000`, `CTE_STATEMENT_TIMEOUT_MS = 60000` (after `PG_BATCH_SIZE`)
- Add class attr `_PGVECTOR_OP`, method `_distance_op`, method `_similarity_search_cte`
- Modify `_similarity_search` to short-circuit to the CTE before the batch loop

## Apply / re-apply

`context_chat_backend/apply_patch_hnsw.sh` — idempotent (guards on `HNSW_ACTIVATION_THRESHOLD`),
AST-checks after writing, hard-fails if the base file moved. Then `docker restart
nc_app_context_chat_backend`. **All live container patches are lost on
`app_api:app:update` — re-run the script after every app update.**

## Long-term

This deployment is already on pgvector 0.8.0, which ships **iterative index scans**
(`SET hnsw.iterative_scan = relaxed_order` — HNSW keeps scanning until enough rows pass the
id-filter); it is `off` by default here. That is the pgvector-native remedy for exactly this
filtered-KNN under-return and is worth enabling and measuring. I kept the CTE as the
application-level fix because it is exact and deterministic even for a very sparse user; the
two are complementary.
