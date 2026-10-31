/// <reference path="../rules.d.ts" />

/**
 * ARCH-003: LLM actions must pass through AI Sandbox
 *
 * - lib/kontor/ai/pipeline.ex must reference "Sandbox" or "AI.Sandbox"
 * - Direct Req.get/Req.post calls outside minimax_client.ex and embeddings.ex are violations
 */
export default {
  rules: {
    'pipeline-uses-sandbox': {
      description:
        'lib/kontor/ai/pipeline.ex must route LLM-proposed actions through AI.Sandbox',
      severity: 'error',
      async check(ctx) {
        const file = ctx.scopedFiles.find((f) => f.endsWith('pipeline.ex'))
        if (file === undefined) return

        const content = await ctx.readFile(file)
        if (!/Sandbox|AI\.Sandbox/.test(content)) {
          ctx.report.violation({
            message:
              `ARCH-003: ${file} does not reference Sandbox or AI.Sandbox. ` +
              'The AI pipeline must route all LLM-proposed actions through the Sandbox allowlist validator.',
            file,
          })
        }
      },
    },
    'no-direct-http-in-ai-modules': {
      description:
        'Direct Req.get/Req.post calls are only permitted in minimax_client.ex and embeddings.ex',
      severity: 'error',
      async check(ctx) {
        const files = ctx.scopedFiles.filter(
          (f) =>
            !f.endsWith('minimax_client.ex') && !f.endsWith('embeddings.ex')
        )
        const matches = await Promise.all(
          files.map(async (file) => ctx.grep(file, /Req\.(?:get|post)\(/u))
        )
        for (const fileMatches of matches) {
          for (const m of fileMatches) {
            // Skip comment lines
            if (/^\s*#/.test(m.content)) continue
            ctx.report.violation({
              message:
                `ARCH-003: direct Req.get/Req.post call found at ${m.file}:${m.line}. ` +
                'Direct HTTP calls from AI modules are only permitted in minimax_client.ex and embeddings.ex. ' +
                'All other AI module HTTP interactions must go through the designated clients.',
              file: m.file,
              line: m.line,
            })
          }
        }
      },
    },
  },
} satisfies RuleSet
