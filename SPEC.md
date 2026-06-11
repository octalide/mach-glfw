# mach-glfw — GLFW 3.4 bindings for Mach

Mach bindings for [GLFW](https://www.glfw.org/) 3.4: a thin raw C-ABI layer
plus an idiomatic Mach API on top. Project id is `glfw`, so consumers reach
everything as `glfw.*`.

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
- An OpenGL loader. `core.proc_address` exposes `glfwGetProcAddress`; GL
  bindings belong in a separate project.

## Architecture

Two layers:

```
src/
  c.mach          raw layer: every ext fun import, C types verbatim
  lib.mach        library surface: forwards the common core
  core.mach       init/terminate, version, events, time, context, error cb
  err.mach        error codes + last-error query
  hint.mach       init & window hint ids and values
  window.mach     Window + lifecycle, attributes, per-window callbacks
  monitor.mach    Monitor, VideoMode, gamma
  input.mach      per-window input: keys, mouse, cursor mode, clipboard, drop
  key.mach        key codes, actions, modifier bits
  mouse.mach      mouse buttons, cursor shapes, Cursor objects
  joystick.mach   joystick + gamepad state and constants
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

Naming: drop the `glfw` prefix and the per-domain noun, which the module path
already carries. `glfwCreateWindow` → `window.create`, `glfwGetKey` →
`input.key`, `glfwSetWindowShouldClose` → `window.set_should_close`,
`GLFW_KEY_ESCAPE` → `key.ESCAPE`.

Types:

- Opaque handles wrap in single-field records: `pub rec Window { handle: ptr; }`,
  `Monitor`, `Cursor`. Passed **by value** (one pointer wide). A nil-handle
  record is the sentinel for failure; check with `window.is_valid(w)`.
- `bool` (`std.types.bool`) replaces `GLFW_TRUE`/`GLFW_FALSE` returns and
  parameters; `str` (`std.types.string`) replaces `const char*`. Strings
  returned by GLFW are GLFW-owned; the docs state their lifetime.
- Scalar out-params stay out-params (`window.size(w, ?width, ?height)`), the
  Mach idiom for multiple returns.

Error model — GLFW's own, not `Result`:

- Fallible constructors return a sentinel (nil-handle record); everything else
  follows GLFW semantics (calls with an invalid handle fire the error
  callback / set the last error).
- `err.last(desc: *str) i32` wraps `glfwGetError`; `err.NONE`,
  `err.NOT_INITIALIZED`, … name the codes.
- Rationale: Mach's `Result[T, E]` requires explicit generic instantiation at
  every unwrap (`unwrap_ok[Window, Error](r)`), which costs more ergonomics
  than the sentinel + last-error model it would replace. GLFW already
  guarantees benign behavior on error paths.

Callback model:

- Callbacks are plain Mach functions; Mach compiles to the SysV C ABI on the
  supported target, so a `fun` passes directly to GLFW (verified).
- Callback `def` types live in the module that owns the setter and use **raw
  C-faithful signatures** — first parameter `ptr` (the `GLFWwindow*`), not
  `Window`, because GLFW is the caller and the C ABI is the contract:

  ```mach
  pub def KeyFun: fun(ptr, i32, i32, i32, i32);    # window, key, scancode, action, mods
  pub fun set_key_callback(w: Window, cb: KeyFun) { c.glfwSetKeyCallback(w.handle, cb); }
  ```

  Inside a callback, rewrap with `window.from_handle(h)`. Setters return
  nothing (the previous-callback return is dropped; v1 keeps the surface
  small).
- There is no closure capture in Mach; callback state goes in module-level
  `var`s or through `window.set_user_ptr` / `window.user_ptr`
  (`glfwSetWindowUserPointer`).

### Library surface — `glfw.lib`

`lib.mach` forwards the everyday core so small programs need one import:
`init`, `terminate`, `poll_events`, `wait_events`, `swap_interval`,
`Window`, `window.create` (as `create_window`), `swap_buffers`,
`make_context_current`, `should_close`, `set_should_close`. Domain modules
remain the full API; the surface is sugar, not a boundary.

## Linking

The library is source-vendored like all Mach deps; the **consumer's** manifest
must add the system library to its target:

```toml
[targets.linux]
libs = ["glfw"]
```

`ext fun` symbols then bind dynamically against `libglfw.so` at load time.
This repo's own manifest does the same for its demo/tests.

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
context, `glClearColor`/`glClear` loaded through `core.proc_address`, animated
clear color, ESC closes via key callback. Serves as living documentation of
the callback, context, and event-loop idioms.

## Tests

`test` blocks live beside the code they cover. Display-free tests (version,
error-before-init) always run; init-dependent tests require a session with a
display server and are kept in `core.mach` clearly marked.

## Known toolchain issues surfaced by this project

- `std.runtime` exits via `SYS_exit` (60), not `SYS_exit_group` (231). GLFW's
  platform backends leave service threads alive, so a process that initialized
  GLFW never terminates after `main` returns. Needs a mach-std fix; tracked
  upstream.
