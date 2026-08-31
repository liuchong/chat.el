#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/chat-eval-extended.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

if [ "$#" -eq 0 ]; then
  set -- zig clojure java typescript c cpp sql
fi

required_commands() {
  case "$1" in
    zig) echo "zig" ;;
    clojure) echo "lein" ;;
    java) echo "java javac" ;;
    typescript) echo "node tsc" ;;
    c) echo "clang" ;;
    cpp) echo "clang++" ;;
    sql) echo "sqlite3" ;;
    *) echo "unknown language: $1" >&2; return 2 ;;
  esac
}

missing=""
for language in "$@"; do
  for command in $(required_commands "$language"); do
    if ! command -v "$command" >/dev/null 2>&1; then
      missing="${missing}${missing:+, }$language:$command"
    fi
  done
done

if [ -n "$missing" ]; then
  echo "BLOCKED: unavailable toolchains: $missing" >&2
  exit 3
fi

for language in "$@"; do
  cp -R "$root/$language" "$work/$language"
  fixture="$work/$language"
  if ! (cd "$fixture" && sh test-one normalize); then
    echo "FAIL: $language normalize baseline does not compile and pass" >&2
    exit 1
  fi
  for test_name in divide label active; do
    if (cd "$fixture" && sh test-one "$test_name") >/dev/null 2>&1; then
      echo "FAIL: $language $test_name is missing its seeded defect" >&2
      exit 1
    fi
  done
  echo "PASS: $language fixture baseline and seeded defects are deterministic"
done
