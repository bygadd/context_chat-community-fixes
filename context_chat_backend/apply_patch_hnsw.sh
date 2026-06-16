#!/usr/bin/env bash
# Patch 7 — HNSW selective-context fix (CCB-PATCH-hnsw-selective)
# Applies to: nc_app_context_chat_backend container
# File: /app/context_chat_backend/vectordb/pgvector.py
# Re-apply after every: app_api:app:update context_chat_backend
#
# Fixes: Selective Context returns 0 documents for users with >~5500 chunks.
# Root cause: PostgreSQL flips the similarity ORDER BY to an HNSW Index Scan at ~5500
# IN-list items, then post-filters by id → 0 surviving candidates for users whose chunks
# are a small fraction of the collection.
#
# Two non-obvious constraints on THIS deployment (proven empirically, see doc):
#   1. /dev/shm = 64MB → a PARALLEL plan over the materialized CTE fails with
#      "DiskFull: could not resize shared memory segment". Must disable parallelism
#      for the statement (SET LOCAL max_parallel_workers_per_gather = 0).
#   2. The CTE brute-forces distance over the user's full chunk set. Latency is linear
#      (~9us/chunk): 100k=1.3s, 1M=9s, 2.8M(largest user)=~21-26s. Correct but slow for
#      huge users; a statement_timeout guards against pathological hangs.

set -euo pipefail
CONTAINER=nc_app_context_chat_backend
TARGET=/app/context_chat_backend/vectordb/pgvector.py

echo "=== Patch 7: HNSW selective-context fix ==="
docker exec "$CONTAINER" grep -n "PG_BATCH_SIZE\|HNSW_ACTIVATION" "$TARGET" | head -5

docker exec -i "$CONTAINER" python3 - <<'PYEOF'
path = '/app/context_chat_backend/vectordb/pgvector.py'
with open(path, 'r') as f:
    src = f.read()

if 'HNSW_ACTIVATION_THRESHOLD' in src:
    print('Already patched — skipping')
    exit(0)

# 1. Add constant after PG_BATCH_SIZE
src = src.replace(
    'PG_BATCH_SIZE = 50000',
    'PG_BATCH_SIZE = 50000\n'
    '# CCB-PATCH-hnsw-selective: PostgreSQL switches similarity ORDER BY to HNSW Index Scan\n'
    '# at ~5500 IN-list items, post-filtering to 0 results for users with < ~2% of total rows.\n'
    '# Below this size the existing ORM batch path is safe (no HNSW flip).\n'
    'HNSW_ACTIVATION_THRESHOLD = 5000\n'
    '# Brute-force similarity over the filtered set; cap runtime for pathologically large users.\n'
    'CTE_STATEMENT_TIMEOUT_MS = 60000',
)

