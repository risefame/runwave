# Project Map

Generated at: 2026-11-13T07:14:45.150Z

## Repository Snapshot
- Total files: 29
- Total directories: 9
- Truncated scan: no

## Repository Identity
- Root package: runwave-web-prototype
- README summary: none detected
- Workspace packages: 1
- Direct dependencies indexed: 11

## Browse First
- Inspect entrypoint: web/src/main.ts
- Inspect config: web/vite.config.ts
- Browse directory: web/ (17 files)
- Browse directory: supabase/ (9 files)
- Browse directory: .gitignore/ (1 files)
- Build command: web#build
- Test command: web#test

## Workspace Packages
- web -> runwave-web-prototype

## Auxiliary Packages
- none detected

## Folder Tree (max depth 3)

```text
.
├── supabase/
│   ├── migrations/
│   │   ├── 0001_schema.sql
│   │   ├── 0002_rls.sql
│   │   ├── 0003_functions.sql
│   │   └── 0004_api.sql
│   ├── tests/
│   │   ├── 00_auth_stub.sql
│   │   └── game_test.sql
│   ├── README.md
│   ├── seed.sql
│   └── setup.sql
├── web/
│   ├── public/
│   │   ├── icons/
│   │   └── manifest.webmanifest
│   ├── screenshots/
│   ├── src/
│   │   ├── map/
│   │   ├── gpsFilter.test.ts
│   │   ├── gpsFilter.ts
│   │   ├── main.ts
│   │   ├── online.ts
│   │   ├── style.css
│   │   ├── supabase.ts
│   │   ├── territory.test.ts
│   │   └── territory.ts
│   ├── index.html
│   ├── package.json
│   ├── tsconfig.json
│   ├── vite.config.ts
│   └── wrangler.jsonc
├── .gitignore
├── AGENTS.md
└── README.md
```

## Detected Languages
- TypeScript: 10
- SQL: 8
- JSON: 3
- Markdown: 3
- CSS: 1
- HTML: 1

## Detected Frameworks
- none

## Package Scripts
- web#build: tsc --noEmit && vite build
- web#dev: vite
- web#preview: vite preview
- web#test: vitest run
- web#typecheck: tsc --noEmit

## Important Config Files
- web/vite.config.ts

## Test Commands
- web#test: vitest run

## Build Commands
- web#build: tsc --noEmit && vite build

## Entrypoints
- web/src/main.ts

## Auxiliary Entrypoints
- none detected

## Key Directories
- web/: 17 files
- supabase/: 9 files
- .gitignore/: 1 files
- AGENTS.md/: 1 files
- README.md/: 1 files

## Auxiliary Paths
- none detected

## Dependency Highlights
- @supabase/supabase-js
- @turf/area
- @turf/center-of-mass
- @turf/difference
- @turf/length
- @turf/union
- @types/geojson
- maplibre-gl
- typescript
- vite
- vitest
