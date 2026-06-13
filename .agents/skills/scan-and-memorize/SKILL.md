---
name: scan-and-memorize
description: >-
  Profile the current Mac with MacSweep's read-only CLI and persist a durable
  machine profile + cleanup preferences into agent memory. Use when asked to
  "scan and remember my computer", "learn my machine", "what should I clean",
  "remember my cleanup preferences", or before recommending any cleanup so the
  advice is grounded in this machine's real state. Runs ONLY read-only commands
  (scan/space/list/status) — never apply, uninstall, shred, or upgrade.
---

# Scan & memorize this Mac

Build a durable, machine-specific picture of the user's system from MacSweep's
JSON output and write it where every agent (Claude Code, Codex, Gemini) will
load it next session.

## Privacy contract (read first)

- This repo is **public**. Scanned output describes the user's personal machine
  (home-dir paths, installed apps, login items). It MUST NOT be committed.
- Write **only** into `.agents/memory/local/`. That path is gitignored.
- Never write machine data into the committed memory root or any tracked file.
- Run **read-only** commands only. Never run `apply`, `uninstall <app>`,
  `login-items enable|disable|remove`, `homebrew upgrade`, `shred`, or
  `maintenance <action>` from this skill.

## Step 1 — locate the binary

Prefer, in order:

1. A release build: `MacSweep/.build/release/macsweep`
2. A debug build: `MacSweep/.build/debug/macsweep`
3. `macsweep` on `PATH` (Homebrew install)

If none exist, build once (no signing needed):

```bash
cd MacSweep && swift build -c release
BIN="$(pwd)/.build/release/macsweep"
```

Set `BIN` to the resolved path and use `"$BIN"` for every call below.

## Step 2 — collect read-only JSON

Run each command with `--format json` and keep the raw output. All are
non-destructive. `permissions status` reveals whether Full Disk Access is
granted — note it, because several findings are undercounted without it.

```bash
"$BIN" version --format json
"$BIN" permissions status --format json
"$BIN" space --format json
"$BIN" space lens ~ --depth 2 --format json
"$BIN" modules list --format json
"$BIN" scan --format json                 # read-only: scans, never deletes
"$BIN" login-items list --format json
"$BIN" uninstall list --format json
"$BIN" ai scan --format json              # heuristic cache analysis (no --deep ⇒ no API key needed)
"$BIN" malware scan --format json
"$BIN" homebrew outdated --format json    # exits 0 with empty report if brew absent
```

Notes:
- `scan` emits `summary` (reclaimableBytes, score, totalFindings) and
  per-module `findings` with `recommended` flags — the recommended set is the
  safe-to-clean subset.
- `ai scan` without `--deep` is pure on-device heuristics; only add `--deep`
  if the user explicitly wants the LLM pass AND a key is set (the command
  exits 1 and notes the missing key otherwise — that is not a hard failure).
- Tolerate non-zero exits per command: capture the JSON and the exit code,
  and record errors rather than aborting the whole scan.

## Step 3 — write the machine profile

Create/overwrite `.agents/memory/local/machine-profile.md` with `last_verified`
set to today (YYYY-MM-DD). Summarize — do not paste raw JSON dumps. Keep paths
but trim to what is decision-relevant.

```markdown
---
last_verified: <YYYY-MM-DD>
source: macsweep <version> (scan-and-memorize skill)
status: temporary
---

# Machine profile

## Disk
- Volume: <used>/<total> (<used %> used, <free> free)
- Largest home dirs (space lens, depth 2): <top 5 dir → size>

## Permissions
- Full Disk Access: <granted|missing>  (if missing: findings are undercounted)
- Other module requirements: <module → missing reqs>

## Cleanup potential (read-only scan)
- Score: <score>
- Reclaimable: <bytes humanized>  across <totalFindings> findings
- Top recommended modules: <module → reclaimable>

## Installed apps (uninstall list)
- Count: <n>;  largest footprints: <app → size [leftovers]>

## Login items
- <n> total; enabled launch agents/daemons: <names>

## Caches (ai scan)
- <n> findings; notable: <category → path (size)>

## Malware scan
- Status: <clean|THREATS FOUND>;  XProtect: <status>

## Homebrew
- <all up to date | n outdated: pkg current→latest ...>
```

## Step 4 — write cleanup preferences

Create `.agents/memory/local/cleanup-prefs.md` only if it does not already
exist (do not clobber preferences the user has tuned). Seed it from what the
scan implies plus anything the user stated this session.

```markdown
---
last_verified: <YYYY-MM-DD>
status: temporary
---

# Cleanup preferences

## Defaults
- Always dry-run first; require explicit confirmation before `apply`.
- Auto-clean scope: recommended findings only.
- Modules to always include: <e.g. trash-bins, system-cache>
- Modules to never touch without asking: <e.g. mail-attachments, dev-tools>

## Observations from last scan
- <e.g. dev-tools caches dominate reclaimable space>

## User-stated rules
- <captured verbatim from the conversation, or "none yet">
```

## Step 5 — report back

Tell the user the headline numbers (reclaimable space, score, any threats or
outdated packages) and where the profile was written. Remind them it lives in
gitignored `.agents/memory/local/` and will refresh next time this skill runs.
Re-run whenever `last_verified` is older than ~30 days or after major cleanup.
