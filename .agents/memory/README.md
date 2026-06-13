# Agent memory

Durable context loaded by AI CLIs (Claude Code, Codex, Gemini) at session start.

## Layout

- `*.md` here (root) — **committed** project memory: architecture decisions,
  gotchas, conventions that generalize across machines. Each file carries a
  `last_verified: YYYY-MM-DD` frontmatter key; re-verify before citing if it is
  older than ~30 days.
- `local/` — **gitignored** machine-specific memory written by the
  `scan-and-memorize` skill (this user's disk profile, installed apps, login
  items, cleanup preferences). Personal data; never committed to this public
  repo.

## Skills

Repo-local skills live in `.agents/skills/` (source of truth) and are mirrored
into `.claude/skills/` and `.codex/skills/` via `scripts/skills.sh sync`.
Run that once after cloning to make them discoverable.
