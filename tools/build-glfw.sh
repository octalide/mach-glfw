#!/bin/sh
# compile the vendored GLFW into a static archive for the active mach target.
#   tools/build-glfw.sh <outdir>    writes <outdir>/libglfw.a
#
# mach exports MACH_TARGET_{ISA,OS,ABI} for the build cell. a target matching the
# host builds with the system cc; anything else goes through zig cc, which
# carries the cross sysroots. CC/AR/SYSROOT/MACOS_SDK override the defaults.
#
# the darwin backend is objective-c against the apple frameworks, so it builds
# only on a macOS host or with MACOS_SDK pointing at an SDK root — zig ships no
# framework headers, and apple's SDK is not redistributable.
set -eu
cd "$(dirname "$0")/.."

OUT=${1:?usage: tools/build-glfw.sh <outdir>}
SRC=vendor/glfw/src
ISA=${MACH_TARGET_ISA:-x86_64}
OS=${MACH_TARGET_OS:-linux}

# units the platform-independent core always contributes
CORE="context.c init.c input.c monitor.c platform.c vulkan.c window.c
      egl_context.c osmesa_context.c
      null_init.c null_monitor.c null_window.c null_joystick.c"

INC="-Ivendor/glfw/include -I$SRC"
FLAGS="-std=c99 -O2 -w"

case $(uname -s) in
Linux)  HOST=linux ;;
Darwin) HOST=darwin ;;
*)      HOST=other ;;
esac

case $OS in
linux)
    TRIPLE=$ISA-linux-gnu
    # x11 and wayland are both compiled in; glfwInit picks one at runtime
    UNITS="$CORE posix_time.c posix_thread.c posix_module.c posix_poll.c
           linux_joystick.c xkb_unicode.c
           x11_init.c x11_monitor.c x11_window.c glx_context.c
           wl_init.c wl_monitor.c wl_window.c"
    DEFS="-D_GLFW_X11 -D_GLFW_WAYLAND -D_DEFAULT_SOURCE"
    # mach's elf linker resolves no GOT relocation, so the archive has to be
    # non-pic; that also means consumers cannot link it with --pie
    FLAGS="$FLAGS -fno-pic -fno-PIE"
    ;;
windows)
    TRIPLE=$ISA-windows-gnu
    UNITS="$CORE win32_time.c win32_thread.c win32_module.c
           win32_init.c win32_joystick.c win32_monitor.c win32_window.c
           wgl_context.c"
    DEFS="-D_GLFW_WIN32 -DUNICODE -D_UNICODE"
    ;;
darwin)
    TRIPLE=$ISA-macos
    UNITS="$CORE cocoa_time.c posix_thread.c posix_module.c
           cocoa_init.m cocoa_joystick.m cocoa_monitor.m cocoa_window.m
           nsgl_context.m"
    DEFS="-D_GLFW_COCOA"
    [ -n "${MACOS_SDK:-}" ] && FLAGS="$FLAGS -isysroot $MACOS_SDK"
    ;;
*)
    echo "build-glfw: unsupported target os '$OS'" >&2
    exit 1
    ;;
esac

if [ "$OS" = "$HOST" ]; then
    CC=${CC:-cc}
    AR=${AR:-ar}
    TFLAG=
else
    CC=${CC:-zig cc}
    AR=${AR:-zig ar}
    TFLAG="-target $TRIPLE"
fi

mkdir -p "$OUT"

if [ "$OS" = linux ]; then
    # the x11/wayland/xkbcommon headers come from the system; -idirafter keeps
    # them below the toolchain's own libc headers. SYSROOT retargets them.
    for d in $(pkg-config --cflags-only-I x11 xkbcommon wayland-client wayland-egl 2>/dev/null |
               tr ' ' '\n' | sed -n 's/^-I//p'); do
        INC="$INC -idirafter $d"
    done
    INC="$INC -idirafter ${SYSROOT:-}/usr/include"

    # wayland-scanner turns the vendored protocol xml into the headers wl_init.c
    # includes directly; the -code.h halves are not separate units
    WL=$OUT/wl
    mkdir -p "$WL"
    for p in wayland viewporter xdg-shell fractional-scale-v1 \
             xdg-activation-v1 xdg-decoration-unstable-v1 \
             idle-inhibit-unstable-v1 pointer-constraints-unstable-v1 \
             relative-pointer-unstable-v1; do
        wayland-scanner client-header "vendor/glfw/deps/wayland/$p.xml" "$WL/$p-client-protocol.h"
        wayland-scanner private-code  "vendor/glfw/deps/wayland/$p.xml" "$WL/$p-client-protocol-code.h"
    done
    INC="$INC -I$WL"

    # memfd_create is the preferred shm path; mkstemp is the fallback
    if printf '#include <sys/mman.h>\nint main(void){return memfd_create("x",0);}\n' |
       $CC $TFLAG -D_GNU_SOURCE -x c - -o "$OUT/.memfd" >/dev/null 2>&1; then
        DEFS="$DEFS -DHAVE_MEMFD_CREATE"
    fi
    rm -f "$OUT/.memfd"
fi

OBJS=""
for u in $UNITS; do
    o=$OUT/${u%.*}.o
    $CC $TFLAG -c $FLAGS $DEFS $INC "$SRC/$u" -o "$o"
    OBJS="$OBJS $o"
done

rm -f "$OUT/libglfw.a"
$AR rcs "$OUT/libglfw.a" $OBJS
