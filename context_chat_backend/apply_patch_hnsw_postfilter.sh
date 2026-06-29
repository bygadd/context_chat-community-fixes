#!/usr/bin/env bash
# Patch 7b — HNSW post-filter for HUGE selective scopes (CCB-PATCH-hnsw-postfilter)
# Applies to: nc_app_context_chat_backend container (5.4.0+, pgvector >= 0.8.0)
# File: /app/context_chat_backend/vectordb/pgvector.py
# Re-apply after every: app_api:app:update context_chat_backend  (AFTER apply_patch_hnsw.sh)
#
# Problem: Selective Context over a HUGE scope (e.g. the whole files provider for a user with a
# large corpus) makes doc_search enumerate ALL the user's chunk_ids (observed ~2.46M). Patch 7's
# MATERIALIZED CTE then brute-forces distance over all of them -> O(n) -> exceeds the 60s
# statement_timeout -> psycopg QueryCanceled -> DbException "Error: performing doc search in
# vectordb" returned to Nextcloud. (Stock 5.4.0 batches 50k at a time -> ~50 brute-force queries
# ~5.6s each -> ~280s, no error but ~5 min hang.)
#
# Fix: above CTE_MAX_CHUNKS, switch to native HNSW (pgvector >= 0.8 `hnsw.iterative_scan`, the
# fix recommended in nextcloud/context_chat_backend#320) with NO id-filter in SQL — fetch the top
# HNSW_POSTFILTER_FETCH nearest (O(log n)), then keep only ids in the scope set (O(1) python
# membership). Safe for huge scopes: when the scope is a large fraction of the collection the
# global-nearest are overwhelmingly in-scope. Measured on the live 10.4M-chunk DB: HNSW top-200
# = 79ms, top-10000 = 757ms (vs CTE 2.46M = timeout).
#
# Dispatch after this patch (in _similarity_search):
#   n <= HNSW_ACTIVATION_THRESHOLD (5000)      -> ORM batch path        (small, exact)
#   5000 < n <= CTE_MAX_CHUNKS (50000)         -> _similarity_search_cte (medium, exact, btree CTE)
#   n  > CTE_MAX_CHUNKS                         -> _similarity_search_hnsw_postfilter (huge, native HNSW)

set -euo pipefail
CONTAINER=nc_app_context_chat_backend
TARGET=/app/context_chat_backend/vectordb/pgvector.py

echo "=== Patch 7b: HNSW post-filter for huge selective scopes ==="
docker exec "$CONTAINER" grep -n "HNSW_ACTIVATION_THRESHOLD\|CTE_STATEMENT_TIMEOUT_MS\|_similarity_search_cte" "$TARGET" | head -5

docker exec -i "$CONTAINER" python3 - <<'PYEOF'
path = '/app/context_chat_backend/vectordb/pgvector.py'
with open(path, 'r') as f:
    src = f.read()

if 'CCB-PATCH-hnsw-postfilter' in src:
    print('Already patched (7b) — skipping')
    raise SystemExit(0)

if 'HNSW_ACTIVATION_THRESHOLD' not in src:
    raise SystemExit('ERROR: Patch 7 (apply_patch_hnsw.sh) must be applied first')

# 1. New constants after CTE_STATEMENT_TIMEOUT_MS
old_const = 'CTE_STATEMENT_TIMEOUT_MS = 60000'
new_const = (
    'CTE_STATEMENT_TIMEOUT_MS = 60000\n'
    '# CCB-PATCH-hnsw-postfilter: above this many chunk_ids the CTE brute-force exceeds the\n'
    '# statement timeout (selective scope over a huge corpus, e.g. the whole files provider).\n'
    '# Switch to native HNSW (pgvector >=0.8 iterative_scan) + app-side id filter: O(log n).\n'
    'CTE_MAX_CHUNKS = 50000\n'
    'HNSW_POSTFILTER_FETCH = 20000\n'
    'HNSW_POSTFILTER_MAX_SCAN = 40000'
)
if old_const not in src:
    raise SystemExit('ERROR: constants anchor not found')
src = src.replace(old_const, new_const, 1)

