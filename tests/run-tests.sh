#!/bin/bash
# Run all chat.el tests

cd "$(dirname "$0")/.."

emacs -Q -batch \
  -l chat-session.el \
  -l chat-files.el \
  -l chat-llm.el \
  -l chat-llm-kimi.el \
  -l chat.el \
  -l tests/unit/test-helper.el \
  -l tests/unit/test-chat-session.el \
  -l tests/unit/test-chat-files.el \
  -l tests/unit/test-chat.el \
  -l tests/unit/test-chat-llm.el \
  -l tests/unit/test-chat-llm-kimi.el \
  -f ert-run-tests-batch-and-exit
