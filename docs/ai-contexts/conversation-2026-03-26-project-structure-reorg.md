# Project Structure Reorg
## Requirements
Reorganize the repository into a clearer long term structure for runtime source, tests, scripts, and design documents.
Keep `chat.el` as the single root entry point.
Make the new layout work with the existing batch test flow.
## Technical Decisions
Use `lisp/` instead of `src/` because the project is primarily Emacs Lisp.
Split runtime modules into `lisp/core`, `lisp/llm`, `lisp/tools`, `lisp/ui`, and `lisp/code`.
Keep `chat.el` at the repository root and switch it from root local `load` calls to `load-path` setup plus `require`.
Use `tests/test-paths.el` as the shared bootstrap for unit tests, prototypes, and manual scripts.
Keep `tests/run-tests.el` as the canonical runner and reduce `tests/run-tests.sh` to a thin wrapper.
## Completed Work
Moved all runtime `chat-*.el` modules into the new `lisp/` domain directories.
Updated `chat.el` to register the new module directories in `load-path` and require modules from there.
Moved loose root tests into `tests/unit` and `tests/manual`.
Moved migration scripts into `scripts/migration`.
Moved `DESIGN.md` and `DESIGN_GAP_ANALYSIS.md` into `docs/architecture`.
Added `tests/test-paths.el` and updated prototypes plus manual scripts to use it.
Updated `tests/run-tests.el` and `tests/run-tests.sh` to use the new bootstrap flow.
Stabilized the streaming timer unit test by stubbing `run-with-idle-timer` instead of depending on batch idle execution.
Updated `docs/troubleshooting-pitfalls.md` and `docs/PROJECT_STATUS.md`.
Updated `README.md` to describe the new `lisp/` layout, refresh the architecture map and test baseline, and merge duplicate license text into one final section.
Updated `docs/index.html` and `docs/pages/docs.html` so the static documentation site matches the reorganized `lisp/` layout, current test baseline, and actual chat send key.
## Pending Work
Decide whether `scripts/maintenance/` needs initial checked in helpers or should remain empty until needed.
## Key Code Paths
`chat.el`
`tests/test-paths.el`
`tests/run-tests.el`
`lisp/core/chat-session.el`
`lisp/llm/chat-llm.el`
`lisp/tools/chat-tool-caller.el`
`lisp/ui/chat-ui.el`
`lisp/code/chat-code.el`
## Verification
Ran `emacs -Q -batch -l tests/run-tests.el`.
Read lints for `chat.el`, `tests/`, and `scripts/migration/`.
Confirmed runtime modules no longer live in the repository root.
Read back `README.md` to confirm the project layout, architecture map, and test baseline match the new structure.
Read back the static docs pages to confirm old root-level module paths, the `122/120` test baseline, and the stale `C-c C-c` send instruction were removed.
## Issues Encountered
Batch mode does not reliably execute `run-with-idle-timer`, so the migrated streaming timer test failed when it was promoted into `tests/unit`.
Added a troubleshooting entry and rewrote the test to assert on the captured callback closure instead of waiting for real idle execution.
