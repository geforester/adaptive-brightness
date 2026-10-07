#!/bin/bash
# Тесты чистой модели: src/model.swift + tests/main.swift, без AppKit и прочего.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)/model-tests"
swiftc -O -o "$OUT" "$ROOT/src/model.swift" "$ROOT/tests/main.swift"
"$OUT"
