# Stage Record: Structured MDP Tool Results

## Outcome

Structured local tool results now complete the MDP round trip. Elisp plists,
alists, hash tables, vectors and arrays are normalized into the protocol's
ordered value model and encoded as canonical MDP. Strings stay unchanged.
Unsupported, circular, over-deep, over-size and duplicate-key values fail back
to the existing readable tool-result path.

The format is explicit rather than inferred from punctuation. A result marked
as MDP retains that identity when an Evidence ID is prefixed, when the Agent
creates the `:tool` message, across session persistence, and when the transcript
projects the message for display. The provider wire remains a native tool-role
message whose content is the same MDP string.

The UI does not own another table or list renderer. An expanded MDP tool result
is passed to the shared Markdown document renderer at column zero, preserving
the established absolute-column and CJK table alignment behavior.

Character truncation is a format boundary. When the general tool-result budget
cuts a payload, the retained text keeps its omission marker but loses MDP format
identity, so an incomplete document cannot be persisted or rendered as valid
structure.

## Verification

- MDP and tool caller focused coverage: 110/110 before cross-layer integration
- MDP codec coverage after array and duplicate-key hardening: 51/51
- Agent, session, transcript, UI, MDP and tool-caller integration: 294/294
- Agent coverage after truncation hardening: 69/69
- Canonical suite: 2008/2008, zero skipped and zero unexpected

The first canonical invocation inherited a PATH without the existing
`/Users/liu/.cargo/bin` toolchain and therefore skipped two Rust isolation
tests before execution. Re-running with that existing path exposed made both
tests execute and pass; the skip-only run is not acceptance evidence.

## Lessons

1. Structured data needs an explicit format tag. Guessing from text would make
   ordinary tool output accidentally enter the protocol renderer.
2. Evidence prose can coexist with MDP because prose is a protocol comment, but
   string transformations must deliberately preserve the format tag.
3. A list of plists is an array of objects, not an alist. Container recognition
   order is part of the codec contract and needs a regression test.
4. Renderer reuse includes coordinate assumptions. Keeping MDP documents at
   column zero avoids invalidating the table alignment already accepted in the
   chat surface.
5. Isolated ERT files that depend on configured providers must load the standard
   provider fixture; otherwise `Unknown provider` failures never reach the code
   under test and cannot be treated as product evidence.
6. A format tag describes a complete contract, not the prefix that survived a
   character limit. Truncation must invalidate structured identity.
