//! Retia — M1: nested コンポジタの骨格。
//!
//! wlroots 同梱の最小構成例 tinywl を、scene graph (wlr_scene) を使って Zig に移植したもの。
//! 描画は scene graph に任せる (SPEC §13 リスク 4 の方針: scene graph で開始)。
//!
//! M1 の範囲 (SPEC §12):
//!   - nested 起動 (WLR_BACKENDS=wayland) で窓が描画される
//!   - キーバインド: Super+T kitty 起動 / Super+Q 窓を閉じる / Super+Escape 終了
//!   - レイアウトは未実装 (M2 でスクロール列)。新規窓はレイアウト全面に置く
//!
//! 既知の簡略化 (M1 限定):
//!   - フォーカスは「最後に map された窓」のみ。クリックフォーカス/窓切替は M2
//!   - ドラッグ移動/リサイズなし。ポインタは hover/ボタン転送のみ

const std = @import("std");

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("signal.h");
    @cInclude("wayland-server-core.h");
    @cInclude("xkbcommon/xkbcommon.h");
    @cInclude("wlr/backend.h");
    @cInclude("wlr/render/allocator.h");
    @cInclude("wlr/render/wlr_renderer.h");
    @cInclude("wlr/types/wlr_compositor.h");
    @cInclude("wlr/types/wlr_subcompositor.h");
    @cInclude("wlr/types/wlr_data_device.h");
    @cInclude("wlr/types/wlr_output.h");
    @cInclude("wlr/types/wlr_output_layout.h");
    @cInclude("wlr/types/wlr_cursor.h");
    @cInclude("wlr/types/wlr_keyboard.h");
    @cInclude("wlr/types/wlr_seat.h");
    @cInclude("wlr/types/wlr_scene.h");
    @cInclude("wlr/types/wlr_xdg_shell.h");
    @cInclude("wlr/util/log.h");
});

/// テスト: キーバインドの mod。niri 互換のデフォルトは Super (SPEC §5)
const MODIFIER: u32 = c.WLR_MODIFIER_LOGO;

/// wlr_log マクロは __LINE__ を埋め込むため translate-c できない。自前のログに寄せる
fn logInfo(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("[retia] " ++ fmt ++ "\n", args);
}

fn logErr(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("[retia] ERROR: " ++ fmt ++ "\n", args);
}

const Toplevel = struct {
    xdg_surface: *c.wlr_xdg_surface,
    scene_tree: *c.wlr_scene_tree,

    map: c.wl_listener,
    unmap: c.wl_listener,
    destroy: c.wl_listener,
    request_maximize: c.wl_listener,
    request_fullscreen: c.wl_listener,
};

const Keyboard = struct {
    wlr_keyboard: *c.wlr_keyboard,
    modifiers: c.wl_listener,
    key: c.wl_listener,
    destroy: c.wl_listener,
};

const Server = struct {
    gpa: std.mem.Allocator,
    display: *c.wl_display = undefined,
    backend: *c.wlr_backend = undefined,
    renderer: *c.wlr_renderer = undefined,
    allocator: *c.wlr_allocator = undefined,
    scene: *c.wlr_scene = undefined,
    layout: *c.wlr_output_layout = undefined,
    cursor: *c.wlr_cursor = undefined,
    seat: *c.wlr_seat = undefined,
    xdg_shell: *c.wlr_xdg_shell = undefined,
    socket_name: [:0]const u8 = undefined,

    focused: ?*Toplevel = null,

    new_output: c.wl_listener = undefined,
    new_input: c.wl_listener = undefined,
    new_xdg_surface: c.wl_listener = undefined,
    cursor_motion: c.wl_listener = undefined,
    cursor_motion_absolute: c.wl_listener = undefined,
    cursor_button: c.wl_listener = undefined,
};

/// M1 は単一インスタンス前提 (tinywl と同じ)。プロセス分離のシェル系は別
var server: Server = undefined;

