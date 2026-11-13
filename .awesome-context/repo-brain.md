# Repo Brain

Generated at: 2026-11-13T09:08:10.571Z

## Cold-Start Instructions

This file is the persistent knowledge base for this repository.
Load this file at the start of any session — you do not need to scan, grep, or explore the repo to understand it.
The Module Catalog below tells you exactly what each source file exports and does.
Use `.awesome-context/ai-context.md` for rules, memory, workflows, and decisions.

## Module Catalog

## Architecture Data Flow

```
ace sync
  → graph.ts        generateGraphContext  — builds graph.json + cache.json (symbol/import graph)
  → indexer.ts      indexProject          — builds project-map.md + project-index.json
  → context-marks.ts markContextFiles     — writes @ace-dna headers, file-context.json, impact-map.json
  → memory.ts       buildMemoryContext    — loads items.json, guarantees rule/warning items surface
  → sync.ts         renderContext         — compresses all sources into ai-context.md
  → sync.ts         renderRepoBrain       — writes repo-brain.md (this file)
```

## Key Entry Points

- `src/cli.ts` — all `ace` CLI commands
- `src/index.ts` — public Node.js API surface
- `.awesome-context/ai-context.md` — agent context (read this first)
- `.awesome-context/repo-brain.md` — this file (full module map)
- `.awesome-context/memory/items.json` — persistent memory store