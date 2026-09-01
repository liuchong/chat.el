# Visiting Buffer Mutation Consistency

- Type: stage-record
- Attention: reference
- Status: complete
- Scope: M10 reliability repair discovered during M20 development campaign
- Date: 2026-09-01

## Incident

DeepSeek campaign `m20-dev-baseline-deepseek-952f90f-r3` completed 39 of 126
trials without a product failure. C, Clojure, C++, Java, SQL and TypeScript were
all 6/6; Zig failing-test, locate and multi-file were 3/3. During the first
`coding/zig-refactor` repetition, Emacs repeatedly asked whether to edit
`sample.zig` because it had changed on disk. A batch campaign cannot answer an
interactive supersession prompt, so the run was stopped before timeout.

The 39 immutable results remain useful development evidence. The campaign is
incomplete, has no completion record and cannot be resumed after the product
revision changes. It must not enter final success-rate aggregation.

## Root Cause

`open_file` reconciled a clean visiting buffer with disk before opening it.
Direct mutations separately wrote through temporary buffers and refreshed the
run-local file observation, but returned while an existing visiting buffer
could still hold the pre-write content and visited-file modtime. Any later
buffer edit could therefore enter Emacs' interactive supersession path.

The same gap existed in write, replace, insert, legacy patch, transactional
patch and the older high-level edit API. It was not Zig-specific and could not
be fixed by changing one fixture, prompt or model policy.

## System Contract

1. Before any direct mutation, reconcile the canonical path's clean visiting
   buffer and reject every buffer with unsaved modifications as `stale-file`.
2. The dirty-buffer refusal applies even when run-local read-set enforcement is
   not active; user edits are never an optional consistency mode.
3. After a successful disk mutation and observation refresh, silently revert
   the clean visiting buffer before reporting success.
4. Multi-file `apply_patch` performs the dirty-buffer check for its complete
   path set before the first write, then synchronizes every committed path.
5. The high-level edit and undo paths reuse the same shared boundary.
6. No mutation path asks an interactive question, discards user edits or leaves
   a successful result paired with stale buffer contents.

## Deterministic Evidence

- five direct mutation shapes keep an open buffer synchronized and allow an
  immediate local edit without `yes-or-no`, `y-or-n` or supersession callbacks;
- write, replace, insert and legacy patch reject unsaved buffers without
  read-set mode and keep disk content unchanged;
- transactional patch rejects an unsaved target before its first write;
- high-level edit refuses the mutation before creating a backup;
- focused file/edit regression: 167/167 passed;
- canonical suite: 2014/2014 passed, zero skipped and unexpected.

## Replay Rule

Run the canonical suite on the completed implementation, commit it, and start a
fresh 42-task-by-three campaign for each exact provider/model. Do not resume or
pool the 39-result incident campaign. If the prompt reappears, stop immediately
and capture the exact tool sequence before any further model sampling.

## Live Regression Closure

Clean revision `de0f6afbeb4d657737331b753cca6b2a601be865` completed fresh
DeepSeek campaign `m20-dev-baseline-deepseek-de0f6af-r1` against manifest
digest `fecacb185cd4b2d95c30f8fd62ff1e21ecae28731628fcf0045499390c7e0de0`.
The immutable matrix contains 126 unique task/repetition identities: 42 tasks,
three repetitions and 18 results for each of C, Clojure, C++, Java, SQL,
TypeScript and Zig.

All 126 trials passed. Every normalized model request used exact identity
`deepseek/deepseek-v4-flash`; failed checks, out-of-scope final files,
unfinished work plans, executor failures, provider retry attempts and unclean
workspaces were all zero. In particular, `zig-refactor` passed in all three
independent workspaces without a supersession prompt. The campaign completed
without a running lock or owned process.

Request count was 3--19 per task with median 10 and total 1,260. Task duration
was 5.072--71.246 seconds with median 19.679 seconds and total 3,004.935
seconds. These efficiency measurements are development evidence for later
model-policy tuning; they do not weaken the common correctness contract and do
not replace the final five-repetition baseline/current campaigns.