pub fn main() !void {
    server = .{ .gpa = std.heap.c_allocator };

    c.wlr_log_init(c.WLR_INFO, null);

    server.display = c.wl_display_create() orelse return error.WlDisplayCreateFailed;
    const event_loop = c.wl_display_get_event_loop(server.display);
    server.backend = c.wlr_backend_autocreate(event_loop, null) orelse return error.BackendCreateFailed;
    server.renderer = c.wlr_renderer_autocreate(server.backend) orelse return error.RendererCreateFailed;
    _ = c.wlr_renderer_init_wl_display(server.renderer, server.display);
    server.allocator = c.wlr_allocator_autocreate(server.backend, server.renderer) orelse return error.AllocatorCreateFailed;

    // プロトコル面の最小セット (SPEC §3.1 のほんの一部。増やすのは M2 以降)
    _ = c.wlr_compositor_create(server.display, 6, server.renderer);
    _ = c.wlr_subcompositor_create(server.display);
    _ = c.wlr_data_device_manager_create(server.display);

    server.layout = c.wlr_output_layout_create(server.display) orelse return error.OutputLayoutCreateFailed;
    server.scene = c.wlr_scene_create() orelse return error.SceneCreateFailed;
    _ = c.wlr_scene_attach_output_layout(server.scene, server.layout);

    server.xdg_shell = c.wlr_xdg_shell_create(server.display, 6) orelse return error.XdgShellCreateFailed;

    server.cursor = c.wlr_cursor_create() orelse return error.CursorCreateFailed;
    _ = c.wlr_cursor_attach_output_layout(server.cursor, server.layout);

    server.seat = c.wlr_seat_create(server.display, "seat0") orelse return error.SeatCreateFailed;
    _ = c.wlr_seat_set_capabilities(server.seat, c.WL_SEAT_CAPABILITY_POINTER | c.WL_SEAT_CAPABILITY_KEYBOARD);

    const socket = c.wl_display_add_socket_auto(server.display) orelse return error.NoAvailableSocket;
    server.socket_name = std.mem.span(socket);
    _ = c.setenv("WAYLAND_DISPLAY", server.socket_name.ptr, 1);

    server.new_output.notify = handleNewOutput;
    c.wl_signal_add(&server.backend.events.new_output, &server.new_output);
    server.new_input.notify = handleNewInput;
    c.wl_signal_add(&server.backend.events.new_input, &server.new_input);
    server.new_xdg_surface.notify = handleNewXdgSurface;
    c.wl_signal_add(&server.xdg_shell.events.new_surface, &server.new_xdg_surface);
    server.cursor_motion.notify = handleCursorMotion;
    c.wl_signal_add(&server.cursor.events.motion, &server.cursor_motion);
    server.cursor_motion_absolute.notify = handleCursorMotionAbsolute;
    c.wl_signal_add(&server.cursor.events.motion_absolute, &server.cursor_motion_absolute);
    server.cursor_button.notify = handleCursorButton;
    c.wl_signal_add(&server.cursor.events.button, &server.cursor_button);

    _ = c.signal(c.SIGINT, handleSigint);

    logInfo("M1 starting, WAYLAND_DISPLAY={s}", .{server.socket_name});
    _ = c.wl_display_run(server.display);
}

// ---- 出力 ----

fn handleNewOutput(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = listener;
    const output: *c.wlr_output = @ptrCast(@alignCast(data.?));

    // nested でもモードが渡されるが、無い場合 (headless 等) はカスタムモードを据える
    if (!output.enabled) {
        var state: c.wlr_output_state = undefined;
        c.wlr_output_state_init(&state);
        defer c.wlr_output_state_finish(&state);
        if (output.current_mode == null) {
            c.wlr_output_state_set_custom_mode(&state, 1280, 720, 0);
        }
        c.wlr_output_state_set_enabled(&state, true);
        if (!c.wlr_output_commit_state(output, &state)) {
            logErr("failed to commit output state: {s}", .{std.mem.sliceTo(&output.name, 0)});
            return;
        }
    }

    _ = c.wlr_output_layout_add_auto(server.layout, output);
    logInfo("output added: {s}", .{std.mem.sliceTo(&output.name, 0)});
}