# 2. Add _similarity_search_cte method just before the existing _similarity_search
cte_method = '''
\t# CCB-PATCH-hnsw-selective
\t# Map the configured langchain distance strategy to the pgvector operator so the CTE
\t# path is consistent with the ORM path even if distance_strategy is reconfigured.
\t_PGVECTOR_OP = {
\t\t\'l2_distance\': \'<->\',
\t\t\'cosine_distance\': \'<=>\',
\t\t\'max_inner_product\': \'<#>\',
\t}

\tdef _distance_op(self) -> str:
\t\t# distance_strategy is a property that raises ValueError for an unknown enum and
\t\t# returns a bound comparator method (whose __name__ is the dict key) otherwise.
\t\ttry:
\t\t\tname = self.client.distance_strategy.__name__  # bound column-comparator method
\t\texcept (AttributeError, ValueError):
\t\t\tname = \'cosine_distance\'
\t\treturn self._PGVECTOR_OP.get(name, \'<=>\')

\tdef _similarity_search_cte(
\t\tself,
\t\tsession: orm.Session,
\t\tcollection_uuid,
\t\tembedding: list[float],
\t\tchunk_ids: list[str],
\t\tk: int,
\t) -> list[Document]:
\t\t"""Pre-filter by id (btree) before similarity to avoid HNSW post-filter returning 0.

\t\tWhen len(chunk_ids) > HNSW_ACTIVATION_THRESHOLD, PostgreSQL's cost model switches the
\t\tsimilarity ORDER BY query from a seq-scan to an HNSW Index Scan. HNSW explores only
\t\t~ef_search (~40) global nearest neighbours and then post-filters by the id list.
\t\tUsers whose chunks are < ~2% of the collection get 0 surviving candidates → 0 results.

\t\tA MATERIALIZED CTE forces the btree id-filter to execute first as an independent fence
\t\t(PostgreSQL 12+), then similarity is computed only on the pre-filtered subset. EXPLAIN
\t\tshows Bitmap Heap Scan (btree) — no HNSW Index Scan.

\t\tTwo deployment constraints handled via SET LOCAL (transaction-scoped, no pool leak):
\t\t- max_parallel_workers_per_gather=0: a parallel plan over the materialized CTE needs
\t\t  shared-memory segments that exceed a small /dev/shm (64MB here) → DiskFull. Serial
\t\t  execution spills to normal temp space instead.
\t\t- statement_timeout: brute-force distance is O(n) in the user's chunk count (~9us/chunk);
\t\t  the cap prevents a pathologically large corpus from pinning a worker indefinitely.

\t\tANY(:chunk_ids) binds the whole list as one PostgreSQL array parameter, not individual
\t\t$1..$N params, so the 65535 bind-parameter limit does not apply.
\t\t"""
\t\temb_literal = \'[\' + \',\'.join(str(x) for x in embedding) + \']\'
\t\top = self._distance_op()  # one of a fixed set, safe to interpolate
\t\tsession.execute(sa.text(\'SET LOCAL max_parallel_workers_per_gather = 0\'))
\t\tsession.execute(sa.text(f\'SET LOCAL statement_timeout = {int(CTE_STATEMENT_TIMEOUT_MS)}\'))
\t\tresult = session.execute(
\t\t\tsa.text(f"""
\t\t\t\tWITH filtered AS MATERIALIZED (
\t\t\t\t\tSELECT id, document, cmetadata, embedding
\t\t\t\t\tFROM langchain_pg_embedding
\t\t\t\t\tWHERE collection_id = :coll_uuid
\t\t\t\t\tAND id = ANY(:chunk_ids)
\t\t\t\t)
\t\t\t\tSELECT id, document, cmetadata,
\t\t\t\t\t   embedding {op} cast(:query_vec AS vector) AS distance
\t\t\t\tFROM filtered
\t\t\t\tORDER BY distance
\t\t\t\tLIMIT :k
\t\t\t"""),
\t\t\t{
\t\t\t\t\'coll_uuid\': str(collection_uuid),
\t\t\t\t\'chunk_ids\': chunk_ids,
\t\t\t\t\'query_vec\': emb_literal,
\t\t\t\t\'k\': k,
\t\t\t},
\t\t)
\t\treturn [
\t\t\tDocument(
\t\t\t\tid=str(row.id),
\t\t\t\tpage_content=row.document,
\t\t\t\tmetadata=row.cmetadata,
\t\t\t)
\t\t\tfor row in result
\t\t]

'''
src = src.replace(
    '\t# modified from langchain_postgres.vectorstores\n\tdef _similarity_search(',
    cte_method + '\t# modified from langchain_postgres.vectorstores\n\tdef _similarity_search(',
)

# 3. In _similarity_search: short-circuit to CTE when chunk_ids exceeds threshold.
old = (
    '\t\tembedding = self.client.embeddings.embed_query(query)\n'
    '\t\tcollection = self.client.get_collection(session)\n'
    '\t\tif not collection:\n'
    '\t\t\traise DbException(\'Collection not found\')\n'
    '\n'
    '\t\t# Initialize results list to store all potential matches\n'
    '\t\tall_results = []'
)
new = (
    '\t\tembedding = self.client.embeddings.embed_query(query)\n'
    '\t\tcollection = self.client.get_collection(session)\n'
    '\t\tif not collection:\n'
    '\t\t\traise DbException(\'Collection not found\')\n'
    '\n'
    '\t\t# CCB-PATCH-hnsw-selective: bypass batching for large chunk lists — the ORM\n'
    '\t\t# .in_() path triggers HNSW Index Scan -> 0 results when > HNSW_ACTIVATION_THRESHOLD.\n'
    '\t\tif len(chunk_ids) > HNSW_ACTIVATION_THRESHOLD:\n'
    '\t\t\treturn self._similarity_search_cte(\n'
    '\t\t\t\tsession, collection.uuid, embedding, chunk_ids, k\n'
    '\t\t\t)\n'
    '\n'
    '\t\t# Initialize results list to store all potential matches\n'
    '\t\tall_results = []'
)
if old not in src:
    raise SystemExit('ERROR: short-circuit anchor not found — base file changed')
src = src.replace(old, new)

with open(path, 'w') as f:
    f.write(src)
print('Patch written OK')
PYEOF

echo "=== Syntax check ==="
docker exec "$CONTAINER" python3 -c "import ast; ast.parse(open('$TARGET').read()); print('AST OK')"
echo "=== Verifying markers ==="
docker exec "$CONTAINER" grep -n "HNSW_ACTIVATION_THRESHOLD\|_similarity_search_cte\|max_parallel_workers_per_gather\|CCB-PATCH-hnsw" "$TARGET"
echo "=== Restart to activate: docker restart $CONTAINER ==="
