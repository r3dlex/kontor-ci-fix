/// <reference path="../rules.d.ts" />

/**
 * ARCH-005: Zero-install distribution via Burrito
 *
 * mix.exs must contain "burrito" in the releases/0 function and in deps.
 */
export default {
  rules: {
    'burrito-zero-install-config': {
      description: 'mix.exs must configure Burrito in both deps and releases/0',
      severity: 'error',
      async check(ctx) {
        const file = ctx.scopedFiles.find((f) => f.endsWith('mix.exs'))
        if (file === undefined) return

        const content = await ctx.readFile(file)

        // Check that burrito appears in deps
        // Match {:burrito, ...} in the deps list
        if (!/:burrito/.test(content)) {
          ctx.report.violation({
            message:
              `ARCH-005: ${file} does not list :burrito as a dependency. ` +
              'Burrito must be included in deps for zero-install binary distribution.',
            file,
          })
        }

        // Check that burrito appears in the releases configuration
        // The releases function should reference Burrito.wrap
        if (!/Burrito\.wrap/.test(content)) {
          ctx.report.violation({
            message:
              `ARCH-005: ${file} does not reference Burrito.wrap in the releases configuration. ` +
              'The releases/0 function must include &Burrito.wrap/1 in its steps.',
            file,
          })
        }

        // Check that burrito targets are configured
        if (!/burrito:/.test(content) && !/burrito \[/.test(content)) {
          ctx.report.violation({
            message:
              `ARCH-005: ${file} is missing Burrito targets configuration in releases/0. ` +
              'Expected a burrito: keyword with macos_arm, macos_x86, and linux_x86 targets.',
            file,
          })
        }

        // Verify at least one target is defined
        const hasTargets =
          /macos_arm/.test(content) ||
          /macos_x86/.test(content) ||
          /linux_x86/.test(content)

        if (!hasTargets) {
          ctx.report.violation({
            message:
              `ARCH-005: ${file} has no Burrito targets defined. ` +
              'Expected targets: macos_arm, macos_x86, linux_x86.',
            file,
          })
        }
      },
    },
  },
} satisfies RuleSet
