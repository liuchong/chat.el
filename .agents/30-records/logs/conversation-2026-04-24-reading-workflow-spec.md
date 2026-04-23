# Log Item

- Type: logs
- Attention: records
- Status: completed
- Scope: reading-workflow-spec
- Tags: spec, reading, navigation, code-mode, workflow

## Summary

Defined a new staged spec for the next major in-Emacs workflow: quoting the code the user is currently reading, asking AI about that code without manual copy/paste, and letting AI safely open related files inside Emacs.

### Technical Decisions

- Treated reading-context capture, file navigation, and session command discoverability as one workflow instead of three isolated features
- Kept the design Emacs-native and explicitly avoided widget-heavy UI or shell-driven navigation
- Chose an explicit `open_file(path, line, column)` tool contract over special-casing file navigation in response text parsing
- Chose visible quoted message text with file path and line range over hidden metadata-only context

### Completed Work

- Added `specs/003-reading-workflow-and-navigation.md`
- Updated `docs/README.md` to link the new spec
- Updated `.agents` entry and focus records to point at the new stage

### Verification

- Documentation-only stage
- No runtime code changed
- No regression tests were required for this stage

### Remaining

- Implement the first slice:
  - code-mode region quote and ask commands
  - safe `open_file` navigation tool
  - discoverability for regenerate and edit-resend commands
