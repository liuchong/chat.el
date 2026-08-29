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
- Standing context can leak across sibling paths or grow into a hidden prompt tax.
- Agent-authored notes can be mistaken for project instructions or verified facts.
- A plan can become prompt ceremony while the Agent acts outside its current item.
- Plan history can consume context or stale evidence can be repeated every turn.
- A platform sandbox API can disappear or change behavior after an OS update.
- Compiler shims can hide filesystem and environment requirements from argv inspection.
- A durable Goal can loop indefinitely, leak across project scope or be marked complete from model prose.
- Plan Mode can become prompt-only ceremony if a tool bypasses its execution-boundary effect gate.
- Inert staged drafts can be conflated with the executable runtime send queue, causing premature sends or lost input.

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
- Filter every fragment by canonical scope, preserve provenance and explain omissions.
- Keep Agent notes at Agent authority, label hypotheses and require revisions for updates.
- Gate governed tools on a scoped active plan with one dependency-ready current item.
- Project only the bounded active slice and evidence added after the prior revision.
- Probe isolation in the foreground at startup and report unavailable rather than falling back.
- Resolve measured tool shims to real binaries and derive SDK paths without widening write roots.
- Bound Goal continuation, preserve scope on every projection/mutation and require known scoped evidence for deterministic completion.
- Gate every tool call while Plan Mode is active, fail closed on unknown effects and bind approval to the exact submitted plan revision.
- Give stage items stable structured identity, require explicit `/send`, and clear only after the canonical turn is checkpointed and recorded.

## Governing Plan

See `programming-capability-reliability-plan.md` for the construction sequence,
test matrix and non-negotiable acceptance thresholds.
