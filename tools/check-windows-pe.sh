#!/bin/sh
# verify the vendored windows link stays self-contained and relocatable.
set -eu

[ "$#" -gt 0 ] || { echo "usage: tools/check-windows-pe.sh <exe>..." >&2; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat >"$tmp/expected-dlls" <<'EOF'
advapi32.dll
api-ms-win-core-synch-l1-2-0.dll
api-ms-win-crt-convert-l1-1-0.dll
api-ms-win-crt-heap-l1-1-0.dll
api-ms-win-crt-math-l1-1-0.dll
api-ms-win-crt-private-l1-1-0.dll
api-ms-win-crt-stdio-l1-1-0.dll
api-ms-win-crt-string-l1-1-0.dll
api-ms-win-crt-utility-l1-1-0.dll
gdi32.dll
kernel32.dll
shell32.dll
user32.dll
ws2_32.dll
EOF

for exe in "$@"; do
    imports="$tmp/imports"
    relocs="$tmp/relocs"
    llvm-readobj --coff-imports "$exe" >"$imports"
    llvm-readobj --coff-basereloc "$exe" >"$relocs"
    sed -n 's/^  Name: //p' "$imports" | sort -u >"$tmp/actual-dlls"
    if ! diff -u "$tmp/expected-dlls" "$tmp/actual-dlls"; then
        echo "check-windows-pe: unexpected import dependency set in $exe" >&2
        exit 1
    fi
    if grep -Eq '^  Symbol: (__imp_|memcpy |memmove |memset |strlen |sprintf |sscanf |vsnprintf )' "$imports"; then
        echo "check-windows-pe: indirect or static CRT symbol leaked into imports in $exe" >&2
        exit 1
    fi
    for symbol in __stdio_common_vsprintf __stdio_common_vsscanf; do
        grep -q "^  Symbol: $symbol " "$imports" || {
            echo "check-windows-pe: missing UCRT helper $symbol in $exe" >&2
            exit 1
        }
    done
    dir64=$(grep -c '^    Type: DIR64$' "$relocs")
    [ "$dir64" -gt 0 ] || {
        echo "check-windows-pe: no DIR64 base relocations in $exe" >&2
        exit 1
    }
    if grep '^    Type: ' "$relocs" | grep -Ev '^    Type: (ABSOLUTE|DIR64)$'; then
        echo "check-windows-pe: unexpected base relocation type in $exe" >&2
        exit 1
    fi
    echo "PASS $exe: 14 DLLs, $dir64 DIR64 relocations"
done
