# Tool Menu Frozen Into Session State

- Type: logs
- Attention: records
- Status: complete
- Scope: capability-packs, session persistence
- Tags: advertised-tools, bounded-skip, work-plan, incident

## Summary

A coding session (PR work, `code-enabled`, no profile) lost every read tool
and `shell_execute` mid-run. The model could only manage the work plan, so it
looped on plan bookkeeping for dozens of turns, each real action refused as
"Tool ... is unavailable for this turn". The symptom survived restarts.

Root cause, two defects compounding:

1. `chat-capability--advertise-tools` (lisp/tools/chat-capability-packs.el)
   created an advertised menu for a session that had no tool contract at all
   (no `:enabled-tools`, no `:advertised-tools`): `current` fell back to the
   missing `enabled` and the union became only the tools one stage added.
   A session without a menu should see every registered tool; a menu that
   lists only the new stage hides everything else, because
   `chat-tool-caller--tool-advertised-p` refuses whatever a menu omits. The
   plan-create handler's advertise call was the trigger; later activations
   unioned in write and verification tools, freezing a 16-tool menu
   (plan lifecycle minus create, plus files_write/files_replace/files_patch/
   apply_patch, plus programming_verification_plan/run) -- exactly the set
   persisted in the polluted session file.

2. Session saving persisted `:advertised-tools` into `toolConfig`, so the
   transient menu became durable state and every reload restored the
   narrowing. Spec 022 names the menu transient execution-Session policy;
   persistence contradicted it.

## Changes

- `lisp/tools/chat-capability-packs.el`: advertise is a no-op unless the
  execution session carries a tool contract (`:enabled-tools` or
  `:advertised-tools`). Staging narrows a menu; it never invents one.
- `lisp/core/chat-session.el`: `chat-session--durable-tool-config` strips
  `:advertised-tools` in both serialization paths (JSONL state entry and
  legacy serializer) and again on load, so a polluted file heals on reopen.
- Tests: `chat-session-advertised-tool-menu-is-never-persisted`,
  `chat-capability-activation-leaves-a-menu-less-session-alone`; the two
  staging tests that built menu-less sessions now install the code profile
  contract first, because a contract-less narrow no longer exists.
- `docs/troubleshooting-pitfalls.md`: "A Narrowed Tool Menu Must Never
  Become Session State" under Tool Calling and Tool Forging.

## Verification

Full canonical suite 2073 tests, 2071 as expected, 2 skipped (environment),
0 unexpected. The polluted session file itself was the primary evidence:
its `toolConfig` carried exactly the 16-tool menu and `workPlans[].skip`
bookkeeping, with no `:enabled-tools` and no `:profile` anywhere.
