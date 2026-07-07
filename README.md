# mach-glfw

Mach bindings for [GLFW](https://www.glfw.org/) 3.4: a thin raw C-ABI layer
plus an idiomatic Mach API on top. Project id is `glfw`, so consumers reach
everything as `glfw.*`.

```mach
use glfw;

fun example() {
    glfw.init();
    val w: glfw.Window = glfw.open_window(1280, 720, "hello");
    glfw.make_context_current(w);
    for (!glfw.window_should_close(w)) {
        glfw.swap_buffers(w);
        glfw.poll_events();
    }
    glfw.terminate();
}
```

Consuming projects vendor the bindings as a normal Mach dependency. The system
GLFW link requirement cascades from `mach-glfw`'s own manifest, so consumers
do not need to redeclare `libs = ["glfw"]`:

```toml
[deps.mach-glfw]
git = "https://github.com/briar-systems/mach-glfw"
ref = "branch/main"
```

## Goals

- Complete coverage of the GLFW 3.4 window/input/monitor API.
- Zero-cost: the idiomatic layer is thin wrappers over `ext fun` imports;
  no allocation, no registries, no hidden state beyond what GLFW itself keeps.
- Mach-idiomatic naming and types (`snake_case`, `bool`, `str`, records),
  while staying recognizable to anyone who knows the GLFW C API.

## Non-goals (v1)

- Vulkan surface creation (`glfwGetRequiredInstanceExtensions`,
  `glfwCreateWindowSurface`, …) — deferred until Mach has a Vulkan story.
- Native-handle access (`glfw3native.h`) — platform-specific, deferred.
- An OpenGL loader. `get_proc_address` exposes `glfwGetProcAddress`; GL
  bindings belong in a separate project.
- `glfwInitAllocator` — Mach-side custom allocators for GLFW are deferred.

## Architecture

Two layers:

```
src/
  c.mach          raw layer: every ext fun import, C types verbatim
  glfw.mach       library surface: generated, forwards every public symbol
  core.mach       init/terminate, version, events, time, context, error query
  err.mach        error code constants
  hint.mach       init & window hint ids and values
  window.mach     Window + lifecycle, attributes, context, window callbacks
  monitor.mach    Monitor, video modes, gamma
  input.mach      keys, mouse, Cursor objects, clipboard, joystick, gamepad
  key.mach        key code, action, and modifier constants
  mouse.mach      mouse button and cursor shape constants
  joystick.mach   joystick, hat, and gamepad constants
  main.mach       demo executable (not part of the library surface)
```

### Raw layer — `glfw.c`

One file mirroring `glfw3.h` declaration order. Every GLFW function is a
`pub ext fun` with its C name and C-faithful types:

```mach
pub ext fun glfwCreateWindow(width: i32, height: i32, title: *u8, monitor: ptr, share: ptr) ptr;
```

Type mapping:

| C | Mach |
|---|---|
| `int`, `enum` | `i32` |
| `unsigned int` | `u32` |
| `float` / `double` | `f32` / `f64` |
| `const char*` | `*u8` |
| `GLFWwindow*`, `GLFWmonitor*`, `GLFWcursor*` (opaque) | `ptr` |
| `GLFWvidmode*`, `GLFWimage*`, … (transparent structs) | pointer to a Mach `rec` with identical layout |
| callback function pointers | `fun(...)` types, C-faithful signatures |
| `uint64_t` | `u64` |

Transparent structs (`GLFWvidmode`, `GLFWgammaramp`, `GLFWimage`,
`GLFWgamepadstate`) are declared as `rec`s in `c.mach` with C layout and
re-exported by the idiomatic layer.

No constants live in `c.mach` — they belong to the domain modules, which own
the names (`key.SPACE`, not `GLFW_KEY_SPACE`; the `glfw.` namespace already
says "GLFW").

### Idiomatic layer

Naming is mechanically derived from the C API, so any GLFW reference maps
directly and a generator could reproduce the surface: functions are the C
name minus the `glfw` prefix, snake_cased (`glfwCreateWindow` →
`create_window`, `glfwWindowShouldClose` → `window_should_close`); constants
are the C macro minus only `GLFW_` (`GLFW_KEY_ESCAPE` → `KEY_ESCAPE`). Every
name is globally unique, which lets `glfw.mach` flatten all of them onto one
namespace.

A small set of convenience helpers has no C counterpart and follows its own
uniform rule per handle type: `no_window()` / `no_monitor()` / `no_cursor()`
(nil-handle values for optional arguments), `window_from_handle()` /
`monitor_from_handle()` (rewrap raw callback pointers), `window_is_valid()` /
`monitor_is_valid()` / `cursor_is_valid()`, and `open_window()` (windowed
`create_window` sugar).

Types:

- Opaque handles wrap in single-field records: `pub rec Window { handle: ptr; }`,
  `Monitor`, `Cursor`. Passed **by value** (one pointer wide). A nil-handle
  record is the sentinel for failure; check with `window_is_valid(w)`.
- `bool` (`std.types.bool`) replaces `GLFW_TRUE`/`GLFW_FALSE` returns and
  parameters; `str` (`std.types.string`) replaces `const char*`. Strings
  returned by GLFW are GLFW-owned; the docs state their lifetime.
- Scalar out-params stay out-params (`get_window_size(w, ?width, ?height)`),
  the Mach idiom for multiple returns.

Error model — GLFW's own, not `Result`:

- Fallible constructors return a sentinel (nil-handle record); everything else
  follows GLFW semantics (calls with an invalid handle fire the error
  callback / set the last error).
- `get_error(description: **u8) i32` wraps `glfwGetError`; `NO_ERROR`,
  `NOT_INITIALIZED`, … (module `glfw.err`) name the codes.

Callback model:

- Callbacks are plain Mach functions; Mach compiles to the SysV C ABI on the
  supported target, so a `fun` passes directly to GLFW. A display-free test
  in `core.mach` pins this ABI guarantee in CI (GLFW invokes a Mach error
  callback).
- Callback `def` types live in the module that owns the setter and use **raw
  C-faithful signatures** — first parameter `ptr` (the `GLFWwindow*`), not
  `Window`, because GLFW is the caller and the C ABI is the contract:

  ```mach
  pub def KeyFun: fun(ptr, i32, i32, i32, i32);    # window, key, scancode, action, mods
  pub fun set_key_callback(w: Window, cb: KeyFun) { c.glfwSetKeyCallback(w.handle, cb); }
  ```

  Inside a callback, rewrap with `window_from_handle(h)`. Setters return
  nothing (the previous-callback return is dropped; v1 keeps the surface
  small); clear one by passing nil cast to the callback type
  (`nil::KeyFun`).
- There is no closure capture in Mach; callback state goes in module-level
  `var`s or through `set_window_user_pointer` / `get_window_user_pointer`
  (`glfwSetWindowUserPointer`).

### Library surface — `glfw.glfw`

`glfw.mach` re-exports every public symbol of every split module (Mach has no
import splat, so the surface is explicit `fwd` lines). It is generated by
`tools/surface.sh gen` and CI fails if it drifts from the split modules
(`tools/surface.sh check`). `[project].module = "glfw.mach"` means a bare
`use glfw;` resolves to it — binding the leaf as `glfw` and giving the whole
API as `glfw.init()`, `glfw.create_window(...)`, `glfw.KEY_ESCAPE`. The split
modules (`glfw.core`, `glfw.window`, …) remain importable individually for
smaller dependency surfaces.

### Requirements and vendoring

The bindings call the **system** GLFW: `libs = ["glfw"]` resolves to
`libglfw.so` and binds the `ext fun` symbols dynamically at load time.
GLFW ≥ 3.4 must be installed (`pacman -S glfw`, `apt install libglfw3-dev`,
…). GLFW itself is intentionally not vendored.

## Scope of GLFW coverage

| Domain | In v1 |
|---|---|
| Init/terminate, init hints, version, error | yes |
| Window: create/destroy, hints, attributes, pos/size/limits/aspect, title, icon, show/hide/focus/minimize/maximize/attention, opacity, monitor mode, user pointer, all callbacks | yes |
| Context: make current, swap buffers/interval, proc address, extension query | yes |
| Monitor: enumerate, primary, pos/workarea/physical/scale/name, video modes, gamma, monitor callback | yes |
| Input: input modes, raw mouse motion, key/scancode/name, mouse buttons, cursor pos/enter, custom + standard cursors, clipboard, time/timer, key/char/mouse/scroll/drop callbacks | yes |
| Joystick/gamepad: presence, axes/buttons/hats, GUID, gamepad mappings/state, joystick callback | yes |
| Vulkan, native handles | no (deferred) |

## Demo

`main.mach` (executable target): error callback installed, window + OpenGL
context, `glClearColor`/`glClear` loaded through `get_proc_address`, animated
clear color, ESC closes via key callback. Serves as living documentation of
the callback, context, and event-loop idioms.

## Tests

`test` blocks live beside the code they cover and are display-free: the
version query and the pre-init error path (which doubles as the C→Mach
callback ABI regression test). Paths that need a live window — context
creation, swap, input events — are exercised by running the demo, not by
`mach test`.
