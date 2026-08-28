# Capability-Tested Execution Isolation

- Type: record
- Attention: reference
- Status: complete
- Scope: coding-agent-reliability
- Tags: execution, sandbox, capability, network, cleanup

## Result

M15 upgrades execution records to schema v2 and separates policy requirements
from backend capability facts. Darwin now has measured `inspect`, `build` and
approved `networked-build` enforcement. Shell, background task and verification
adapters use those policies; explicit local remains unrestricted.

## Evidence

- foreground probe: filesystem `scoped`, network `controlled`, environment
  `explicit`, timeout true, process-tree cleanup true, availability `available`;
- project-external read, parent write, symlink escape, default bind and undeclared
  environment access were blocked;
- project write, Clang compile/run and approved socket bind completed;
- timeout and cancellation killed a spawned `sleep 30` child process group;
- backend mismatch created no execution record or process;
- start-preparation fault injection left no temporary directory;
- v1 durable data migrated to explicit local policy;
- execution isolation tests passed 16/16 and adapter tests passed 47/47.

## Lessons

- Canonicalize `/var` through `file-truename`; Darwin policy paths use `/private/var`.
- Emacs pipe subprocesses are process-group leaders, so negative PID signals cover descendants.
- A nil `run-at-time` delay means immediate execution; optional backend timeout needs an explicit guard.
- Put temporary-root creation inside the same error boundary as argv, profile and environment preparation.
- Apple developer commands are shared shims. Resolve real Xcode tools and derive SDKROOT instead of granting shim cache writes outside the project.
- Give restricted processes a private HOME; denying a real HOME while still advertising it makes ordinary tools fail rather than protecting it cleanly.

## Verification Commands

```sh
/Users/liu/projects/.agent-tools/capped.sh 256 emacs -Q -batch -L . -L tests/spike -l chat.el -l tests/spike/probe-execution-isolation.el
emacs -Q -batch -L . -L tests/unit -l chat.el -l tests/unit/test-chat-execution.el -l tests/unit/test-chat-execution-isolation.el --eval '(ert-run-tests-batch-and-exit "^chat-execution")'
emacs -Q -batch -L . -L tests/unit -l chat.el -l tests/unit/test-chat-tool-shell.el -l tests/unit/test-chat-work.el -l tests/unit/test-chat-code-verify.el --eval '(ert-run-tests-batch-and-exit "\\`\\(chat-tool-shell\\|chat-work\\|chat-code-verify\\)")'
```

The canonical suite passed 1,666/1,666 with zero unexpected results. No
background service was started; final process, listener and sandbox
temporary-root scans were empty.