// ---- 入力デバイス ----

fn handleNewInput(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = listener;
    const device: *c.wlr_input_device = @ptrCast(@alignCast(data.?));

    if (device.type == c.WLR_INPUT_DEVICE_KEYBOARD) {
        if (device.keyboard) |wlr_kb| handleNewKeyboard(wlr_kb);
    } else if (device.type == c.WLR_INPUT_DEVICE_POINTER) {
        _ = c.wlr_cursor_attach_input_device(server.cursor, device);
    }
}

fn handleNewKeyboard(wlr_kb: *c.wlr_keyboard) void {
    const kb = server.gpa.create(Keyboard) catch return;
    kb.* = .{
        .wlr_keyboard = wlr_kb,
        .modifiers = undefined,
        .key = undefined,
        .destroy = undefined,
    };

    // キーマップ: 空の rule names = デフォルト設定 (SPEC §5)
    const ctx = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS) orelse return;
    defer c.xkb_context_unref(ctx);
    var rules = std.mem.zeroes(c.xkb_rule_names);
    const keymap = c.xkb_keymap_new_from_names(ctx, &rules, c.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse return;
    c.wlr_keyboard_set_keymap(wlr_kb, keymap);
    c.xkb_keymap_unref(keymap);
    _ = c.wlr_keyboard_set_repeat_info(wlr_kb, 25, 600);

    kb.modifiers.notify = handleKeyboardModifiers;
    c.wl_signal_add(&wlr_kb.events.modifiers, &kb.modifiers);
    kb.key.notify = handleKeyboardKey;
    c.wl_signal_add(&wlr_kb.events.key, &kb.key);
    kb.destroy.notify = handleKeyboardDestroy;
    c.wl_signal_add(&wlr_kb.events.destroy, &kb.destroy);

    c.wlr_seat_set_keyboard(server.seat, wlr_kb);
    logInfo("keyboard added", .{});
}

fn handleKeyboardModifiers(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = data;
    const kb: *Keyboard = @fieldParentPtr("modifiers", listener.?);
    c.wlr_seat_set_keyboard(server.seat, kb.wlr_keyboard);
    c.wlr_seat_keyboard_notify_modifiers(server.seat, &kb.wlr_keyboard.modifiers);
}

fn handleKeyboardKey(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const kb: *Keyboard = @fieldParentPtr("key", listener.?);
    const event: *c.wlr_keyboard_key_event = @ptrCast(@alignCast(data.?));
    const wlr_kb = kb.wlr_keyboard;

    if (event.state == c.WL_KEYBOARD_KEY_STATE_PRESSED) {
        const sym = c.xkb_state_key_get_one_sym(wlr_kb.xkb_state, event.keycode + 8);
        const mods = c.wlr_keyboard_get_modifiers(wlr_kb);
        if ((mods & MODIFIER) != 0) {
            if (sym == c.XKB_KEY_q) {
                // Super+Q: フォーカス窓を閉じる
                if (server.focused) |t| {
                    _ = c.wlr_xdg_toplevel_send_close(t.xdg_surface.toplevel.?);
                }
                return;
            } else if (sym == c.XKB_KEY_t) {
                // Super+T: kitty 起動 (M7 で自作ターミナルに置き換え)
                spawnTerminal();
                return;
            } else if (sym == c.XKB_KEY_Escape) {
                // Super+Escape: コンポジタ終了 (nested 開発用の逃げ道)
                c.wl_display_terminate(server.display);
                return;
            }
        }
    }

    c.wlr_seat_keyboard_notify_key(server.seat, event.time_msec, event.keycode, event.state);
}

