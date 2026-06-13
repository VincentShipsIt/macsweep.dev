#!/usr/bin/env bash
#
# skills.sh — wire repo-local agent skills into every CLI's discovery path.
#
# Source of truth:  .agents/skills/<name>/SKILL.md   (committed)
# Discovery mirrors: .claude/skills/<name>  ->  ../../.agents/skills/<name>
#                    .codex/skills/<name>   ->  ../../.agents/skills/<name>
#
# The mirrors are per-skill *relative* symlinks, matching the global convention
# in ~/.claude/skills (each entry links back into ~/.agents/skills). They are
# regenerable, so they are gitignored — run `skills.sh sync` after cloning.
#
# Commands:
#   sync      Create/refresh symlinks for every source skill; prune broken/orphaned ones.
#   list      List the source skills under .agents/skills.
#   status    Show, per mirror, which skills are linked / missing / broken.
#   install   Ensure mirror dirs exist, then sync (alias for first-time setup).
#   help      This message.
#
# Never points `npx/bunx skills add` at the install dir — this manages symlinks
# directly and only ever deletes symlinks (never real skill content).

set -euo pipefail

# Resolve repo root from this script's location (scripts/ is one level down).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SRC_DIR="$REPO_ROOT/.agents/skills"
MIRRORS=(".claude/skills" ".codex/skills")
# Relative target from inside a mirror dir (<repo>/.claude/skills/<name>) back to
# the source: up to .claude, up to repo root, into .agents/skills/<name>.
REL_PREFIX="../../.agents/skills"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
warn() { printf '\033[33m%s\033[0m\n' "$1" >&2; }

ensure_src() {
  if [[ ! -d "$SRC_DIR" ]]; then
    warn "No source skills dir at .agents/skills — nothing to do."
    exit 0
  fi
}

# Echo each immediate subdirectory name of .agents/skills (handles spaces).
source_skill_names() {
  local entry
  for entry in "$SRC_DIR"/*/; do
    [[ -d "$entry" ]] || continue
    basename "$entry"
  done
}

cmd_list() {
  ensure_src
  bold "Source skills (.agents/skills):"
  local found=0 name
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    found=1
    if [[ -f "$SRC_DIR/$name/SKILL.md" ]]; then
      printf '  • %s\n' "$name"
    else
      printf '  • %s  (no SKILL.md)\n' "$name"
    fi
  done < <(source_skill_names)
  [[ "$found" -eq 0 ]] && printf '  (none)\n'
}

# Prune symlinks in a mirror dir whose target no longer resolves, or that point
# back into .agents/skills but no longer have a matching source (orphaned).
prune_mirror() {
  local mirror_abs="$1" link target base
  [[ -d "$mirror_abs" ]] || return 0
  for link in "$mirror_abs"/*; do
    [[ -L "$link" ]] || continue
    base="$(basename "$link")"
    if [[ ! -e "$link" ]]; then
      rm -f "$link"
      printf '  pruned (broken): %s\n' "$base"
    elif [[ ! -d "$SRC_DIR/$base" ]]; then
      target="$(readlink "$link")"
      if [[ "$target" == "$REL_PREFIX/"* ]]; then
        rm -f "$link"
        printf '  pruned (orphaned): %s\n' "$base"
      fi
    fi
  done
}

cmd_sync() {
  ensure_src
  local name
  for mirror in "${MIRRORS[@]}"; do
    local mirror_abs="$REPO_ROOT/$mirror"
    mkdir -p "$mirror_abs"
    bold "Syncing $mirror"
    prune_mirror "$mirror_abs"
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      local dest="$mirror_abs/$name"
      local want="$REL_PREFIX/$name"
      if [[ -L "$dest" ]]; then
        if [[ "$(readlink "$dest")" == "$want" ]]; then
          continue
        fi
        rm -f "$dest"
      elif [[ -e "$dest" ]]; then
        warn "  skip (real path, not a symlink): $name"
        continue
      fi
      ln -s "$want" "$dest"
      printf '  linked: %s\n' "$name"
    done < <(source_skill_names)
  done
}

cmd_status() {
  ensure_src
  for mirror in "${MIRRORS[@]}"; do
    local mirror_abs="$REPO_ROOT/$mirror"
    bold "$mirror"
    local name
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      local dest="$mirror_abs/$name"
      if [[ -L "$dest" && -e "$dest" ]]; then
        printf '  ✓ %s\n' "$name"
      elif [[ -L "$dest" ]]; then
        printf '  ✗ %s (broken link)\n' "$name"
      elif [[ -e "$dest" ]]; then
        printf '  ! %s (real path, not linked)\n' "$name"
      else
        printf '  · %s (missing — run sync)\n' "$name"
      fi
    done < <(source_skill_names)
  done
}

cmd_help() {
  sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

case "${1:-help}" in
  sync)    cmd_sync ;;
  list)    cmd_list ;;
  status)  cmd_status ;;
  install) cmd_sync ;;
  help|-h|--help) cmd_help ;;
  *) warn "Unknown command: ${1:-}"; cmd_help; exit 2 ;;
esac
