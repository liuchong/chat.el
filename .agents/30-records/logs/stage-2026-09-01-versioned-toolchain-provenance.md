# Versioned Toolchain Provenance

- Date: 2026-09-01
- Scope: M20 campaign preflight and immutable provenance
- Status: implementation complete; local extended toolchain still blocked

## Contract

Campaign schema v2 makes the local executable toolchain part of campaign
identity. Eval core derives the sorted union of manifest-declared hidden
dependencies and direct command-judge executables. Every name must resolve to
an absolute canonical path and have a registered, bounded, no-network version
probe.

The persisted `toolchain` entries contain `name`, invocation `path`, canonical
`target` and bounded `version` output. Probes execute the invocation path rather
than the canonical target so multi-call binaries retain their command identity.
Entries are included in `configurationDigest`, surfaced by runner preflight and
re-resolved on resume. Missing commands, unknown probes, timeout, probe failure,
path drift, target drift or version drift all fail before provider readiness or
trial scheduling. Campaign schema v1 records are intentionally not migrated or
resumed.

## Verification

- deterministic hidden-plus-direct dependency union: passed;
- real shell path/version capture: passed;
- unknown existing executable probe rejection: passed;
- bounded timeout and process cleanup: passed;
- descriptor persistence and configuration digest: passed;
- resume rejects version drift: passed;
- complete coding Eval unit suite: 53/53 passed;
- changed Lisp files byte-compiled successfully;
- canonical suite: 1,945/1,945 passed, zero skipped and zero unexpected;
- real extended preflight: blocked before provider use with missing `lein` and
  `tsc`, while all available probes completed successfully.

No model API request was made.

## Lessons

1. An executable path alone is insufficient campaign identity. Two machines or
   two runs can resolve the same name to behaviorally different versions.
2. A canonical target is not always a valid invocation path. Executing a
   `cargo` symlink through its `rustup` target changes dispatch and records the
   wrong tool version; both identities must be stored while probes use `path`.
3. Printing versions to the terminal is not durable evidence. The exact record
   must participate in the immutable configuration hash and resume comparison.
4. Probe support is an allowlist, not a best-effort `--version` guess. Tool
   command lines differ, and guessed flags can hang or produce false identity.
5. Version probes are processes with the same lifecycle obligations as judges:
   bounded wait, explicit termination and no surviving background process.
6. Environment readiness remains separate from mechanism correctness. The
   system now records versions correctly, but the seven-language gate cannot
   pass until deterministic `lein` and `tsc` executables are present.

## Next

Implement conservative project verification adapters for the seven extended
languages. Do not infer unsafe broad commands from a file suffix alone; require
an authoritative project marker or explicit `.chat-verification.json` entry.
