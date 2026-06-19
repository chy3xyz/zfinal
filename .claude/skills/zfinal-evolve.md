---
name: zfinal-evolve
description: Use when evolving the ZFinal framework itself — bumping versions, writing CHANGELOG entries, updating AGENTS.md, retiring deprecated APIs, or planning major version bumps. Triggers on phrases like "升级版本", "发布新版本", "废弃", "deprecated", "AGENTS.md", "CHANGELOG", or when working across multiple modules and the question "should this be a patch/minor/major release?"
---

# ZFinal Evolve Skill

> **Process skill for evolving the ZFinal framework.**

When you're an AI agent working on the ZFinal codebase and the task involves
version bumps, API deprecation, or cross-cutting documentation updates,
this skill gives you the playbook.

---

## 1. When to bump what

### SemVer decision tree

```
Change affects:
├─ Only fixes an existing bug, no API change
│   → PATCH bump (0.10.6 → 0.10.7)
├─ Adds new feature, new plugin, new skill, new codegen flag
│   → MINOR bump (0.10.9 → 0.11.0)
├─ Changes existing API signature, removes deprecated function,
│  or changes behavior that requires user code edits
│   → MAJOR bump (1.0 → 2.0)
└─ Internal refactor only (no user-visible change)
    → NO version bump, but commit with `refactor:` prefix
```

### When in doubt

Ask: "Would a user with an existing project need to edit their code
to keep building after this change?"

- **No** → PATCH
- **Yes, but new optional stuff** → MINOR
- **Yes, breaking** → MAJOR

---

## 2. Release checklist (every release)

Before tagging a version, complete these steps:

### 2.1 Code

- [ ] `zig build` passes
- [ ] `zig build test` (or `zig build test-zf`) passes
- [ ] No `@deprecated` symbols introduced without a release note
- [ ] No new compiler warnings

### 2.2 Documentation

- [ ] `CHANGELOG.md` entry under new version, format:
      ```
      ## [X.Y.Z] - YYYY-MM-DD

      ### Added
      - ...

      ### Fixed
      - ...

      ### Changed
      - ...
      ```
- [ ] If API changed: `AGENTS.md` examples reflect new API
- [ ] If new AI workflow: skill in `.claude/skills/`
- [ ] If new dependency: `build.zig.zon` updated with hash

### 2.3 Release

- [ ] `git tag -a vX.Y.Z -m "Release vX.Y.Z: short summary"`
- [ ] `git push origin main && git push origin vX.Y.Z`
- [ ] `gh release create vX.Y.Z --title "vX.Y.Z — title" --notes "..."`

### 2.4 Audit (after release)

- [ ] Update `PRODUCTION_AUDIT.md` if production-relevant
- [ ] If breaking change: add migration guide to `doc/`

---

## 3. AGENTS.md update triggers

Update `AGENTS.md` whenever:

| Trigger | What to add/update |
|---------|--------------------|
| New `zf` command | Add to "▶️ START" flow section |
| New ai-edit-zone | Add to "📂 EDIT ZONE" list |
| New skill | Mention in opening paragraph |
| New architecture layer | Update "🏗️ Architecture" diagram |
| Deprecated API | Move from ❌ NEVER to "❌ DEPRECATED" |

---

## 4. Deprecation workflow

When removing an API:

```zig
// Step 1: Mark deprecated
pub const oldFunc = struct {
    pub fn call(...) ... {
        @deprecated("oldFunc is deprecated, use newFunc instead. See CHANGELOG vX.Y.Z");
        return newFunc.call(...);
    }
};
```

```zig
// Step 2: Release minor with deprecation note (CHANGELOG)
### Deprecated
- `oldFunc` — use `newFunc` instead. Will be removed in v(N+1).0.0.
```

```zig
// Step 3: Release major with removal
pub const oldFunc = void; // removed in v(N+1).0.0 — see migration guide
```

CHANGELOG entry:
```
### Removed
- `oldFunc` (deprecated since vX.Y.Z)
```

---

## 5. Cross-cutting refactor checklist

When refactoring across multiple modules (e.g. changing pool API):

1. **Find all call sites**:
   ```bash
   grep -rn "oldPool.init" src/ examples/ tools/
   ```

2. **Plan migration order**:
   - Framework code first (works internally)
   - Examples second (template for users)
   - Tools last (codegen must produce new pattern)

3. **Add self-heal**:
   - If old pattern is common, add `zf check --heal` patcher
   - Document in `zfinal-debug` skill

4. **Run codegen regression tests**:
   ```bash
   zig build test-zf
   ```

5. **Verify idempotency**:
   ```bash
   zig build
   ./zig-out/bin/zf check --heal  # should say "0 files patched"
   ```

---

## 6. Skill maintenance

Skills are living documents. When to update:

| Trigger | Update |
|---------|--------|
| New error type | Add to `zfinal-debug.md` lookup table |
| New `zf` flag | Add to `zfinal-ai-playbook.md` |
| New plugin | Add to `zfinal-framework.md` |
| New architectural decision | Add to `zfinal-onboarding.md` |
| New release | Add summary to `zfinal-evolution.md` |

When updating a skill:
- Update the YAML frontmatter `description` (used for discovery)
- Add concrete examples (not just descriptions)
- Keep table-of-contents in sync

---

## 7. Common anti-patterns

❌ **Don't**:
- Bump MAJOR for cosmetic changes
- Skip CHANGELOG "for small fixes"
- Add new feature without updating AGENTS.md
- Add skill without YAML frontmatter
- Tag without `git push` first

✅ **Do**:
- Use conventional commits (`feat:`, `fix:`, `refactor:`, `docs:`)
- Reference issue numbers in commit bodies when applicable
- Link releases to milestone in CHANGELOG
- Add `@deprecated` markers in same commit as replacement

---

## 8. Quick templates

### Commit message
```
feat(scope): short summary

Longer explanation if needed. Reference issue #123.

Body paragraph explaining the change.
```

### CHANGELOG entry
```
## [X.Y.Z] - YYYY-MM-DD

### Added
- **`feature`**: one-line description. Use case / example.

### Fixed
- **bug-name**: root cause + fix summary.

### Changed
- `api`: signature change. Migration: `old()` → `new()`.
```

### Release notes
```
### Added
- feature description

### Fixed
- bug description

Full changelog: <url>
```

---

## 9. Self-check before release

Run through this list:

1. ✓ `zig build` clean
2. ✓ `zf check --heal` clean (idempotent)
3. ✓ `zf check --ai-zones` lists known editable zones
4. ✓ CHANGELOG entry under new version
5. ✓ Tag + push + gh release created
6. ✓ No new `@deprecated` without CHANGELOG note
7. ✓ All skill YAML descriptions mention trigger conditions

If any box unchecked, do not tag.