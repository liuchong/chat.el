# Streaming UX Diagnosis

- Type: log
- Attention: record
- Status: complete
- Scope: code-mode, request-panel, streaming
- Tags: streaming, request-panel, diagnosis, ux

## Summary

Checked the current code-mode streaming path after a user reported that the request panel felt stale and the conversation buffer did not reveal enough live progress.

## Findings

- request diagnostics record every stream chunk and keep phase, process liveness, and chunk counters current
- request panel refresh in code mode is primarily driven by response rendering and explicit hint paths, not by a diagnostics subscription on every trace update
- the panel shows transport liveness and chunk counters, but not a stronger live heartbeat or explicit last-chunk freshness indicator in the main visible summary
- the conversation buffer only renders user-visible streamed content and does not expose internal progress events unless tool events or approval states exist
- there is no explicit auto-follow window logic to keep the visible conversation window pinned to the latest streamed output

## Conclusion

The reported “not alive enough” feeling is mainly an implementation and UI surfacing problem, not a prompt problem. The backend is receiving stream chunks, but the current request panel and conversation rendering do not surface that progress with enough immediacy or confidence.
