#!/usr/bin/env bash
# Patch childlog (5.4.0) — relay forkserver child log records to the parent's handlers
# (CCB-PATCH-childlog). Applies to: nc_app_context_chat_backend 5.4.0+.
# File: /app/context_chat_backend/vectordb/../utils.py  ->  /app/context_chat_backend/utils.py
# Re-apply after every: app_api:app:update context_chat_backend
#
# Problem (upstream nextcloud/context_chat_backend#319): main.py calls setup_logging() under
# `if __name__ == '__main__'` and then sets the forkserver start method. Forkserver children are
# re-imported WITHOUT __main__, so setup_logging() never runs in them -> the embed/ingest child
# loggers (ccb.injest / network_em / doc_loader / models / vectordb) have no handlers and their
# INFO/DEBUG records are lost. 5.4.0's stdconn pipe only relays raw child stdout/stderr (+ a
# faulthandler crash dump), NOT logging records, so per-request indexing/embedding stays invisible.
#
# Fix (the approach suggested in the issue): a single multiprocessing.Queue + QueueListener bound
# to the parent's real `ccb` handlers (ONE writer -> no RotatingFileHandler rotation race), and a
# QueueHandler installed on the `ccb` logger in each child via exception_wrap. Scoped to `ccb.*`
# so library noise isn't relayed.

set -euo pipefail
CONTAINER=nc_app_context_chat_backend
TARGET=/app/context_chat_backend/utils.py

echo "=== Patch childlog (5.4.0): forkserver child log relay ==="

docker exec -i "$CONTAINER" python3 - <<'PYEOF'
path = '/app/context_chat_backend/utils.py'
with open(path, 'r') as f:
    src = f.read()

if 'CCB-PATCH-childlog' in src:
    print('Already patched — skipping')
    raise SystemExit(0)

# 1. module-level: import + queue/listener + helpers, after _MAX_STD_CAPTURE_CHARS
anchor1 = '_MAX_STD_CAPTURE_CHARS = 64 * 1024'
block1 = anchor1 + '''

# CCB-PATCH-childlog: forkserver children re-import without __main__, so setup_logging() (guarded
# by `if __name__ == "__main__"` in main.py) never runs in them and child loggers lose their
# handlers (upstream #319). Relay child `ccb.*` records to the parent's real handlers via a single
# QueueListener (one writer -> no rotation race); a QueueHandler is installed per child below.
import logging.handlers  # noqa: E402

_log_queue = None
_log_listener = None


def _ensure_log_listener():
\t"""Lazily start a QueueListener bound to the parent's real `ccb` handlers. Returns the queue
\t(or None if setup_logging hasn't configured any handlers yet)."""
\tglobal _log_queue, _log_listener
\tif _log_listener is not None:
\t\treturn _log_queue
\tccb_logger = logging.getLogger('ccb')
\thandlers = list(ccb_logger.handlers) or list(logging.getLogger().handlers)
\tif not handlers:
\t\treturn None
\t_log_queue = mp.Queue()
\t_log_listener = logging.handlers.QueueListener(_log_queue, *handlers, respect_handler_level=True)
\t_log_listener.start()
\treturn _log_queue


def _setup_child_logging(queue):
\t"""Install a QueueHandler on the child's `ccb` logger so its records reach the parent listener."""
\tif queue is None:
\t\treturn
\tqh = logging.handlers.QueueHandler(queue)
\tccb = logging.getLogger('ccb')
\tccb.handlers = [qh]
\tccb.setLevel(logging.DEBUG)
\tccb.propagate = False'''
if anchor1 not in src:
    raise SystemExit('ERROR: anchor1 (_MAX_STD_CAPTURE_CHARS) not found')
src = src.replace(anchor1, block1, 1)

# 2. exception_wrap signature: add _log_queue keyword-only param
anchor2 = 'def exception_wrap(fun: Callable | None, *args, resconn: Connection, stdconn: Connection, **kwargs):'
new2 = 'def exception_wrap(fun: Callable | None, *args, resconn: Connection, stdconn: Connection, _log_queue=None, **kwargs):'
if anchor2 not in src:
    raise SystemExit('ERROR: anchor2 (exception_wrap signature) not found')
src = src.replace(anchor2, new2, 1)

# 3. inside exception_wrap: configure child logging right after the signal-ignore lines
anchor3 = ("\tsignal.signal(signal.SIGINT, signal.SIG_IGN)\n"
           "\tsignal.signal(signal.SIGTERM, signal.SIG_IGN)\n")
new3 = anchor3 + "\n\t_setup_child_logging(_log_queue)  # CCB-PATCH-childlog\n"
if anchor3 not in src:
    raise SystemExit('ERROR: anchor3 (signal lines in exception_wrap) not found')
src = src.replace(anchor3, new3, 1)

# 4. exec_in_proc: pass the queue into the child kwargs
anchor4 = "\tkwargs['stdconn'] = std_cconn\n"
new4 = anchor4 + "\tkwargs['_log_queue'] = _ensure_log_listener()  # CCB-PATCH-childlog\n"
if anchor4 not in src:
    raise SystemExit('ERROR: anchor4 (kwargs stdconn) not found')
src = src.replace(anchor4, new4, 1)

with open(path, 'w') as f:
    f.write(src)
print('Patch childlog written OK')
PYEOF

echo "=== Syntax check ==="
docker exec "$CONTAINER" python3 -c "import ast; ast.parse(open('$TARGET').read()); print('AST OK')"
echo "=== Verifying markers ==="
docker exec "$CONTAINER" grep -n "CCB-PATCH-childlog\|_ensure_log_listener\|_setup_child_logging\|_log_queue" "$TARGET" | head
echo "=== Restart to activate: docker restart $CONTAINER ==="
