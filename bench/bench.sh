#!/bin/sh
BIN=${1:-./zig-out/bin/zero-noise}
for cmd in "audit src" "complexity src --threshold=100" "blast executeSafeRefactor --root=src"; do
  echo "== $cmd =="
  /usr/bin/time -f "elapsed=%e sec maxrss=%M KB" sh -c "$BIN $cmd >/dev/null" 2>&1
done
