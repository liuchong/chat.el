# Risks

- Type: lessons
- Attention: active
- Status: active
- Scope: coding-agent-reliability
- Tags: risks, coding, evaluation, isolation, verification

## Current Risks

- Feature breadth can hide a lack of measured coding-task success.
- Live model evaluation can become noisy, expensive or accidentally model-specific.
- Existing regular-expression indexing can be mistaken for semantic certainty.
- LSP client internals can change and can block the Emacs main loop.
- Automatic verification can loop forever or expand the diff through formatting.
- A worktree can be mistaken for a filesystem or network sandbox.
- File content can drift between read, patch planning and commit.
- Review can produce plausible but ungrounded findings.
- Parallel coding agents can edit overlapping resources or merge against a stale base.

## Mitigations

- Freeze deterministic fixtures and judges before changing coding behavior.
- Report live Eval variance and keep it outside the canonical offline suite.
- Return backend provenance and distinguish unavailable from an empty result.
- Use public asynchronous APIs, bounded caches and explicit timeouts.
- Bound repair attempts and stop on an unchanged failure fingerprint or diff.
- Test backend capabilities instead of inferring isolation from its name.
- Bind every Agent write to a runtime-owned read observation and recheck before commit.
- Require typed findings with path, line, evidence and measured precision/recall.
- Declare child read/write resources, use owned worktrees and refuse conflicted merges.

## Governing Plan

See `programming-capability-reliability-plan.md` for the construction sequence,
test matrix and non-negotiable acceptance thresholds.