fn handleKeyboardDestroy(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = data;
    const kb: *Keyboard = @fieldParentPtr("destroy", listener.?);
    c.wl_list_remove(&kb.modifiers.link);
    c.wl_list_remove(&kb.key.link);
    c.wl_list_remove(&kb.destroy.link);
    server.gpa.destroy(kb);
}

fn spawnTerminal() void {
    // C の fork/exec を使う (std.process は Zig バージョン間で変わりやすいため)
    const pid = c.fork();
    if (pid == 0) {
        // 子プロセス: WAYLAND_DISPLAY は親で setenv 済み。失敗したら _exit で落とす
        _ = c.execlp("kitty", "kitty", @as(?*const anyopaque, null));
        logErr("exec kitty failed", .{});
        c._exit(1);
    } else if (pid < 0) {
        logErr("fork failed", .{});
    }
}

// ---- XDG シェル (窓) ----

fn handleNewXdgSurface(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = listener;
    const xdg_surface: *c.wlr_xdg_surface = @ptrCast(@alignCast(data.?));
    if (xdg_surface.role != c.WLR_XDG_SURFACE_ROLE_TOPLEVEL) return;
    const toplevel_handle = xdg_surface.toplevel orelse return;

    const toplevel = server.gpa.create(Toplevel) catch return;
    toplevel.* = .{
        .xdg_surface = xdg_surface,
        // scene ノードは map 前に作れる。unmap 中は自動で隠れる
        .scene_tree = c.wlr_scene_xdg_surface_create(&server.scene.tree, xdg_surface) orelse {
            server.gpa.destroy(toplevel);
            return;
        },
        .map = undefined,
        .unmap = undefined,
        .destroy = undefined,
        .request_maximize = undefined,
        .request_fullscreen = undefined,
    };

    toplevel.map.notify = handleToplevelMap;
    c.wl_signal_add(&xdg_surface.surface.events.map, &toplevel.map);
    toplevel.unmap.notify = handleToplevelUnmap;
    c.wl_signal_add(&xdg_surface.surface.events.unmap, &toplevel.unmap);
    toplevel.destroy.notify = handleToplevelDestroy;
    c.wl_signal_add(&xdg_surface.events.destroy, &toplevel.destroy);
    toplevel.request_maximize.notify = handleToplevelRequestMaximize;
    c.wl_signal_add(&toplevel_handle.events.request_maximize, &toplevel.request_maximize);
    toplevel.request_fullscreen.notify = handleToplevelRequestFullscreen;
    c.wl_signal_add(&toplevel_handle.events.request_fullscreen, &toplevel.request_fullscreen);
}

fn handleToplevelMap(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = data;
    const toplevel: *Toplevel = @fieldParentPtr("map", listener.?);

    // M1 レイアウト: レイアウト全面 (M2 でスクロール列に置き換え)
    const size = layoutSize();
    _ = c.wlr_scene_node_set_position(&toplevel.scene_tree.node, 0, 0);
    _ = c.wlr_xdg_toplevel_set_size(toplevel.xdg_surface.toplevel.?, size.w, size.h);
    _ = c.wlr_xdg_surface_schedule_configure(toplevel.xdg_surface);

    focusToplevel(toplevel);
}

fn handleToplevelUnmap(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = data;
    const toplevel: *Toplevel = @fieldParentPtr("unmap", listener.?);
    if (server.focused == toplevel) server.focused = null;
}

fn handleToplevelDestroy(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = data;
    const toplevel: *Toplevel = @fieldParentPtr("destroy", listener.?);
    c.wl_list_remove(&toplevel.map.link);
    c.wl_list_remove(&toplevel.unmap.link);
    c.wl_list_remove(&toplevel.destroy.link);
    c.wl_list_remove(&toplevel.request_maximize.link);
    c.wl_list_remove(&toplevel.request_fullscreen.link);
    if (server.focused == toplevel) server.focused = null;
    server.gpa.destroy(toplevel);
}

