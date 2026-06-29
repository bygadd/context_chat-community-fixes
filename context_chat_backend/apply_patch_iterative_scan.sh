#!/usr/bin/env bash
# ⛔ SUPERSEDED / DO NOT USE (2026-06-29, #35892): this native-iterative_scan-only approach
# REGRESSED real queries on prod. iterative_scan + hnsw.max_scan_tuples (default 20000) is
# APPROXIMATE — for a medium/large per-user scope it only visits the global-nearest ~20000 then
# post-filters by the id-list, so a relevant in-scope chunk outside the global top-N is MISSED
# (a files-scoped invoice query returned "Не знам"). The exact Patch 7 CTE (apply_patch_hnsw.sh)
# + Patch 7b (apply_patch_hnsw_postfilter.sh) were RESTORED. Kept only for provenance.
#
# Patch 7-native — Selective Context 0-results fix via native pgvector >=0.8 iterative_scan
# (CCB-PATCH-iterative-scan). Applies to: nc_app_context_chat_backend (5.4.0+, pgvector >= 0.8.0).
# File: /app/context_chat_backend/vectordb/pgvector.py
# Re-apply after every: app_api:app:update context_chat_backend
#
# SUPERSEDES the local logic-rewrites Patch 7 (apply_patch_hnsw.sh, MATERIALIZED CTE) and
# Patch 7b (apply_patch_hnsw_postfilter.sh, HNSW post-filter). Decision (Yoan, 2026-06-29):
# KEEP the original 5.4.0 _similarity_search logic — it is exhaustive over the scope and returns
# FULL/EXACT results — and changing that logic would be hard to land in an upstream PR. The
# minimal, PR-friendly fix recommended in nextcloud/context_chat_backend#320 is to enable the
# native pgvector iterative_scan, so an HNSW plan keeps scanning past the first ef_search batch
# instead of post-filtering the id-list down to 0 rows. This is a ~2-line, behaviour-preserving
# change (no-op when the planner uses the btree id index, which it does for the <=50k batches).
#
# Run on a PRISTINE 5.4.0 pgvector.py (revert Patch 7/7b first if present).

set -euo pipefail
CONTAINER=nc_app_context_chat_backend
TARGET=/app/context_chat_backend/vectordb/pgvector.py

echo "=== Patch 7-native: hnsw.iterative_scan (preserve original 5.4.0 logic) ==="

docker exec -i "$CONTAINER" python3 - <<'PYEOF'
path = '/app/context_chat_backend/vectordb/pgvector.py'
with open(path, 'r') as f:
    src = f.read()

if 'CCB-PATCH-iterative-scan' in src:
    print('Already patched — skipping')
    raise SystemExit(0)

if 'CCB-PATCH-hnsw' in src:
    raise SystemExit('ERROR: Patch 7/7b still present — revert to pristine 5.4.0 first')

old = (
    "\t\tif not collection:\n"
    "\t\t\traise DbException('Collection not found')\n"
    "\n"
    "\t\t# Initialize results list to store all potential matches\n"
)
new = (
    "\t\tif not collection:\n"
    "\t\t\traise DbException('Collection not found')\n"
    "\n"
    "\t\t# CCB-PATCH-iterative-scan (#320 native fix, pgvector>=0.8): keep the original 5.4.0\n"
    "\t\t# exhaustive batched logic (full/exact results); only let an HNSW plan keep scanning past\n"
    "\t\t# the first ef_search batch so the id-filtered ORDER BY never post-filters down to 0 rows.\n"
    "\t\t# strict_order preserves exact distance order; a no-op when the planner uses the btree id\n"
    "\t\t# index (the usual choice for the <=PG_BATCH_SIZE batches).\n"
    "\t\tsession.execute(sa.text('SET LOCAL hnsw.iterative_scan = strict_order'))\n"
    "\n"
    "\t\t# Initialize results list to store all potential matches\n"
)
if old not in src:
    raise SystemExit('ERROR: anchor not found (file not pristine 5.4.0?)')
src = src.replace(old, new, 1)

with open(path, 'w') as f:
    f.write(src)
print('Patch written OK')
PYEOF

echo "=== Syntax check ==="
docker exec "$CONTAINER" python3 -c "import ast; ast.parse(open('$TARGET').read()); print('AST OK')"
echo "=== Verifying marker ==="
docker exec "$CONTAINER" grep -n "CCB-PATCH-iterative-scan\|hnsw.iterative_scan" "$TARGET"
echo "=== Restart to activate: docker restart $CONTAINER ==="
