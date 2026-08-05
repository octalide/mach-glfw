#!/bin/sh
# materialize zig's target-matched mingw and compiler runtime archives.
set -eu

mingw_out=${1:?usage: tools/materialize-mingw-runtime.sh <mingw-out> <compiler-rt-out>}
compiler_rt_out=${2:?usage: tools/materialize-mingw-runtime.sh <mingw-out> <compiler-rt-out>}
zig=${ZIG:-zig}
isa=${MACH_TARGET_ISA:-x86_64}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

printf 'int main(void) { return 0; }\n' >"$tmp/probe.c"
if ! "$zig" cc -v -target "$isa-windows-gnu" -O2 -s \
    "$tmp/probe.c" -o "$tmp/probe.exe" >"$tmp/stdout" 2>"$tmp/link.log"; then
    cat "$tmp/stdout" "$tmp/link.log" >&2
    exit 1
fi

link_archive() {
    name=$1
    awk -v suffix="/$name" '
        /^lld-link / {
            for (i = 1; i <= NF; i++) {
                value = $i
                sub(/^"/, "", value)
                sub(/"$/, "", value)
                if (length(value) >= length(suffix) &&
                    substr(value, length(value) - length(suffix) + 1) == suffix) {
                    print value
                    exit
                }
            }
        }
    ' "$tmp/link.log"
}

mingw=$(link_archive libmingw32.lib)
compiler_rt=$(link_archive compiler_rt.lib)
if [ -z "$mingw" ] || [ -z "$compiler_rt" ] ||
   [ ! -f "$mingw" ] || [ ! -f "$compiler_rt" ]; then
    echo "materialize-mingw-runtime: zig did not report its runtime archives" >&2
    cat "$tmp/link.log" >&2
    exit 1
fi

mkdir -p "$(dirname "$mingw_out")" "$(dirname "$compiler_rt_out")"
cp "$mingw" "$mingw_out"
cp "$compiler_rt" "$compiler_rt_out"
