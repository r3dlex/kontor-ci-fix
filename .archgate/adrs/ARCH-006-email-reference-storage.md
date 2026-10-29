---
id: ARCH-006
title: Email reference storage (reference-first, copy-optional)
domain: email-storage
rules: true
files: ["lib/kontor/mail/**/*.ex", "lib/kontor/accounts/mailbox.ex", "lib/kontor/ai/pipeline.ex", "lib/kontor/ai/sandbox.ex", "priv/repo/migrations/*reference_storage*"]
---

# ARCH-006: Email Reference Storage (Reference-First, Copy-Optional)

## Status

Proposed (Revised -- Architect ITERATE + Critic REVISE incorporated)

## Context

Kontor's AI pipeline uses a "lossy markdown" system: each email thread has a persistent markdown document that is incrementally updated as new emails arrive. The raw email body is consumed by the AI pipeline (classifier, thread summarizer, scorer) to produce this markdown, after which the body's primary utility is fulfilled.

Currently, every email's full body and raw headers are stored in PostgreSQL. For a typical mailbox with thousands of emails, body text dominates storage. Since the thread markdown is the primary working document for the AI-driven UX, storing every email body is redundant for the default use case.

Some users may want full body storage for archival, full-text search, or compliance reasons. This must remain possible but should not be the default.

### Pre-existing Bug (Prerequisite)

`pipeline.ex:121` passes `%{markdown: md}` to `Sandbox.execute(:write_thread_markdown, ...)` but `sandbox.ex:98` pattern-matches on `%{content: content}`. This key mismatch causes `write_thread_markdown` to fail silently. This must be fixed before the process-once guarantee can function, as it depends on `post_process/4` succeeding.

### Decision Drivers

1. **Storage efficiency** -- Email bodies account for 80-90% of the `emails` table size. Reference-only storage reduces database growth proportionally to email volume.
2. **Processing correctness** -- The AI pipeline must process each email exactly once for markdown contribution. An atomic CAS on `threads.markdown_stale` provides a concurrency-safe, queryable guarantee at the thread level.
3. **User autonomy** -- Different mailboxes have different retention needs. A per-mailbox `copy_emails` toggle gives users control without global configuration complexity.

## Decision

**Default behavior: store email with body at import, discard body after successful AI processing.**

### Body Lifecycle (Inverted from v1)

1. Read the full email (including body) from Himalaya MCP.
2. Insert the Email row WITH body and raw_headers (as today -- no change to insert).
3. Set `thread.markdown_stale = true` for the email's thread.
4. Pass the email to the AI pipeline for thread markdown processing.
5. On pipeline SUCCESS: perform atomic CAS (`UPDATE threads SET markdown_stale = false WHERE id = ? AND markdown_stale = true`).
6. If CAS succeeds and `mailbox.copy_emails == false`: nil out `email.body` and `email.raw_headers`, set `email.processed_at`.
7. On pipeline FAILURE: leave body intact, leave `markdown_stale = true`. The `MarkdownBackfillWorker` will retry.

**Opt-in full storage:** When `mailbox.copy_emails == true`, body and raw_headers are never nilled out (step 6 is skipped).

**Self-healing property:** Because body is always inserted at import time and only removed after confirmed success, pipeline failures leave the system in a retryable state. No data is lost.

### Process-Once Guarantee (Thread-Level CAS)

The `markdown_stale` boolean on the Thread row (not Email) controls processing state:
- Set to `true` when a new email arrives for the thread.
- Set to `false` via atomic CAS after successful pipeline processing.
- Concurrent emails in the same thread: CAS loser sees 0 rows updated and skips. The winner's markdown update incorporates the most recent email context (via coherence sampling of prior emails).

### Import Paths

- **Poller** (real-time): Inserts email, sets `thread.markdown_stale = true`, calls `Pipeline.process_email/1` directly (only if thread is stale). Includes nil-id guard for `on_conflict: :nothing` duplicates.
- **Importer** (bulk historical): Inserts email, sets `thread.markdown_stale = true`, does NOT call pipeline directly. Relies on `MarkdownBackfillWorker` (Oban, 5-minute interval) to process stale threads in batches. This keeps bulk import simple and rate-limited.

### Nil-ID Guard

Both Poller and Importer use `on_conflict: :nothing` for email dedup. When the insert is a duplicate, Ecto returns `%Email{id: nil}`. Before calling the pipeline, the code must check for nil id. If nil, fetch the existing email by `[tenant_id, message_id]` and only call pipeline if `thread.markdown_stale == true`.

### Schema Changes

- `mailboxes` table: Add `copy_emails` (boolean, default: false, not null)
- `emails` table: Alter `body` to nullable, alter `raw_headers` to nullable (no new columns -- `processed_at` already exists)
- `threads` table: Add `markdown_stale` (boolean, default: true, not null)
- New partial index: `CREATE INDEX threads_stale_idx ON threads (tenant_id) WHERE markdown_stale = true`
- Removed from v1: `markdown_processed` on emails, composite index on `[:mailbox_id, :markdown_processed]`

### Alternatives Considered

**Option B -- Separate `email_bodies` table:** Move body and headers to a dedicated table, joined on demand. This provides cleaner separation but adds schema complexity (extra table, foreign key, joins) without proportional benefit. The current codebase has no full-text search or attachment handling that would justify a separate table. This option can be adopted later if retention requirements grow.

**Compress bodies in-place (pg_lz):** Use PostgreSQL TOAST compression for body storage. This reduces storage but does not eliminate it, and does not address the process-once requirement.

**Email-level `markdown_processed` flag (v1 approach):** Track processing on the email rather than the thread. Rejected because: (a) batch reprocessing queries are less efficient (must join emails to threads), (b) thread-level stale flag naturally handles "new email invalidates thread markdown" semantics, (c) atomic CAS on thread is simpler than per-email flag management.

## Consequences

**Positive:**
- Database storage reduced by 80-90% for default-mode mailboxes
- Self-healing: pipeline failure leaves body intact for retry
- Atomic CAS prevents duplicate processing without locks
- Thread-level stale flag simplifies batch reprocessing queries
- Per-mailbox control over storage behavior
- Backwards compatible -- existing email rows with bodies are untouched
- No changes required to the Himalaya MCP interface
- Importer path cleanly separated from pipeline via Oban backfill worker

**Negative:**
- Email body not available for full-text search after cleanup in reference-only mode (must re-fetch from provider)
- Cannot retroactively populate bodies for previously cleaned emails without re-import
- Two-phase body lifecycle (insert then conditional cleanup) adds code complexity
- `GET /api/v1/emails/:id` may return `body: null` -- frontend must handle gracefully
- `email_processing_log` deferred to v2 -- limited audit trail beyond `processed_at` timestamp

## Exceptions

- During import, the body is always inserted regardless of `copy_emails` setting -- it is needed for AI processing
- The `markdown_stale` flag is managed by the import flow (set to true) and the AI pipeline (set to false via CAS), not by the user
- Existing migrations and email rows are not modified by this change
- The Importer does not call the pipeline directly; it relies on the `MarkdownBackfillWorker`

## Follow-ups

- **v2:** Add `email_processing_log` table for detailed audit trail (processing duration, error messages, retry count)
- **v2:** Consider Option B (separate body table) if attachment handling or full-text search is added
- **v2:** Add observability metrics (processing latency, stale thread count, body cleanup rate)
