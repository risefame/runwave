# Project Map

Generated at: 2026-11-13T08:52:38.112Z

## Repository Snapshot
- Total files: 103
- Total directories: 98
- Truncated scan: no

## Repository Identity
- Root package: runwave-web-prototype
- README summary: none detected
- Workspace packages: 1
- Direct dependencies indexed: 17

## Browse First
- Inspect entrypoint: web/src/main.ts
- Inspect config: web/capacitor.config.ts
- Inspect config: web/vite.config.ts
- Browse directory: web/ (89 files)
- Browse directory: supabase/ (9 files)
- Browse directory: .github/ (2 files)
- Build command: web#build
- Test command: web#test

## Workspace Packages
- web -> runwave-web-prototype

## Auxiliary Packages
- none detected

## Folder Tree (max depth 3)

```text
.
├── .github/
│   └── workflows/
│       ├── android.yml
│       └── ios.yml
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
│   ├── android/
│   │   ├── app/
│   │   ├── capacitor-cordova-android-plugins/
│   │   ├── gradle/
│   │   ├── .gitignore
│   │   ├── build.gradle
│   │   ├── capacitor.settings.gradle
│   │   ├── gradle.properties
│   │   ├── gradlew
│   │   ├── gradlew.bat
│   │   ├── settings.gradle
│   │   └── variables.gradle
│   ├── ios/
│   │   ├── App/
│   │   ├── capacitor-cordova-ios-plugins/
│   │   ├── .gitignore
│   │   └── debug.xcconfig
│   ├── public/
│   │   ├── icons/
│   │   └── manifest.webmanifest
│   ├── resources/
│   ├── screenshots/
│   ├── src/
│   │   ├── map/
│   │   ├── geolocation.ts
│   │   ├── gpsFilter.test.ts
│   │   ├── gpsFilter.ts
│   │   ├── main.ts
│   │   ├── online.ts
│   │   ├── style.css
│   │   ├── supabase.ts
│   │   ├── territory.test.ts
│   │   └── territory.ts
│   ├── capacitor.config.ts
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
- XML: 13
- TypeScript: 12
- JSON: 9
- JavaScript: 8
- SQL: 8
- Markdown: 4
- Swift: 4
- CSS: 3
- HTML: 3
- Java: 3
- YAML: 2

## Detected Frameworks
- none

## Package Scripts
- web#build: tsc --noEmit && vite build
- web#cap:sync: npm run build && npx cap sync
- web#dev: vite
- web#preview: vite preview
- web#test: vitest run
- web#typecheck: tsc --noEmit

## Important Config Files
- web/capacitor.config.ts
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
- web/: 89 files
- supabase/: 9 files
- .github/: 2 files
- .gitignore/: 1 files
- AGENTS.md/: 1 files
- README.md/: 1 files

## Auxiliary Paths
- none detected

## Dependency Highlights
- @capacitor/android
- @capacitor/assets
- @capacitor/cli
- @capacitor/core
- @capacitor/ios
- @capgo/background-geolocation
- @supabase/supabase-js
- @turf/area
- @turf/center-of-mass
- @turf/difference
- @turf/length
- @turf/union
- @types/geojson
- maplibre-gl
