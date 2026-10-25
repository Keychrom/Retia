# Retia

**English** | [日本語](README.ja.md)

**A scrollable-tiling Wayland compositor with an integrated shell, written in Zig.**

Retia pairs the scrollable-column tiling grammar popularized by [niri](https://github.com/YaLTeR/niri) with the piece niri deliberately leaves out: a built-in desktop shell. Taskbar, start menu, session-persistent layouts — designed together with the compositor, in one codebase, as isolated processes.

> ⚠️ **Status: design phase.** The specification (v1.0) is frozen and implementation is starting. Nothing builds yet and there are no releases — watch the repo if you want to follow along.

## The idea, in three layers

1. **Interaction grammar: niri-compatible.** Scrollable columns, consume/expel window moves, niri's default keybind layout, KDL configuration, touchpad gestures. Muscle memory carries over — we don't reinvent this layer.
2. **Product: the shell niri leaves out.** An integrated taskbar and start menu built as first-class parts of the project. A "niri-style tiling DE" is the slot in the ecosystem Retia aims to fill.
3. **Signature features the shell enables.** A live mini-map of the window strip in the taskbar (fixing the classic "where am I in an infinite strip" problem), layouts that persist across sessions, and a start menu that fuses app launching and window switching into one search.

For context: Hyprland is C++, niri / COSMIC / ShojiWM are Rust, sway is C. Retia is the rich-shell entry written in Zig.

## Planned for v1.0

- **Scrollable columns** — columns of stacked windows on an infinitely scrolling strip, with smooth animated scrolling from day one
- **Taskbar** — workspaces, task list, clock, battery, a live **strip mini-map**, systray later
- **Start menu** — XDG app entries with fuzzy search that also jumps to running windows
- **Session layout persistence** — column structure restored across restarts
- **KDL configuration** (niri-compatible grammar) with hot reload and validation errors surfaced in the shell; optional compiled Zig plugin extensions later
- **Two-layer bar customization** — declarative KDL widgets (including `custom` script widgets) plus experimental Zig plugin widgets with a small draw-list ABI
- **Kitty** as the default terminal; a first-party terminal is planned after v1.0

## Tech stack

- **Compositor**: [wlroots](https://gitlab.freedesktop.org/wlroots/wlroots) driven from Zig (hand-written bindings)
- **Shell**: separate layer-shell clients; custom lightweight renderer (OpenGL + freetype/harfbuzz) shared by the bar and start menu
- **Config**: KDL first; Zig plugins (dlopen) as an experimental second layer

## Roadmap

| Milestone | Scope |
|---|---|
| M0 🚧 | Specification freeze, repository, dev environment |
| M1 | wlroots bindings; nested compositor renders client windows |
| M2 | Scrollable columns + smooth scrolling + keybinds |
| M3 | Standalone DRM session on real hardware |
| M4 | KDL config + hot reload + IPC + `retiactl` |
| M5 | Taskbar (mini-map) + unified-search start menu |
| M6 | Effects polish + session layout persistence |
| M7 | First-party terminal |
| M8 | XWayland, portals, polish → **Retia 0.1** |

## Specification

The full frozen design document lives in [docs/SPEC.md](docs/SPEC.md) (Japanese for now — an English translation is planned).

## License

[MIT](LICENSE)
