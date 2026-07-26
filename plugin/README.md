# plugin/

Claude Code plugin payload for unimatrix (P1-FR1/FR2 — wired into `check.sh`).

This directory **is the plugin root** (spec 17 open question 1, resolved empirically — see below):
the marketplace entry sources `./plugin`, so Claude Code discovers `plugin/.claude-plugin/plugin.json`
plus the conventional `commands/` and `skills/` subdirectories directly under here.

- **Manifests**: `plugin/.claude-plugin/plugin.json` is the plugin manifest. The repo-root
  `.claude-plugin/marketplace.json` is the self-marketplace anchor (it has to live at the repo root
  for `/plugin marketplace add <repo path>` to find it) and its one `plugins[]` entry points
  `"source": "./plugin"` at this directory. There is no root-level `plugin.json` any more — it moved
  here.
- **Generated**: `plugin/commands/*.md` — one ≤3-line pointer stub per `.claude/commands/u-*.md`,
  produced by `gen-commands.sh`. Never hand-edit; regenerate instead. `check.sh` regenerates into a
  temp dir and diffs against what's committed here — a mismatch fails the gate.
- **Canonical**: `.claude/commands/u-*.md` — the real command body a stub points to, read via
  `$UNIMATRIX_HOME` at invocation time.
- **Skill**: `plugin/skills/unimatrix/SKILL.md` is a relative symlink to the repo's canonical
  `.claude/skills/unimatrix/SKILL.md` (same zero-duplication pattern P0-FR2 already uses for the
  7 account copies) — one file, one source of truth, shipped through the plugin's conventional
  `skills/<name>/SKILL.md` discovery path. No explicit `"skills"` field in `plugin.json`: local
  precedent (`frontend-design`, `skill-creator`, `cloudflare` — all installed and enabled on this
  box) ships skills via the convention directory alone, no manifest field.
- **Versioning**: `plugin.json`'s `version` mirrors the newest `## [x.y.z]` release heading in
  `CHANGELOG.md`. It is bumped in the same commit as that changelog entry — **the release
  checklist (`docs/releasing.md`) now owns this bump**, not an ad hoc edit here. Currently `1.1.0`,
  matching the newest cut release.
- **D3**: `marketplace.json` is directory-sourced (`source: "."` at the repo root, `./plugin` for
  the plugin itself) — instant iteration, no publish step. Switches to GitHub-sourced at the first
  stable release after the plugin has settled.
