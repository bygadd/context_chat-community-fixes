# context_chat — community fixes (PR staging)

Consolidated patches developed for Nextcloud context_chat on the Videnov deployment,
staged here for an eventual comprehensive upstream contribution once context_chat is on a
final, bug-free version. Two upstream targets:

## nextcloud/context_chat (PHP app)
| Patch | Status | GLPI | Dir |
|---|---|---|---|
| SMB `fopen` non-seekable → unconditional `CachingStream` (LangRopeService) | live (Yoan-applied) | #35096 / Change #93 | `context_chat/smb-seek/` |
| Indexing-job self-heal (`IndexerWatchdogJob` TimedJob + `insertIntoQueue` fix) | local clone | #35096 | `context_chat/IndexerWatchdogJob/` |

## nextcloud/context_chat_backend (Python)
| Patch | Status | GLPI | Doc |
|---|---|---|---|
| multipart-CR freeze fix | live | #34981 / Change #89-93 | `docs/context_chat_multipart_freeze_2026-06-06.md` |
| fork-deadlock freeze fix | live | #34981 | `docs/context_chat_fork_deadlock_2026-06-07.md` |
| recv-leak / lease fix (+test) | live | #34981 | `docs/context_chat_recv_leak_lease_2026-06-07.md` |
| child-log relay (ccb.log) | live | #34981 | (in recv_leak_lease doc) |

NOT part of this contribution: the NC-core worker dedup fix lives in `nextcloud/server`
(repo `nc-worker-resilience`, already PR'd separately).