/// 最大化/フルスクリーン要求は M1 では全部「レイアウト全面」で応える
fn handleToplevelRequestMaximize(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = data;
    const toplevel: *Toplevel = @fieldParentPtr("request_maximize", listener.?);
    const size = layoutSize();
    _ = c.wlr_xdg_toplevel_set_size(toplevel.xdg_surface.toplevel.?, size.w, size.h);
    _ = c.wlr_xdg_toplevel_set_maximized(toplevel.xdg_surface.toplevel.?, true);
    _ = c.wlr_xdg_surface_schedule_configure(toplevel.xdg_surface);
}

fn handleToplevelRequestFullscreen(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = data;
    const toplevel: *Toplevel = @fieldParentPtr("request_fullscreen", listener.?);
    const size = layoutSize();
    _ = c.wlr_xdg_toplevel_set_size(toplevel.xdg_surface.toplevel.?, size.w, size.h);
    _ = c.wlr_xdg_toplevel_set_fullscreen(toplevel.xdg_surface.toplevel.?, true);
    _ = c.wlr_xdg_surface_schedule_configure(toplevel.xdg_surface);
}

fn focusToplevel(toplevel: *Toplevel) void {
    if (server.focused) |prev| {
        if (prev != toplevel) {
            _ = c.wlr_xdg_toplevel_set_activated(prev.xdg_surface.toplevel.?, false);
        }
    }
    server.focused = toplevel;
    _ = c.wlr_xdg_toplevel_set_activated(toplevel.xdg_surface.toplevel.?, true);
    _ = c.wlr_seat_keyboard_notify_enter(server.seat, toplevel.xdg_surface.surface, null, 0, null);
}

fn layoutSize() struct { w: u32, h: u32 } {
    if (c.wlr_output_layout_get_box(server.layout, null)) |box| {
        if (box.width > 0 and box.height > 0) {
            return .{ .w = @intCast(box.width), .h = @intCast(box.height) };
        }
    }
    return .{ .w = 1024, .h = 768 };
}

// ---- ポインタ ----

fn handleCursorMotion(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = listener;
    const event: *c.wlr_pointer_motion_event = @ptrCast(@alignCast(data.?));
    c.wlr_cursor_move(server.cursor, &event.pointer.base, event.delta_x, event.delta_y);
    processPointerMotion(event.time_msec);
}

fn handleCursorMotionAbsolute(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = listener;
    const event: *c.wlr_pointer_motion_absolute_event = @ptrCast(@alignCast(data.?));
    c.wlr_cursor_warp_absolute(server.cursor, &event.pointer.base, event.x, event.y);
    processPointerMotion(event.time_msec);
}

fn processPointerMotion(time_msec: u32) void {
    var sx: f64 = 0;
    var sy: f64 = 0;
    const node = c.wlr_scene_node_at(&server.scene.tree.node, server.cursor.x, server.cursor.y, &sx, &sy);
    if (node != null and node.?.type == c.WLR_SCENE_NODE_BUFFER) {
        const scene_buffer: *c.wlr_scene_buffer = @ptrCast(@alignCast(node.?));
        if (c.wlr_scene_surface_try_from_buffer(scene_buffer)) |scene_surface| {
            c.wlr_seat_pointer_notify_enter(server.seat, scene_surface.surface, sx, sy);
            c.wlr_seat_pointer_notify_motion(server.seat, time_msec, sx, sy);
            return;
        }
    }
    c.wlr_seat_pointer_notify_clear_focus(server.seat);
}

fn handleCursorButton(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = listener;
    const event: *c.wlr_pointer_button_event = @ptrCast(@alignCast(data.?));
    // クリックフォーカスは M2 (toplevel 一覧を持ってから)
    c.wlr_seat_pointer_notify_button(server.seat, event.time_msec, event.button, event.state);
}

// ---- 終了 ----

fn handleSigint(sig: c_int) callconv(.c) void {
    _ = sig;
    c.wl_display_terminate(server.display);
}
