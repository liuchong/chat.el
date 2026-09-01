# Official Clojure CLI Toolchain Closure

- Type: stage-record
- Attention: reference
- Status: complete
- Scope: M20 toolchain and corpus authority
- Date: 2026-09-01

## Outcome

M20 no longer depends on Lein. The only Clojure evaluation toolchain is the
official `clojure` executable. TypeScript and Clojure now both pass versioned
campaign preflight, the all-seven fixture gate is closed, and no provider
request was used for this stage.

## Design Change

- Replaced `project.clj` with a dependency-free `deps.edn` project.
- Added a checked-in `clojure.test` runner that resolves one named test var and
  returns deterministic process status.
- Fixed the judge command to `clojure -Srepro -M:test NAME`, excluding user
  aliases and dependencies.
- Bumped the six Clojure task revisions and fixture identity because the
  executable contract changed.
- Removed automatic `project.clj` inference from product verification. Generic
  projects use the existing structured `.chat-verification.json` authority;
  arbitrary `deps.edn` content is not guessed or parsed as a test command.
- Removed obsolete generated paths and retained only `.cpcache` for Clojure.

There is no dual path, fallback, migration or compatibility branch.

## Toolchain Evidence

- TypeScript invocation: `/opt/homebrew/bin/tsc`
- TypeScript target: Homebrew TypeScript 7.0.2 executable
- Clojure invocation: `/opt/homebrew/bin/clojure`
- Clojure target: Homebrew Clojure CLI 1.12.5.1664 executable
- Full manifest digest:
  `1c8cf84e4faa09b074503ff61ed986f7754cecfe87ab7177c2998d86c67fe1f4`
- Preflight configuration digest:
  `3f701fd0ae857650855a1408858f431580bff4300ad4e0404367bbdb62676243`

The campaign runner reproduced this evidence after replacing `HOME` with an
isolated temporary directory. The Clojure CLI created only its small config
files there; the fixture needs no downloaded project or test dependency.

## Verification

- focused Clojure and TypeScript fixture gate: 2/2 languages passed;
- all-seven baseline plus three seeded defects per language: 7/7 passed;
- isolated 42-task campaign descriptor preflight: passed before provider setup;
- focused subset identity tests: 7/7 passed;
- canonical suite: 2009/2009 passed, zero skipped and zero unexpected;
- copied fixture roots and isolated runtime homes: removed;
- repository fixture directories contain no generated `.cpcache`, compiler
  output or campaign evidence.

The first canonical run correctly failed two subset identity assertions after
the manifest task revision changed. The focused and combined smoke manifests
were brought back to the same canonical task records; the tests were not
weakened. Their stable corpus IDs remain unchanged because the manifest digest
and task revisions already carry the exact configuration change.

## Next

Run the TypeScript and Clojure mutation smoke independently against exact
DeepSeek `deepseek-v4-flash` and Kimi Code `k3-256k`. Only after all four cells
pass may the separate complete repeated 42-task campaigns begin.
