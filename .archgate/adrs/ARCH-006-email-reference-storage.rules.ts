/// <reference path="../rules.d.ts" />

/**
 * ARCH-006: Email reference storage (reference-first, copy-optional)
 *
 * The ADR replaces "store every email body forever" with "store the body at
 * import, drop it after the AI pipeline has processed the email". Three
 * invariants make that safe:
 *
 *  - the schema supports reference-only mode (copy_emails / markdown_stale /
 *    a partial index over stale threads),
 *  - a thread is processed exactly once (atomic CAS on markdown_stale),
 *  - an email body is only discarded when the mailbox opted out of copies.
 */
export default {
  rules: {
    'reference-storage-schema': {
      description:
        'The reference_storage migration must add copy_emails, markdown_stale and the threads_stale_idx partial index',
      severity: 'error',
      async check(ctx) {
        const migrations = await ctx.glob(
          'priv/repo/migrations/*reference_storage*'
        )
        if (migrations.length === 0) {
          ctx.report.violation({
            message:
              'ARCH-006: no priv/repo/migrations/*reference_storage* migration exists. ' +
              'Reference-first storage requires a migration adding copy_emails and markdown_stale.',
            file: 'priv/repo/migrations',
          })
          return
        }

        for (const file of migrations) {
          const content = await ctx.readFile(file)

          if (!/add :copy_emails, :boolean, null: false, default: false/u.test(content)) {
            ctx.report.violation({
              message:
                `ARCH-006: ${file} must add copy_emails as a not-null boolean defaulting to false.`,
              file,
            })
          }

          if (!/add :markdown_stale, :boolean, null: false, default: true/u.test(content)) {
            ctx.report.violation({
              message:
                `ARCH-006: ${file} must add markdown_stale as a not-null boolean defaulting to true.`,
              file,
            })
          }

          if (!/CREATE INDEX threads_stale_idx ON threads \(tenant_id\) WHERE markdown_stale = true/u.test(content)) {
            ctx.report.violation({
              message:
                `ARCH-006: ${file} must create the threads_stale_idx partial index over stale threads.`,
              file,
            })
          }
        }
      },
    },
    'process-once-cas': {
      description:
        'Kontor.Mail must clear markdown_stale with an atomic compare-and-set guarded by tenant_id',
      severity: 'error',
      async check(ctx) {
        const file = 'lib/kontor/mail/mail.ex'
        let content: string
        try {
          content = await ctx.readFile(file)
        } catch {
          ctx.report.violation({
            message: `ARCH-006: ${file} is missing, so the process-once CAS cannot exist.`,
            file,
          })
          return
        }

        const hasCasGuard =
          /markdown_stale == true/u.test(content) &&
          /tenant_id/u.test(content) &&
          /set: \[markdown_stale: false\]/u.test(content)

        if (!hasCasGuard) {
          ctx.report.violation({
            message:
              `ARCH-006: ${file} must clear markdown_stale with an atomic ` +
              'compare-and-set (tenant_id scoped, guarded by markdown_stale == true). ' +
              'Without the CAS the AI pipeline can process an email more than once.',
            file,
          })
        }
      },
    },
    'body-cleared-only-when-copy-disabled': {
      description:
        'The AI pipeline must only discard an email body when the mailbox has copy_emails disabled',
      severity: 'error',
      async check(ctx) {
        const file = 'lib/kontor/ai/pipeline.ex'
        let content: string
        try {
          content = await ctx.readFile(file)
        } catch {
          ctx.report.violation({
            message: `ARCH-006: ${file} is missing, so the body lifecycle cannot be enforced.`,
            file,
          })
          return
        }

        const guarded = /copy_emails/u.test(content)
        if (!guarded) {
          ctx.report.violation({
            message:
              `ARCH-006: ${file} must check mailbox.copy_emails before discarding an email body. ` +
              'A mailbox that opted into copies must keep its body and raw_headers.',
            file,
          })
        }
      },
    },
  },
} satisfies RuleSet
