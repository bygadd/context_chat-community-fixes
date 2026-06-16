# context_chat — community fixes

Consolidated patches and write-ups developed while stabilising **Nextcloud context_chat**
(app `5.3.1` / backend) on a production **NC 33.0.5** deployment. Staged here for an
eventual comprehensive upstream contribution. Every fix was diagnosed against the source
and verified live. Two upstream targets:

## nextcloud/context_chat (PHP app)
| Patch | Status | Dir |
|---|---|---|
| SMB `fopen` non-seekable → unconditional `CachingStream` (`LangRopeService`) | live | `context_chat/smb-seek/` |
| Indexing-job self-heal (`IndexerWatchdogJob` TimedJob + `insertIntoQueue` fix) | local | `context_chat/IndexerWatchdogJob/` |

## nextcloud/context_chat_backend (Python)
| Patch | Status | Doc |
|---|---|---|
| multipart-CR indexing freeze | live | `docs/context_chat_multipart_freeze_2026-06-06.md` |
| `exec_in_proc` fork-deadlock | live | `docs/context_chat_fork_deadlock_2026-06-07.md` |
| recv-leak / orphaned `_indexing` lock (+ test) | live | `docs/context_chat_recv_leak_lease_2026-06-07.md` |
| child-log relay | live | (in the recv-leak/lease doc) |
| HNSW selective-context 0-results (pgvector) | live | `docs/context_chat_hnsw_selective_context_2026-06-12.md` |

> Note: the NC-core TaskProcessing worker dedup/atomic-claim fix is **not** part of this
> contribution — it lives in `nextcloud/server` and is being contributed there separately
> (PR #61053).

*These patches were prepared with AI assistance and verified on a live deployment.*
