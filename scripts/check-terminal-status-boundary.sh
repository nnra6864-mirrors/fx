#!/usr/bin/env bash
# Terminal status keeps all host integrations (herdr, cmux, Otty) in
# src/builtins/terminal_status behind one front door, terminal_status.zig.
# Code outside imports only that file and talks to hosts only through
# `publish`. Hosts render `Status` values: they may import the status model,
# the socket transport, and shared basics, but never hooks or app runtimes,
# so a host cannot grow its own view of fx's lifecycle.

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

folder="src/builtins/terminal_status"

reaching_in="$({
  git grep -n -E '@import\("[^"]*terminal_status/[a-z_/]+\.zig"\)' -- src ":(exclude)$folder" || true
} | grep -v 'terminal_status/terminal_status\.zig")' || true)"
if [[ -n "$reaching_in" ]]; then
  printf 'Only %s/terminal_status.zig may be imported from outside terminal status:\n%s\n' "$folder" "$reaching_in" >&2
  exit 1
fi

host_access="$(git grep -n -E 'app\.(herdr|cmux|otty)([^A-Za-z0-9_]|$)|@hasField\(App, "(herdr|cmux|otty)"\)' -- src || true)"
if [[ -n "$host_access" ]]; then
  printf 'Reach terminal hosts only through app.terminal_status.publish:\n%s\n' "$host_access" >&2
  exit 1
fi

check_imports() {
  local scope="$1" allowed="$2" message="$3" line target violations=""
  while IFS= read -r line; do
    target="${line#*@import(\"}"
    target="${target%\")}"
    if [[ ! "$target" =~ $allowed ]]; then
      violations+="$line"$'\n'
    fi
  done < <(git grep -n -o -E '@import\("\.\./[^"]+"\)' -- "$scope" || true)
  if [[ -n "$violations" ]]; then
    printf '%s\n%s' "$message" "$violations" >&2
    exit 1
  fi
}

check_imports "$folder/hosts" \
  '^\.\./(status|socket)\.zig$|^\.\./\.\./\.\./(core/shared/(io|debug_trace)|acp/jsonrpc)\.zig$' \
  'Terminal hosts may import only the status model, the socket transport, and shared basics:'

check_imports "$folder/status.zig" \
  '^\.\./\.\./core/shared/types\.zig$' \
  'The status model must stay pure:'

check_imports "$folder/socket.zig" \
  '^\.\./\.\./core/shared/io\.zig$' \
  'The socket transport may import only shared I/O:'
