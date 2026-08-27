# Stage: Hooks, Skills And Agent Profiles

- Type: logs
- Attention: records
- Status: complete
- Scope: agent-runtime
- Tags: hooks, skills, profiles, trust, composition, authority

Date: 2026-08-28
Spec: 014, 015
Decision: 0021

## Result

M3 adds one trusted extension layer above the M1 event bus and M2 model facts.
Named runtime hooks, lazy declarative skills and resolved custom-agent profiles
all feed the existing agent loop. Project declarations are inactive until their
root is trusted, and every resolved file source carries provenance and a
content digest.

Profiles compose instructions, model preferences, skills, tool overlays,
approval and limits before dispatch. The effective configuration is projected
into a transient execution session, leaving prior messages and durable history
unchanged. A bounded `profile-resolved` event records enough of the resolution
to inspect which behavior actually ran.

## Correctness Details

- Hook blockers use lifecycle ordering and fail-closed timeout behavior;
  observers remain isolated.
- Plugin-owned runtime hooks are restored or removed by normal plugin rollback.
- Skill and profile discovery indexes paths without reading manifest bodies.
- Declarative readers reject oversized, malformed and future-schema data and
  do not evaluate it.
- Trusted project manifests outrank user manifests; explicit declarations have
  the highest precedence.
- Parent profile cycles fail with a provenance-bearing error.
- Tool allowlists only intersect, disabled tools only accumulate and skill tool
  requests cannot escape the effective authority.
- Approval can stay equal or become stricter, never weaker.
- Known model capability conflicts fail before a transport request is created.
- Profile-specific subagent depth tightens the global limit.
- Selecting or clearing a profile preserves unrelated session overlays.
- Context-budget and background values are resolved and recorded but await the
  task and context stages for runtime enforcement.

## Verification

The focused extension suite passes 36/36 and the canonical suite passes
1430/1430, both with zero unexpected results. Tests cover hooks, plugin
rollback, trust boundaries, lazy skill loading, schema rejection, profile
precedence and inheritance, capability preflight, authority and approval
monotonicity, session selection, subagent limits and reproducible run
snapshots. All touched Lisp files pass `check-parens` and byte compilation;
the compiler reports only established repository warnings.

No background service was started. Test processes ran in the foreground under
the repository memory cap.

## Next Stage

M4 replaces the separate foreground, background, workflow and delegated work
state machines with one durable `chat-task` contract and a bounded scheduler.
