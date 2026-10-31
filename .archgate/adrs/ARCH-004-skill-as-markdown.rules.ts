/// <reference path="../rules.d.ts" />

/**
 * ARCH-004: Skills are markdown prompt templates, not compiled code
 *
 * Every .md file in priv/skills/ must have valid YAML frontmatter with
 * required fields: name, namespace, version, author. Missing fields are errors.
 */
export default {
  rules: {
    'skill-frontmatter': {
      description:
        'All skill .md files must have valid YAML frontmatter with name, namespace, version, and author fields',
      severity: 'error',
      async check(ctx) {
        for (const file of ctx.scopedFiles) {
          const content = await ctx.readFile(file)

          // Check for YAML frontmatter block
          if (!content.startsWith('---')) {
            ctx.report.violation({
              message:
                `ARCH-004: ${file} is missing YAML frontmatter. ` +
                'All skill files must begin with a --- delimited YAML frontmatter block.',
              file,
              line: 1,
            })
            continue
          }

          // Extract frontmatter block between first and second ---
          const endIndex = content.indexOf('---', 3)
          if (endIndex === -1) {
            ctx.report.violation({
              message:
                `ARCH-004: ${file} has an unclosed YAML frontmatter block. ` +
                'Frontmatter must be closed with a second --- delimiter.',
              file,
              line: 1,
            })
            continue
          }

          const frontmatter = content.slice(3, endIndex)

          // Check for required fields
          if (!/^\s*name\s*:/m.test(frontmatter)) {
            ctx.report.violation({
              message:
                `ARCH-004: ${file} is missing required frontmatter field: "name". ` +
                'All skill files must declare name, namespace, version, and author in their YAML frontmatter.',
              file,
            })
          }
          if (!/^\s*namespace\s*:/m.test(frontmatter)) {
            ctx.report.violation({
              message:
                `ARCH-004: ${file} is missing required frontmatter field: "namespace". ` +
                'All skill files must declare name, namespace, version, and author in their YAML frontmatter.',
              file,
            })
          }
          if (!/^\s*version\s*:/m.test(frontmatter)) {
            ctx.report.violation({
              message:
                `ARCH-004: ${file} is missing required frontmatter field: "version". ` +
                'All skill files must declare name, namespace, version, and author in their YAML frontmatter.',
              file,
            })
          }
          if (!/^\s*author\s*:/m.test(frontmatter)) {
            ctx.report.violation({
              message:
                `ARCH-004: ${file} is missing required frontmatter field: "author". ` +
                'All skill files must declare name, namespace, version, and author in their YAML frontmatter.',
              file,
            })
          }

          // Validate that version is a number (not a string)
          const versionMatch = frontmatter.match(/^\s*version\s*:\s*(.+)$/m)
          if (versionMatch) {
            const versionValue = versionMatch[1].trim()
            if (!/^\d+$/.test(versionValue)) {
              ctx.report.violation({
                message:
                  `ARCH-004: ${file} has an invalid version value: "${versionValue}". ` +
                  'Version must be a positive integer.',
                file,
              })
            }
          }

          // Validate that author is not empty
          const authorMatch = frontmatter.match(/^\s*author\s*:\s*(.+)$/m)
          if (authorMatch) {
            const authorValue = authorMatch[1].trim()
            if (!authorValue || authorValue === 'null' || authorValue === '~') {
              ctx.report.violation({
                message:
                  `ARCH-004: ${file} has an empty or null author field. ` +
                  'Author must be "llm" or a valid GitHub username.',
                file,
              })
            }
          }
        }
      },
    },
  },
} satisfies RuleSet
