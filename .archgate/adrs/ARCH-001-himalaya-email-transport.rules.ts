/// <reference path="../rules.d.ts" />

/**
 * ARCH-001: Himalaya as sole email transport
 *
 * No file in lib/kontor/mail/ or lib/kontor/mcp/ should:
 * - Import :gen_tcp or :ssl (raw socket modules)
 * - Contain "IMAP" or "SMTP" string literals used as protocol markers
 *
 * Exception: lib/kontor/mcp/himalaya_client.ex is the designated integration
 * point and is excluded from these checks.
 */
export default {
  rules: {
    'no-raw-socket-transport': {
      description:
        'Himalaya must be the sole email transport — no direct IMAP/SMTP/gen_tcp in mail or MCP modules',
      severity: 'error',
      async check(ctx) {
        const files = ctx.scopedFiles.filter(
          (f) => !f.endsWith('himalaya_client.ex')
        )
        const matches = await Promise.all(
          files.map(async (file) => ctx.grep(file, /:(?:gen_tcp|ssl)/u))
        )
        for (const fileMatches of matches) {
          for (const m of fileMatches) {
            ctx.report.violation({
              message:
                `ARCH-001: direct raw socket module use found at ${m.file}:${m.line}. ` +
                'All email transport must go through Himalaya MCP (himalaya_client.ex).',
              file: m.file,
              line: m.line,
            })
          }
        }
      },
    },
    'no-imap-smtp-literals': {
      description:
        'IMAP/SMTP protocol literals must not appear in mail or MCP modules outside himalaya_client.ex',
      severity: 'error',
      async check(ctx) {
        const files = ctx.scopedFiles.filter(
          (f) => !f.endsWith('himalaya_client.ex')
        )
        const matches = await Promise.all(
          files.map(async (file) => ctx.grep(file, /"(?:IMAP|SMTP)"/u))
        )
        for (const fileMatches of matches) {
          for (const m of fileMatches) {
            // Elixir comments start with '#' — a literal inside a comment is
            // prose, not a protocol marker.
            if (/^\s*#/u.test(m.content)) continue
            ctx.report.violation({
              message:
                `ARCH-001: IMAP/SMTP string literal found at ${m.file}:${m.line}. ` +
                'Protocol identifiers must not appear in mail/mcp modules outside himalaya_client.ex.',
              file: m.file,
              line: m.line,
            })
          }
        }
      },
    },
  },
} satisfies RuleSet
