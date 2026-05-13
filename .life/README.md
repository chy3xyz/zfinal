# .life — Project Evolution Memory

This directory is **project hippocampus**. Records every significant change, decision, and milestone. AI agents read this first to understand project history, context, and direction.

## How AI Uses This

1. **On session start**: Read `dna.json` for current state + `evolution.md` for recent changes
2. **On major change**: Write to `evolution.md` + update `dna.json`
3. **On milestone**: Generate fingerprint in `fingerprints/`
4. **On architecture decision**: Add ADR in `decisions/`

## Structure

```
.life/
├── README.md          ← You are here
├── dna.json           ← Project identity, current fingerprint, metrics
├── evolution.md       ← Chronological journal of ALL significant changes
├── fingerprints/      ← Immutable milestone snapshots
│   └── v0.X.0.json
├── decisions/         ← Architecture Decision Records (ADR)
│   └── NNN-title.md
└── memory/            ← AI session summaries (key insights, decisions made)
    └── YYYY-MM-DD-topic.md
```

## Principles

- **Write for future AI, not future humans.** Include context, reasoning, alternatives considered.
- **Every fingerprint is immutable.** Never modify old fingerprints — create new ones.
- **Evolution journal is chronological.** Append, never reorder.
- **Decisions are numbered.** Use ADR format: title, context, decision, consequences.
