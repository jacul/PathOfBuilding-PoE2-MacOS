#!/usr/bin/env bash
# Syntax/lint checks for every macOS script: shell (bash -n, plus shellcheck if
# installed) and Lua (luajit bytecode compile).
set -uo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fail=0

echo "shell syntax (bash -n):"
shells=()
for d in "${repo_root}/tools/macos" "${repo_root}/tools/macos/lib" "${repo_root}/tools/macos/tests"; do
  for f in "${d}"/*.sh; do
    [ -e "${f}" ] && shells+=("${f}")
  done
done
for f in "${shells[@]}"; do
  if bash -n "${f}" 2>/tmp/lint.err; then
    echo "  PASS: ${f#"${repo_root}"/}"
  else
    echo "  FAIL: ${f#"${repo_root}"/}"; cat /tmp/lint.err; fail=1
  fi
done

if command -v shellcheck >/dev/null 2>&1; then
  echo "shellcheck (advisory):"
  for f in "${shells[@]}"; do
    if shellcheck -x "${f}" >/tmp/shellcheck.out 2>&1; then
      echo "  ok: ${f#"${repo_root}"/}"
    else
      echo "  warn: ${f#"${repo_root}"/}"; sed 's/^/    /' /tmp/shellcheck.out
    fi
  done
else
  echo "shellcheck: not installed (skipping; advisory only)"
fi

echo "lua syntax (luajit):"
for f in "${repo_root}"/macos/lua/*.lua "${repo_root}"/tools/macos/tests/*.lua; do
  [ -e "${f}" ] || continue
  if luajit -bl "${f}" /dev/null >/dev/null 2>&1; then
    echo "  PASS: ${f#"${repo_root}"/}"
  else
    echo "  FAIL: ${f#"${repo_root}"/}"; luajit -bl "${f}" /dev/null; fail=1
  fi
done

[ "${fail}" -eq 0 ] && echo "lint: all passed" || echo "lint: FAILURES"
exit "${fail}"
