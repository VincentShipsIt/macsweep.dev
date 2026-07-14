# GitHub issue standard

Every issue must be understandable without its labels or milestone.

## Title

- Use a concise, sentence-case outcome or observable problem.
- Start feature and maintenance work with an action verb when practical.
- Do not prefix titles with versions, release names, issue types, areas, priorities, or audit names.
- Do not add a trailing period.
- Keep the title under 100 characters when practical.

Good examples:

- `Add unified updates for Homebrew, App Store, and global packages`
- `Space Lens renders only immediate children on folder-heavy disks`
- `Extract a shared ProcessRunner with timeouts and concurrent pipe draining`

Avoid:

- `v1.1.0: Settings and safety controls`
- `[audit] Extract ProcessRunner`
- `Safety: Dashboard cleanup skips confirmation`

## Body

Use the Bug report or Work item form. Issues created through automation or the
GitHub CLI must preserve the same section order.

### Bug report

1. Summary
2. Reproduction
3. Expected behavior
4. Actual behavior
5. Acceptance criteria
6. Verification
7. Context

### Work item

1. Summary
2. Problem
3. Scope
4. Acceptance criteria
5. Verification
6. Out of scope
7. Context

Acceptance criteria describe observable completion conditions. Verification
describes how a reviewer or CI can prove those conditions hold.

## Metadata

Keep planning metadata out of the title:

| Concern | GitHub field |
| --- | --- |
| Bug, enhancement, documentation, or release work | Type label |
| GUI, safety, or another product surface | Area label |
| Audit or other source | Origin label |
| Intended product release | `release:*` label |
| Scheduled delivery window | Milestone |

Every open issue must have at least one type label and either a weekly milestone
or an explicit deferred/future designation.