# 2. New method, inserted right before the existing _similarity_search (alongside the CTE method)
method = (
    '\t# CCB-PATCH-hnsw-postfilter (Patch 7b)\n'
    '\tdef _similarity_search_hnsw_postfilter(\n'
    '\t\tself,\n'
    '\t\tsession: orm.Session,\n'
    '\t\tcollection_uuid,\n'
    '\t\tembedding: list[float],\n'
    '\t\tchunk_ids: list[str],\n'
    '\t\tk: int,\n'
    '\t) -> list[Document]:\n'
    '\t\t"""Huge selective scope: the CTE brute-force is O(n) and exceeds statement_timeout.\n'
    '\n'
    '\t\tRun a native HNSW nearest-neighbour scan (pgvector >=0.8 iterative_scan, NO id-filter in\n'
    '\t\tSQL) for the top HNSW_POSTFILTER_FETCH candidates, then keep only those whose id is in the\n'
    '\t\tscope set (O(1) python membership) and return the k nearest. Fast (HNSW is O(log n)); safe\n'
    '\t\tfor huge scopes because the global-nearest are overwhelmingly in-scope when the scope is a\n'
    '\t\tlarge fraction of the collection (which is exactly when n > CTE_MAX_CHUNKS).\n'
    '\n'
    '\t\tSET LOCAL (transaction-scoped, no pool leak):\n'
    '\t\t- hnsw.iterative_scan=relaxed_order: keep scanning past the first ef_search batch so enough\n'
    '\t\t  candidates survive the post-filter.\n'
    '\t\t- hnsw.max_scan_tuples: cap worst-case scan work.\n'
    '\t\t- max_parallel_workers_per_gather=0: /dev/shm=64MB on this host -> a parallel plan DiskFulls.\n'
    '\t\t"""\n'
    '\t\tchunk_set = set(chunk_ids)\n'
    "\t\temb_literal = '[' + ','.join(str(x) for x in embedding) + ']'\n"
    '\t\top = self._distance_op()  # one of a fixed set, safe to interpolate\n'
    "\t\tsession.execute(sa.text('SET LOCAL hnsw.iterative_scan = relaxed_order'))\n"
    "\t\tsession.execute(sa.text(f'SET LOCAL hnsw.max_scan_tuples = {int(HNSW_POSTFILTER_MAX_SCAN)}'))\n"
    "\t\tsession.execute(sa.text('SET LOCAL max_parallel_workers_per_gather = 0'))\n"
    "\t\tsession.execute(sa.text(f'SET LOCAL statement_timeout = {int(CTE_STATEMENT_TIMEOUT_MS)}'))\n"
    '\t\tresult = session.execute(\n'
    '\t\t\tsa.text(f"""\n'
    '\t\t\t\tSELECT id, document, cmetadata,\n'
    '\t\t\t\t\t   embedding {op} cast(:query_vec AS vector) AS distance\n'
    '\t\t\t\tFROM langchain_pg_embedding\n'
    '\t\t\t\tWHERE collection_id = :coll_uuid\n'
    '\t\t\t\tORDER BY distance\n'
    '\t\t\t\tLIMIT :n\n'
    '\t\t\t"""),\n'
    '\t\t\t{\n'
    "\t\t\t\t'coll_uuid': str(collection_uuid),\n"
    "\t\t\t\t'query_vec': emb_literal,\n"
    "\t\t\t\t'n': int(HNSW_POSTFILTER_FETCH),\n"
    '\t\t\t},\n'
    '\t\t)\n'
    '\t\tmatched = [\n'
    '\t\t\t(row.distance, row.id, row.document, row.cmetadata)\n'
    '\t\t\tfor row in result\n'
    '\t\t\tif str(row.id) in chunk_set\n'
    '\t\t]\n'
    '\t\tmatched.sort(key=lambda r: r[0])\n'
    '\t\treturn [\n'
    '\t\t\tDocument(\n'
    '\t\t\t\tid=str(r[1]),\n'
    '\t\t\t\tpage_content=r[2],\n'
    '\t\t\t\tmetadata=r[3],\n'
    '\t\t\t)\n'
    '\t\t\tfor r in matched[:k]\n'
    '\t\t]\n'
    '\n'
)
anchor = '\t# modified from langchain_postgres.vectorstores\n\tdef _similarity_search('
if anchor not in src:
    raise SystemExit('ERROR: _similarity_search anchor not found')
src = src.replace(anchor, method + anchor, 1)

# 3. Dispatch: add the huge-scope branch before the CTE branch
old_disp = (
    '\t\tif len(chunk_ids) > HNSW_ACTIVATION_THRESHOLD:\n'
    '\t\t\treturn self._similarity_search_cte(\n'
    '\t\t\t\tsession, collection.uuid, embedding, chunk_ids, k\n'
    '\t\t\t)'
)
new_disp = (
    '\t\t# CCB-PATCH-hnsw-postfilter: huge scope (e.g. whole files provider) — CTE would time out.\n'
    '\t\tif len(chunk_ids) > CTE_MAX_CHUNKS:\n'
    '\t\t\treturn self._similarity_search_hnsw_postfilter(\n'
    '\t\t\t\tsession, collection.uuid, embedding, chunk_ids, k\n'
    '\t\t\t)\n'
    '\t\tif len(chunk_ids) > HNSW_ACTIVATION_THRESHOLD:\n'
    '\t\t\treturn self._similarity_search_cte(\n'
    '\t\t\t\tsession, collection.uuid, embedding, chunk_ids, k\n'
    '\t\t\t)'
)
if old_disp not in src:
    raise SystemExit('ERROR: dispatch anchor not found')
src = src.replace(old_disp, new_disp, 1)

with open(path, 'w') as f:
    f.write(src)
print('Patch 7b written OK')
PYEOF

echo "=== Syntax check ==="
docker exec "$CONTAINER" python3 -c "import ast; ast.parse(open('$TARGET').read()); print('AST OK')"
echo "=== Verifying markers ==="
docker exec "$CONTAINER" grep -n "CCB-PATCH-hnsw-postfilter\|CTE_MAX_CHUNKS\|_similarity_search_hnsw_postfilter" "$TARGET"
echo "=== Restart to activate: docker restart $CONTAINER ==="
