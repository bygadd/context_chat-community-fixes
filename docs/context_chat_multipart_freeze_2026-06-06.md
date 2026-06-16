# Context Chat indexing freezes permanently on a mail subject containing a raw CR

## Summary
A single source whose **title contains a raw CR (`\r`)** (or other bare CR/LF) permanently
freezes **all** Context Chat indexing (files *and* mail). The strict multipart parser in the
backend rejects the entire `/loadSources` batch with HTTP 400, the offending source stays in
the queue, and `SubmitContentJob` retries the same batch forever → 0 progress, 100% 400s.

## Environment
- Nextcloud 33.0.5.1
- `context_chat` (PHP app) 5.3.1, `context_chat_backend` (ExApp) 5.3.0
- python-multipart 0.0.22, starlette 0.52.1, uvicorn 0.41.0, Python 3.11

## Root cause
`context_chat_backend` reads each source's metadata from **per-part HTTP headers** of the
multipart `PUT /loadSources` request (`controller.py:347`):
```python
source.headers.get('title')   # the mail subject
source.headers.get('userIds') / 'type' / 'modified' / 'provider'
```
The sender (NC PHP — context_chat / app_api) places the **mail subject** into the `title`
part-header **without sanitizing CR/LF**. For a subject ending in a raw CR, the emitted header is:
```
title: <subject>\r\r\n      (subject's CR  +  the header's CRLF terminator)
```
`python-multipart` >= 0.0.18 (strict CRLF) hits the second CR where it expects LF and raises:
```
[WARNING|multipart]: Did not find LF character at end of header (found 13)
```
→ HTTP 400 for the **whole batch**. The source is never removed from the queue, so the job
retries the identical batch indefinitely. HTTP header values must not contain raw CR/LF (RFC 7230);
this is a sender bug, exposed by (correctly) strict parsing.

## Evidence (this deployment)
- First failure **2026-06-06 01:22:40 UTC**, exactly when `SubmitContentJob` reached
  `oc_context_chat_content_queue` id **281719**, title `"... Регистрант Податоци[мк]\r"`
  (a domain-registrar mail; courier mails with a trailing `\n` are also present — 5 CR + 16 LF titles found).
- **No** backend restart / config / version change at that moment — the same uvicorn worker
  served `200` at 01:22:37 and `400` at 01:22:40. Pure data trigger (the queue simply reached
  the first poison title). Parser has been strict since the image build (2026-02-23).
- 24,755 consecutive `Did not find LF` warnings; queue stuck at ~88k with 0 drain for hours.

## Impact
One mail with a CR/LF in its subject silently freezes ALL Context Chat indexing indefinitely.

## Proposed fixes
1. **Sender (context_chat / app_api):** strip/replace CR/LF in header values (title, etc.)
   before building the multipart part-headers. (Primary fix.)
2. **Backend (context_chat_backend), defensive:** don't let one malformed source kill the whole
   batch — either tolerate stray CR in header parsing, or skip+log the single bad source and
   continue (instead of 400-ing and infinitely retrying the entire batch).

## Working backend patch (defensive #2)
File: `python_multipart/multipart.py`, state `HEADER_VALUE_ALMOST_DONE`:
```diff
                 if c != LF:
+                    if c == CR:
+                        # tolerate stray trailing CR(s) in a header value (e.g. an unsanitized
+                        # mail-subject title -> 'title: ...\r\r\n'); consume and keep waiting for
+                        # the LF instead of failing the whole loadSources batch
+                        i += 1
+                        continue
                     msg = f"Did not find LF character at end of header (found {c!r})"
                     self.logger.warning(msg)
                     e = MultipartParseError(msg)
                     e.offset = i
                     raise e
```
Effect: the stray CR is dropped from the parsed value (title indexed cleanly); the batch parses.
Verified: `multipart_400` → 0, queue draining (88265 → 88005...), docs growing, no embedding errors.

## Local ops runbook (THIS deployment)
- Patch applied live in container `nc_app_context_chat_backend`; original backed up at
  `python_multipart/multipart.py.ccb-bak`.
- **The live patch is LOST on `occ app_api:app:update` / redeploy** (it lives in the container's
  writable layer, not the image). After ANY backend redeploy, re-apply:
  1. `docker exec -i nc_app_context_chat_backend python3 - <<'PY'` (the insert script), or
     `cp multipart.py.ccb-bak`-then-re-patch.
  2. remove `python_multipart/__pycache__/multipart.cpython-311.pyc`
  3. `docker restart nc_app_context_chat_backend`
- Durable option: bake the patch into a derived image, or wait for the upstream fix.

##Work-ticket (Task: root cause + fix).  (this prod change), linked to.
