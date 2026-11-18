#!/usr/bin/env bash
# Generates the incompressible static files the download test serves.
# They MUST be random bytes: anything compressible lets nginx/proxies inflate the
# apparent download speed. Re-running is cheap and idempotent (skips correct sizes).
#
# Usage:  ./make-files.sh [target-dir]      # default: ./dl
# Then point nginx 'root' at the parent so the files live at <root>/dl/.
set -euo pipefail

dir="${1:-./dl}"
mkdir -p "$dir"

# size in bytes, cross-platform (GNU stat -c, BSD/macOS stat -f)
filesize() { stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || echo -1; }

gen() { # name bytes
  local path="$dir/$1"
  if [ -f "$path" ] && [ "$(filesize "$path")" = "$2" ]; then
    echo "ok    $1 — already $2 bytes"
    return
  fi
  head -c "$2" /dev/urandom > "$path"
  echo "wrote $1 — $2 bytes"
}

gen 100kb.bin 102400
gen 1mb.bin   1048576
gen 10mb.bin  10485760
gen 25mb.bin  26214400
gen 100mb.bin 104857600

echo
echo "Done. nginx 'location /dl/' should resolve to: $dir"
echo "(i.e. set 'root' to the directory that CONTAINS this dl/ folder, alongside index.html)"
