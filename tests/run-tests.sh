#!/bin/bash
# Run all chat.el tests

cd "$(dirname "$0")/.."

emacs -Q -batch \
  -l chat-session.el \
  -l chat-files.el \
  -l chat-llm.el \
  -l chat-llm-kimi.el \
  -l chat-llm-openai.el \
  -l chat-stream.el \
  -l chat-ui.el \
  -l chat-tool-forge.el \
  -l chat.el \
  -l tests/unit/test-helper.el \
  -l tests/unit/test-chat-session.el \
  -l tests/unit/test-chat-files.el \
  -l tests/unit/test-chat-llm.el \
  -l tests/unit/test-chat-llm-kimi.el \
  -l tests/unit/test-chat-llm-openai.el \
  -l tests/unit/test-chat-ui.el \
  -l tests/unit/test-chat-stream.el \
  -l tests/unit/test-chat-tool-forge.el \
  -f ert-run-tests-batch-and-exit
