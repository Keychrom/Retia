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
    @cInclude("time.h");
    @cInclude("unistd.h");
    @cInclude("wayland-server-core.h");
    @cInclude("xkbcommon/xkbcommon.h");
    @cInclude("wlr/backend.h");
    @cInclude("wlr/backend/wayland.h");
    @cInclude("wlr/render/allocator.h");
    @cInclude("wlr/render/wlr_renderer.h");
    @cInclude("wlr/types/wlr_compositor.h");
    @cInclude("wlr/types/wlr_subcompositor.h");
    @cInclude("wlr/types/wlr_data_device.h");
    @cInclude("wlr/types/wlr_output.h");
    @cInclude("wlr/types/wlr_output_layout.h");
    @cInclude("wlr/types/wlr_cursor.h");
    @cInclude("wlr/types/wlr_xcursor_manager.h");
    @cInclude("wlr/types/wlr_keyboard.h");
    @cInclude("wlr/types/wlr_seat.h");
    @cInclude("wlr/types/wlr_scene.h");
    @cInclude("wlr/types/wlr_xdg_shell.h");
    @cInclude("wlr/types/wlr_layer_shell_v1.h");
    @cInclude("wlr/types/wlr_screencopy_v1.h");
    @cInclude("wlr/types/wlr_xdg_output_v1.h");
    @cInclude("wlr/util/log.h");
});

const layout_mod = @import("layout/layout.zig");

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
    xdg_toplevel: *c.wlr_xdg_toplevel,
    /// xdg_toplevel.base は [*c] なので単一ポインタ化して保持する
    base: *c.wlr_xdg_surface,
    scene_tree: *c.wlr_scene_tree,
    /// フォーカス表示用の枠 (窓の背面に置く)
    focus_rect: *c.wlr_scene_rect,
    /// 所属ワークスペース (0 始点)
    ws: usize,
    fullscreen: bool = false,
    /// 浮動窓 (SPEC §4.2 toggle-window-floating)
    floating: bool = false,
    fx: i32 = 0,
    fy: i32 = 0,
    fw: i32 = 0,
    fh: i32 = 0,

    map: c.wl_listener,
    unmap: c.wl_listener,
    commit: c.wl_listener,
    destroy: c.wl_listener,
    request_maximize: c.wl_listener,
    request_fullscreen: c.wl_listener,
};

const Popup = struct {
    xdg_popup: *c.wlr_xdg_popup,
    commit: c.wl_listener,
    destroy: c.wl_listener,
};

const WORKSPACE_COUNT = 9;

/// レイヤーシェル表面 (bemenu / waybar / 将来の自作バー。SPEC §3.1)
const LayerSurface = struct {
    layer_surface: *c.wlr_layer_surface_v1,
    scene: *c.wlr_scene_layer_surface_v1,
    map: c.wl_listener,
    unmap: c.wl_listener,
    commit: c.wl_listener,
    destroy: c.wl_listener,
};

/// ポインタのドラッグ状態 (SPEC §5: mod+左ドラッグ移動 / mod+右ドラッグリサイズ)
const CursorMode = enum {
    passthrough,
    move,
    resize,
};

const SceneLayout = layout_mod.Layout(*Toplevel);

const Keyboard = struct {
    wlr_keyboard: *c.wlr_keyboard,
    modifiers: c.wl_listener,
    key: c.wl_listener,
    destroy: c.wl_listener,
};

const Output = struct {
    wlr_output: *c.wlr_output,
    frame: c.wl_listener,
    destroy: c.wl_listener,
};

const Server = struct {
    gpa: std.mem.Allocator,
    display: *c.wl_display = undefined,
    backend: *c.wlr_backend = undefined,
    renderer: *c.wlr_renderer = undefined,
    allocator: *c.wlr_allocator = undefined,
    scene: *c.wlr_scene = undefined,
    scene_output_layout: *c.wlr_scene_output_layout = undefined,
    /// レイヤーシェル用ツリー (下層/上層)。窓は常にこの間に描画される
    layers_bottom_tree: *c.wlr_scene_tree = undefined,
    layers_top_tree: *c.wlr_scene_tree = undefined,
    layer_shell: *c.wlr_layer_shell_v1 = undefined,
    output_layout: *c.wlr_output_layout = undefined,
    cursor: *c.wlr_cursor = undefined,
    xcursor_manager: *c.wlr_xcursor_manager = undefined,
    seat: *c.wlr_seat = undefined,
    xdg_shell: *c.wlr_xdg_shell = undefined,
    socket_name: [:0]const u8 = undefined,
    nested: bool = false,
    /// 出力ごとにワークスペース群を持つ設計 (SPEC §3.2)。現状は単一出力前提で
    /// Server 直に 9 枚。マルチ出力は M3 で出力への割当に変える
    workspaces: [WORKSPACE_COUNT]SceneLayout = undefined,
    active_ws: usize = 0,
    toplevels: std.ArrayList(*Toplevel) = .empty,
    viewport_x: f64 = 0,
    /// フレームハンドラでの applyLayout 反映用 (イベント側で立てる)
    dirty_layout: bool = false,
    outputs: std.ArrayList(*Output) = .empty,
    cursor_mode: CursorMode = .passthrough,
    grabbed: ?*Toplevel = null,
    grab_x: f64 = 0,
    grab_y: f64 = 0,
    grab_w: i32 = 0,
    grab_h: i32 = 0,
    focused: ?*Toplevel = null,

    new_output: c.wl_listener = undefined,
    new_input: c.wl_listener = undefined,
    new_xdg_toplevel: c.wl_listener = undefined,
    new_xdg_popup: c.wl_listener = undefined,
    new_layer_surface: c.wl_listener = undefined,
    cursor_motion: c.wl_listener = undefined,
    cursor_motion_absolute: c.wl_listener = undefined,
    cursor_button: c.wl_listener = undefined,

    fn activeLayout(self: *Server) *SceneLayout {
        return &self.workspaces[self.active_ws];
    }

    /// アクティブなワークスペースの列数・窓数のログ用
    fn layoutSummary(self: *Server) struct { cols: usize, wins: usize } {
        var wins: usize = 0;
        for (self.activeLayout().columns.items) |*col| wins += col.windows.items.len;
        return .{ .cols = self.activeLayout().columns.items.len, .wins = wins };
    }

    /// レイアウト反映を要求する (実際の適用は次フレーム。フレーム内で直接
    /// 座標を書き換えると窓の描画が壊れるため)
    pub fn applyLayout(self: *Server) void {
        self.dirty_layout = true;
    }

    pub fn applyLayoutNow(self: *Server) void {
        const size = layoutSize();
        for (&self.workspaces) |*ws| ws.setUsableSize(size.w, size.h);
        const l = self.activeLayout();

        // 非アクティブワークスペースの窓とリングを隠す
        for (self.toplevels.items) |t| {
            const visible = t.ws == self.active_ws;
            _ = c.wlr_scene_node_set_enabled(&t.scene_tree.node, visible);
            _ = c.wlr_scene_node_set_enabled(&t.focus_rect.node, visible);
        }

        const boxes = l.windowBoxes(self.gpa) catch return;
        defer self.gpa.free(boxes);
        const vx: i32 = @intFromFloat(self.viewport_x);
        for (boxes) |box| {
            const t: *Toplevel = box.window;
            _ = c.wlr_scene_node_set_enabled(&t.scene_tree.node, true);
            if (t.fullscreen) {
                _ = c.wlr_scene_node_set_position(&t.scene_tree.node, 0, 0);
                _ = c.wlr_scene_node_set_enabled(&t.focus_rect.node, false);
                if (t.base.initial_commit) {
                    _ = c.wlr_xdg_toplevel_set_size(t.xdg_toplevel, size.w, size.h);
                }
                continue;
            }
            _ = c.wlr_scene_node_set_position(&t.scene_tree.node, box.x - vx, box.y);
            // initial commit 前の surface への schedule_configure は assert 死亡する
            if (t.base.initial_commit) {
                _ = c.wlr_xdg_toplevel_set_size(t.xdg_toplevel, box.w, box.h);
            }
            // フォーカスリング: フォーカス窓はアクセント色
            const is_focused = self.focused == t;
            const color: [4]f32 = if (is_focused) .{ 0.5, 0.78, 1.0, 1.0 } else .{ 0.31, 0.31, 0.31, 1.0 };
            c.wlr_scene_rect_set_color(t.focus_rect, &color);
            c.wlr_scene_rect_set_size(t.focus_rect, box.w + 4, box.h + 4);
            _ = c.wlr_scene_node_set_position(&t.focus_rect.node, box.x - vx - 2, box.y - 2);
        }

        // 浮動窓 (レイアウト外): 固定位置・サイズ、リングも自分のサイズで
        for (self.toplevels.items) |t| {
            if (!t.floating or t.ws != self.active_ws or t.fullscreen) continue;
            _ = c.wlr_scene_node_set_enabled(&t.scene_tree.node, true);
            _ = c.wlr_scene_node_set_position(&t.scene_tree.node, t.fx - vx, t.fy);
            const is_focused = self.focused == t;
            const fcolor: [4]f32 = if (is_focused) .{ 0.5, 0.78, 1.0, 1.0 } else .{ 0.31, 0.31, 0.31, 1.0 };
            c.wlr_scene_rect_set_color(t.focus_rect, &fcolor);
            c.wlr_scene_rect_set_size(t.focus_rect, t.fw + 4, t.fh + 4);
            _ = c.wlr_scene_node_set_position(&t.focus_rect.node, t.fx - vx - 2, t.fy - 2);
        }
    }
};

/// M1 は単一インスタンス前提 (tinywl と同じ)。プロセス分離のシェル系は別
var server: Server = undefined;

pub fn main() !void {
    server = .{ .gpa = std.heap.c_allocator };
    for (&server.workspaces) |*ws| ws.* = SceneLayout.init(server.gpa);

    c.wlr_log_init(c.WLR_INFO, null);

    server.display = c.wl_display_create() orelse return error.WlDisplayCreateFailed;
    const event_loop = c.wl_display_get_event_loop(server.display);
    if (c.getenv("WAYLAND_DISPLAY") != null) {
        // nested を試みる。接続できない環境 (WAYLAND_DISPLAY が残っている alone な
        // TTY など) では DRM standalone にフォールバックする
        if (c.wlr_wl_backend_create(event_loop, null)) |wl_backend| {
            server.backend = @ptrCast(wl_backend);
            server.nested = true;
        } else {
            logErr("wayland backend failed — falling back to DRM standalone", .{});
            server.backend = c.wlr_backend_autocreate(event_loop, null) orelse return error.BackendCreateFailed;
        }
    } else {
        server.backend = c.wlr_backend_autocreate(event_loop, null) orelse return error.BackendCreateFailed;
    }
    server.renderer = c.wlr_renderer_autocreate(server.backend) orelse return error.RendererCreateFailed;
    _ = c.wlr_renderer_init_wl_display(server.renderer, server.display);
    server.allocator = c.wlr_allocator_autocreate(server.backend, server.renderer) orelse return error.AllocatorCreateFailed;

    // プロトコル面の最小セット (SPEC §3.1 のほんの一部。増やすのは M2 以降)
    _ = c.wlr_compositor_create(server.display, 6, server.renderer);
    _ = c.wlr_subcompositor_create(server.display);
    _ = c.wlr_data_device_manager_create(server.display);

    server.output_layout = c.wlr_output_layout_create(server.display) orelse return error.OutputLayoutCreateFailed;
    server.scene = c.wlr_scene_create() orelse return error.SceneCreateFailed;
    server.scene_output_layout = c.wlr_scene_attach_output_layout(server.scene, server.output_layout) orelse return error.SceneAttachFailed;

    server.xdg_shell = c.wlr_xdg_shell_create(server.display, 6) orelse return error.XdgShellCreateFailed;

    // レイヤーシェル (ランチャー/バー/壁紙)。窓より下/上のツリーを用意する
    server.layer_shell = c.wlr_layer_shell_v1_create(server.display, 4) orelse return error.LayerShellCreateFailed;
    server.layers_bottom_tree = c.wlr_scene_tree_create(&server.scene.tree) orelse return error.SceneTreeCreateFailed;
    server.layers_top_tree = c.wlr_scene_tree_create(&server.scene.tree) orelse return error.SceneTreeCreateFailed;
    server.new_layer_surface.notify = handleNewLayerSurface;
    c.wl_signal_add(&server.layer_shell.events.new_surface, &server.new_layer_surface);

    // スクリーンショット (grim 用。デバッグとユーザー機能の両方)
    _ = c.wlr_screencopy_manager_v1_create(server.display);
    // 出力メタデータ (grim/waybar 等が位置とスケールを知るのに必要)
    _ = c.wlr_xdg_output_manager_v1_create(server.display, server.output_layout);

    server.cursor = c.wlr_cursor_create() orelse return error.CursorCreateFailed;
    _ = c.wlr_cursor_attach_output_layout(server.cursor, server.output_layout);
    // カーソル画像 (無いとポインタが不可視になる)。"default" テーマは中身が
    // 継承のみの場合があるので、ロード失敗時は Adwaita にフォールバックする
    server.xcursor_manager = c.wlr_xcursor_manager_create(null, 24) orelse return error.XcursorCreateFailed;
    if (!c.wlr_xcursor_manager_load(server.xcursor_manager, 1.0) or
        c.wlr_xcursor_manager_get_xcursor(server.xcursor_manager, "default", 1.0) == null)
    {
        logErr("cursor theme 'default' unavailable — falling back to Adwaita", .{});
        c.wlr_xcursor_manager_destroy(server.xcursor_manager);
        server.xcursor_manager = c.wlr_xcursor_manager_create("Adwaita", 24) orelse return error.XcursorCreateFailed;
        if (!c.wlr_xcursor_manager_load(server.xcursor_manager, 1.0)) {
            logErr("Adwaita cursor load failed too", .{});
        }
    }
    c.wlr_cursor_set_xcursor(server.cursor, server.xcursor_manager, "default");

    server.seat = c.wlr_seat_create(server.display, "seat0") orelse return error.SeatCreateFailed;
    _ = c.wlr_seat_set_capabilities(server.seat, c.WL_SEAT_CAPABILITY_POINTER | c.WL_SEAT_CAPABILITY_KEYBOARD);

    const socket = c.wl_display_add_socket_auto(server.display) orelse return error.NoAvailableSocket;
    server.socket_name = std.mem.span(socket);
    _ = c.setenv("WAYLAND_DISPLAY", server.socket_name.ptr, 1);

    server.new_output.notify = handleNewOutput;
    c.wl_signal_add(&server.backend.events.new_output, &server.new_output);
    server.new_input.notify = handleNewInput;
    c.wl_signal_add(&server.backend.events.new_input, &server.new_input);
    server.new_xdg_toplevel.notify = handleNewXdgToplevel;
    c.wl_signal_add(&server.xdg_shell.events.new_toplevel, &server.new_xdg_toplevel);
    server.new_xdg_popup.notify = handleNewXdgPopup;
    c.wl_signal_add(&server.xdg_shell.events.new_popup, &server.new_xdg_popup);
    server.cursor_motion.notify = handleCursorMotion;
    c.wl_signal_add(&server.cursor.events.motion, &server.cursor_motion);
    server.cursor_motion_absolute.notify = handleCursorMotionAbsolute;
    c.wl_signal_add(&server.cursor.events.motion_absolute, &server.cursor_motion_absolute);
    server.cursor_button.notify = handleCursorButton;
    c.wl_signal_add(&server.cursor.events.button, &server.cursor_button);

    _ = c.signal(c.SIGINT, handleSigint);
    // fork した子 (kitty) を自動回収する (放置するとゾンビになる)
    _ = c.signal(c.SIGCHLD, c.SIG_IGN);

    // リスナー登録を済ませてから start (start 時に new_output が飛ぶ)
    _ = c.wlr_backend_start(server.backend);
    if (server.nested) {
        // 0.19 の wayland backend は output を自動生成しない。明示的に要求する
        _ = c.wlr_wl_output_create(server.backend);
    }

    logInfo("M1 starting, WAYLAND_DISPLAY={s}", .{server.socket_name});
    _ = c.wl_display_run(server.display);
}

// ---- 出力 ----

fn handleNewOutput(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = listener;
    const wlr_output: *c.wlr_output = @ptrCast(@alignCast(data.?));

    // output に allocator/renderer を紐付ける。commit 前に一度必須 (tinywl と同じ)
    _ = c.wlr_output_init_render(wlr_output, server.allocator, server.renderer);

    // nested でもモードが渡されるが、無い場合 (headless 等) はカスタムモードを据える
    if (!wlr_output.enabled) {
        var state: c.wlr_output_state = undefined;
        c.wlr_output_state_init(&state);
        defer c.wlr_output_state_finish(&state);
        if (wlr_output.current_mode == null) {
            c.wlr_output_state_set_custom_mode(&state, 1280, 720, 0);
        }
        c.wlr_output_state_set_enabled(&state, true);
        if (!c.wlr_output_commit_state(wlr_output, &state)) {
            logErr("failed to commit output state: {s}", .{outputName(wlr_output)});
            return;
        }
    }

    const output = server.gpa.create(Output) catch return;
    output.* = .{
        .wlr_output = wlr_output,
        .frame = undefined,
        .destroy = undefined,
    };
    output.frame.notify = handleOutputFrame;
    c.wl_signal_add(&wlr_output.events.frame, &output.frame);
    output.destroy.notify = handleOutputDestroy;
    c.wl_signal_add(&wlr_output.events.destroy, &output.destroy);

    // scene_output は自動では作られない: 作成して layout のエントリに紐付ける
    const lo = c.wlr_output_layout_add_auto(server.output_layout, wlr_output);
    // wl_output グローバルを広告する (bemenu 等、出力サイズを必要とするクライアント用。
    // 呼ばないと bind が NULL のまま落ちる)
    c.wlr_output_create_global(wlr_output, server.display);
    const so = c.wlr_scene_output_create(server.scene, wlr_output) orelse {
        logErr("failed to create scene output", .{});
        return;
    };
    c.wlr_scene_output_layout_add_output(server.scene_output_layout, lo, so);
    const so_check = c.wlr_scene_get_scene_output(server.scene, wlr_output);
    logInfo("output added: {s} scene_output={s}", .{ outputName(wlr_output), if (so_check != null) "yes" else "NULL" });

    // レイアウトの usable サイズを更新して配置し直す
    var ew: i32 = 0;
    var eh: i32 = 0;
    c.wlr_output_effective_resolution(wlr_output, &ew, &eh);
    for (&server.workspaces) |*ws| ws.setUsableSize(ew, eh);
    server.outputs.append(server.gpa, output) catch {};
    // VirtualBox (vmwgfx) の HW カーソルが表示されないためソフトウェアカーソルを
    // 強制する。scene commit がカーソルを描画に混ぜてくれる
    c.wlr_output_lock_software_cursors(wlr_output, true);
    server.applyLayout();
    c.wlr_cursor_set_xcursor(server.cursor, server.xcursor_manager, "default");
}

fn handleOutputFrame(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = data;
    const output: *Output = @fieldParentPtr("frame", @as(*c.wl_listener, @ptrCast(listener)));
    // 注: ここで applyLayout を毎フレーム呼ぶと窓の描画が壊れる (検証済み)。
    // レイアウト反映はイベント駆動のみ
    if (server.dirty_layout) {
        server.dirty_layout = false;
        server.applyLayoutNow();
    }
    const scene_output = c.wlr_scene_get_scene_output(server.scene, output.wlr_output);
    if (scene_output) |so| {
        // scene graph の内容を output に commit する。
        // 注意: ここで wlr_output_schedule_frame を呼ぶと frame イベントが即座に
        // 再発火して暴走+毎フレームバッファリーク (OOM した)。tinywl も schedule
        // しない — scene が damage を検知したときだけ自動で回る
        _ = c.wlr_scene_output_commit(so, null);
        // クライアント (kitty 等) にフレーム完了を通知しないと描画が止まる
        var now: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &now);
        c.wlr_scene_output_send_frame_done(so, &now);
    }
    // viewport スクロールのイージング: 収束するまでフレームを継続要求する
    // (アニメ中だけ schedule — 常時は OOM の教訓どおり NG)
    const target: f64 = @floatFromInt(server.activeLayout().viewportTargetX());
    if (@abs(target - server.viewport_x) > 0.5) {
        server.viewport_x += (target - server.viewport_x) * 0.2;
        c.wlr_output_schedule_frame(output.wlr_output);
    } else if (server.viewport_x != target) {
        server.viewport_x = target;
        server.applyLayout();
    }
}

fn handleOutputDestroy(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = data;
    const output: *Output = @fieldParentPtr("destroy", @as(*c.wl_listener, @ptrCast(listener)));
    c.wl_list_remove(&output.frame.link);
    c.wl_list_remove(&output.destroy.link);
    // scene 側の output も明示的に破棄する
    if (c.wlr_scene_get_scene_output(server.scene, output.wlr_output)) |so| {
        c.wlr_scene_output_destroy(so);
    }
    for (server.outputs.items, 0..) |o, i| {
        if (o == output) {
            _ = server.outputs.orderedRemove(i);
            break;
        }
    }
    server.gpa.destroy(output);
    server.applyLayout();
}

/// 0.19 では output.name は NULL になりうる ("may be NULL")
fn outputName(output: *c.wlr_output) []const u8 {
    if (output.name) |n| return std.mem.span(n);
    return "unknown";
}

// ---- 入力デバイス ----

fn handleNewInput(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = listener;
    const device: *c.wlr_input_device = @ptrCast(@alignCast(data.?));

    if (device.type == c.WLR_INPUT_DEVICE_KEYBOARD) {
        // 0.19 からは union でなく from_input_device() で専用型へ変換する
        if (c.wlr_keyboard_from_input_device(device)) |wlr_kb| handleNewKeyboard(@ptrCast(wlr_kb), device);
    } else if (device.type == c.WLR_INPUT_DEVICE_POINTER) {
        _ = c.wlr_cursor_attach_input_device(server.cursor, device);
    }
}

fn handleNewKeyboard(wlr_kb: *c.wlr_keyboard, device: *c.wlr_input_device) void {
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
    _ = c.wlr_keyboard_set_keymap(wlr_kb, keymap);
    c.xkb_keymap_unref(keymap);
    _ = c.wlr_keyboard_set_repeat_info(wlr_kb, 25, 600);

    kb.modifiers.notify = handleKeyboardModifiers;
    c.wl_signal_add(&wlr_kb.events.modifiers, &kb.modifiers);
    kb.key.notify = handleKeyboardKey;
    c.wl_signal_add(&wlr_kb.events.key, &kb.key);
    kb.destroy.notify = handleKeyboardDestroy;
    // 0.19 から keyboard 自身の events に destroy は無い。input device 側を受ける
    c.wl_signal_add(&device.events.destroy, &kb.destroy);

    c.wlr_seat_set_keyboard(server.seat, wlr_kb);
    logInfo("keyboard added", .{});
}

fn handleKeyboardModifiers(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = data;
    const kb: *Keyboard = @fieldParentPtr("modifiers", @as(*c.wl_listener, @ptrCast(listener)));
    c.wlr_seat_set_keyboard(server.seat, kb.wlr_keyboard);
    c.wlr_seat_keyboard_notify_modifiers(server.seat, &kb.wlr_keyboard.modifiers);
}

fn handleKeyboardKey(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const kb: *Keyboard = @fieldParentPtr("key", @as(*c.wl_listener, @ptrCast(listener)));
    const event: *c.wlr_keyboard_key_event = @ptrCast(@alignCast(data.?));
    const wlr_kb = kb.wlr_keyboard;

    if (event.state == c.WL_KEYBOARD_KEY_STATE_PRESSED) {
        const sym = c.xkb_state_key_get_one_sym(wlr_kb.xkb_state, event.keycode + 8);
        const mods = c.wlr_keyboard_get_modifiers(wlr_kb);
        if ((mods & MODIFIER) != 0) {
            const ctrl = (mods & c.WLR_MODIFIER_CTRL) != 0;
            const shift = (mods & c.WLR_MODIFIER_SHIFT) != 0;
            const digit = digitFromSym(sym);
            if (sym == c.XKB_KEY_q) {
                // Super+Q: フォーカス窓を閉じる
                if (server.focused) |t| {
                    _ = c.wlr_xdg_toplevel_send_close(t.xdg_toplevel);
                }
                return;
            } else if (sym == c.XKB_KEY_t) {
                // Super+T: kitty 起動 (M7 で自作ターミナルに置き換え)
                spawnTerminal();
                return;
            } else if (sym == c.XKB_KEY_d) {
                // Mod+D: ランチャー (fuzzel。bemenu はこの環境で renderer が
                // segfault するため不採用。M5 で自作スタートメニューに置き換え)
                spawn("fuzzel");
                return;
            } else if (sym == c.XKB_KEY_Escape and !ctrl) {
                // Super+Escape: コンポジタ終了 (nested 開発用の逃げ道)
                c.wl_display_terminate(server.display);
                return;
            } else if (digit != null and ctrl) {
                // Mod+Ctrl+1..9: フォーカス列をワークスペース N へ移動
                const n = digit.? - 1;
                if (server.activeLayout().takeFocusedColumn()) |col| {
                    for (col.windows.items) |t| t.ws = n;
                    server.workspaces[n].appendColumn(col) catch {};
                    logInfo("column moved to ws {d}", .{n + 1});
                    server.applyLayout();
                }
                return;
            } else if (digit != null) {
                // Mod+1..9: ワークスペース N へ切替
                switchWorkspace(digit.? - 1);
                return;
            } else if (sym == c.XKB_KEY_u) {
                // Mod+U: ワークスペース下へ (番号小さい方へ)
                if (server.active_ws > 0) switchWorkspace(server.active_ws - 1);
                return;
            } else if (sym == c.XKB_KEY_i) {
                // Mod+I: ワークスペース上へ
                if (server.active_ws + 1 < WORKSPACE_COUNT) switchWorkspace(server.active_ws + 1);
                return;
            } else if (sym == c.XKB_KEY_h and ctrl) {
                server.activeLayout().moveColumnLeft();
                server.applyLayout();
                return;
            } else if (sym == c.XKB_KEY_l and ctrl) {
                server.activeLayout().moveColumnRight();
                server.applyLayout();
                return;
            } else if (sym == c.XKB_KEY_j and ctrl) {
                server.activeLayout().moveWindowDown();
                server.applyLayout();
                return;
            } else if (sym == c.XKB_KEY_k and ctrl) {
                server.activeLayout().moveWindowUp();
                server.applyLayout();
                return;
            } else if (sym == c.XKB_KEY_h) {
                server.activeLayout().focusColumnLeft();
                server.applyLayout();
                return;
            } else if (sym == c.XKB_KEY_l) {
                server.activeLayout().focusColumnRight();
                server.applyLayout();
                return;
            } else if (sym == c.XKB_KEY_j) {
                server.activeLayout().focusWindowDown();
                server.applyLayout();
                return;
            } else if (sym == c.XKB_KEY_k) {
                server.activeLayout().focusWindowUp();
                server.applyLayout();
                return;
            } else if (sym == c.XKB_KEY_bracketleft) {
                // Mod+[: consume-or-expel 左 (niri セマンティクス)
                server.activeLayout().consumeOrExpelLeft() catch {};
                server.applyLayout();
                return;
            } else if (sym == c.XKB_KEY_bracketright) {
                server.activeLayout().consumeOrExpelRight() catch {};
                server.applyLayout();
                return;
            } else if (sym == c.XKB_KEY_r) {
                // Mod+R: 列幅プリセットをサイクル
                server.activeLayout().cycleColumnWidth();
                server.applyLayout();
                return;
            } else if (sym == c.XKB_KEY_f and shift) {
                // Mod+Shift+F: フルスクリーントグル
                if (server.focused) |t| {
                    t.fullscreen = !t.fullscreen;
                    _ = c.wlr_xdg_toplevel_set_fullscreen(t.xdg_toplevel, t.fullscreen);
                    server.applyLayout();
                }
                return;
            } else if (sym == c.XKB_KEY_f) {
                // Mod+F: フォーカス列を最大化トグル
                server.activeLayout().toggleMaximizeColumn();
                server.applyLayout();
                return;
            } else if (sym == c.XKB_KEY_v) {
                // Mod+V: 浮動/タイル切替 (SPEC §4.2)
                if (server.focused) |t| toggleFloating(t);
                return;
            }
        }
    }

    c.wlr_seat_keyboard_notify_key(server.seat, event.time_msec, event.keycode, event.state);
}

fn digitFromSym(sym: u32) ?u8 {
    return switch (sym) {
        c.XKB_KEY_1 => 1,
        c.XKB_KEY_2 => 2,
        c.XKB_KEY_3 => 3,
        c.XKB_KEY_4 => 4,
        c.XKB_KEY_5 => 5,
        c.XKB_KEY_6 => 6,
        c.XKB_KEY_7 => 7,
        c.XKB_KEY_8 => 8,
        c.XKB_KEY_9 => 9,
        else => null,
    };
}

fn toggleFloating(t: *Toplevel) void {
    if (!t.floating) {
        // タイル → 浮動: 現在の box を初期位置・サイズにする
        server.workspaces[t.ws].removeWindow(t);
        const size = layoutSize();
        const vx: i32 = @intFromFloat(server.viewport_x);
        t.floating = true;
        if (t.fw == 0 or t.fh == 0) {
            t.fw = @divTrunc(size.w * 2, 3);
            t.fh = @divTrunc(size.h * 2, 3);
        }
        t.fx = vx + @divTrunc(size.w - t.fw, 2);
        t.fy = @divTrunc(size.h - t.fh, 2);
        _ = c.wlr_xdg_toplevel_set_size(t.xdg_toplevel, t.fw, t.fh);
    } else {
        // 浮動 → タイル: アクティブワークスペースのフォーカス列の隣へ
        t.floating = false;
        t.ws = server.active_ws;
        server.activeLayout().addWindow(t) catch {};
    }
    server.applyLayout();
}

fn switchWorkspace(n: usize) void {
    if (n >= WORKSPACE_COUNT or n == server.active_ws) return;
    server.active_ws = n;
    // 切替先のフォーカス窓へキーボードフォーカスを移す
    if (server.activeLayout().focusedWindow()) |t| {
        focusToplevel(t);
    } else {
        server.focused = null;
        c.wlr_seat_keyboard_notify_clear_focus(server.seat);
        server.applyLayout();
    }
    const s = server.layoutSummary();
    logInfo("workspace {d}: {d} cols, {d} windows", .{ n + 1, s.cols, s.wins });
}

fn handleKeyboardDestroy(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = data;
    const kb: *Keyboard = @fieldParentPtr("destroy", @as(*c.wl_listener, @ptrCast(listener)));
    c.wl_list_remove(&kb.modifiers.link);
    c.wl_list_remove(&kb.key.link);
    c.wl_list_remove(&kb.destroy.link);
    server.gpa.destroy(kb);
}

fn spawnTerminal() void {
    spawn("kitty");
}

fn spawn(cmd: []const u8) void {
    // C の fork/exec を使う (std.process は Zig バージョン間で変わりやすいため)
    const pid = c.fork();
    if (pid == 0) {
        // VirtualBox SVGA3D の dmabuf インポートが不安定 (15秒程度で壊れる) ため、
        // クライアントはソフトウェアレンダリングで動かす。実機 (M3) では外す想定
        _ = c.setenv("LIBGL_ALWAYS_SOFTWARE", "1", 1);
        var buf: [128]u8 = undefined;
        const cmd_z = std.fmt.bufPrintZ(&buf, "{s}", .{cmd}) catch return;
        _ = c.execlp(cmd_z.ptr, cmd_z.ptr, @as(?*const anyopaque, null));
        logErr("exec {s} failed", .{cmd});
        c._exit(1);
    } else if (pid < 0) {
        logErr("fork failed", .{});
    }
}

// ---- レイヤーシェル ----

fn handleNewLayerSurface(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = listener;
    const layer_surface: *c.wlr_layer_surface_v1 = @ptrCast(@alignCast(data.?));

    const layer = layer_surface.current.layer;
    const parent: *c.wlr_scene_tree = if (layer == c.ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND or layer == c.ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM)
        server.layers_bottom_tree
    else
        server.layers_top_tree;

    const ls = server.gpa.create(LayerSurface) catch return;
    ls.* = .{
        .layer_surface = layer_surface,
        .scene = c.wlr_scene_layer_surface_v1_create(parent, layer_surface) orelse {
            server.gpa.destroy(ls);
            return;
        },
        .map = undefined,
        .unmap = undefined,
        .commit = undefined,
        .destroy = undefined,
    };
    // layer surface の popup の親解決用
    layer_surface.data = ls.scene.tree;

    const surface: *c.wlr_surface = @ptrCast(layer_surface.surface);
    ls.map.notify = handleLayerSurfaceMap;
    c.wl_signal_add(&surface.events.map, &ls.map);
    ls.unmap.notify = handleLayerSurfaceUnmap;
    c.wl_signal_add(&surface.events.unmap, &ls.unmap);
    ls.commit.notify = handleLayerSurfaceCommit;
    c.wl_signal_add(&surface.events.commit, &ls.commit);
    ls.destroy.notify = handleLayerSurfaceDestroy;
    c.wl_signal_add(&layer_surface.events.destroy, &ls.destroy);
    logInfo("new layer surface (layer {d})", .{layer});
}

/// レイヤー表面をアンカーに従って配置する。バーの予約領域 (usable_area) は
/// 現状フル領域で差し戻す (M5 でバーが予約する)
fn configureLayerSurface(ls: *LayerSurface) void {
    const size = layoutSize();
    var full: c.wlr_box = .{ .x = 0, .y = 0, .width = size.w, .height = size.h };
    var usable: c.wlr_box = .{ .x = 0, .y = 0, .width = size.w, .height = size.h };
    c.wlr_scene_layer_surface_v1_configure(ls.scene, &full, &usable);
    server.applyLayout();
}

fn handleLayerSurfaceMap(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = data;
    const ls: *LayerSurface = @fieldParentPtr("map", @as(*c.wl_listener, @ptrCast(listener)));
    configureLayerSurface(ls);
    // キーボード入力を欲するレイヤー (bemenu 等) にフォーカスを渡す
    if (ls.layer_surface.current.keyboard_interactive != c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE) {
        const surface: *c.wlr_surface = @ptrCast(ls.layer_surface.surface);
        _ = c.wlr_seat_keyboard_notify_enter(server.seat, surface, null, 0, null);
    }
}

fn handleLayerSurfaceUnmap(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = data;
    const ls: *LayerSurface = @fieldParentPtr("unmap", @as(*c.wl_listener, @ptrCast(listener)));
    // キーボードを窓へ返す
    if (ls.layer_surface.current.keyboard_interactive != c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE) {
        if (server.focused) |t| {
            const surface: *c.wlr_surface = @ptrCast(t.base.surface);
            _ = c.wlr_seat_keyboard_notify_enter(server.seat, surface, null, 0, null);
        } else {
            c.wlr_seat_keyboard_notify_clear_focus(server.seat);
        }
    }
}

fn handleLayerSurfaceCommit(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = data;
    const ls: *LayerSurface = @fieldParentPtr("commit", @as(*c.wl_listener, @ptrCast(listener)));
    if (ls.layer_surface.initial_commit) {
        _ = c.wlr_layer_surface_v1_configure(ls.layer_surface, 0, 0);
    } else {
        configureLayerSurface(ls);
    }
}

fn handleLayerSurfaceDestroy(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = data;
    const ls: *LayerSurface = @fieldParentPtr("destroy", @as(*c.wl_listener, @ptrCast(listener)));
    c.wl_list_remove(&ls.map.link);
    c.wl_list_remove(&ls.unmap.link);
    c.wl_list_remove(&ls.commit.link);
    c.wl_list_remove(&ls.destroy.link);
    server.gpa.destroy(ls);
}

// ---- XDG シェル (窓) ----

fn handleNewXdgToplevel(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = listener;
    // 0.19: new_surface は廃止。new_toplevel (data = wlr_xdg_toplevel) を使う
    const xdg_toplevel: *c.wlr_xdg_toplevel = @ptrCast(@alignCast(data.?));
    const base: *c.wlr_xdg_surface = @ptrCast(xdg_toplevel.base);

    const toplevel = server.gpa.create(Toplevel) catch return;
    toplevel.* = .{
        .xdg_toplevel = xdg_toplevel,
        .base = base,
        .scene_tree = c.wlr_scene_xdg_surface_create(&server.scene.tree, base) orelse {
            server.gpa.destroy(toplevel);
            return;
        },
        .focus_rect = undefined,
        .ws = server.active_ws,
        .map = undefined,
        .unmap = undefined,
        .commit = undefined,
        .destroy = undefined,
        .request_maximize = undefined,
        .request_fullscreen = undefined,
    };
    toplevel.scene_tree.node.data = toplevel;
    // popup の親解決用 (M2 で popup を扱うときに使う)
    base.data = toplevel.scene_tree;

    // フォーカスリング: 窓の背面に置く色付き矩形
    const dim: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 };
    toplevel.focus_rect = c.wlr_scene_rect_create(&server.scene.tree, 10, 10, &dim) orelse {
        server.gpa.destroy(toplevel);
        return;
    };
    c.wlr_scene_node_set_enabled(&toplevel.focus_rect.node, false);
    c.wlr_scene_node_place_below(&toplevel.focus_rect.node, &toplevel.scene_tree.node);
    // 窓とリングは上層レイヤーの下に保つ。注意: ring を layers_top の下へ
    // 追加で move すると窓の上に回ってしまう (リングが窓を隠す事故の原因)
    c.wlr_scene_node_place_below(&toplevel.scene_tree.node, &server.layers_top_tree.node);

    const surface: *c.wlr_surface = @ptrCast(base.surface);
    toplevel.map.notify = handleToplevelMap;
    c.wl_signal_add(&surface.events.map, &toplevel.map);
    toplevel.unmap.notify = handleToplevelUnmap;
    c.wl_signal_add(&surface.events.unmap, &toplevel.unmap);
    toplevel.commit.notify = handleToplevelCommit;
    c.wl_signal_add(&surface.events.commit, &toplevel.commit);
    toplevel.destroy.notify = handleToplevelDestroy;
    c.wl_signal_add(&xdg_toplevel.events.destroy, &toplevel.destroy);
    toplevel.request_maximize.notify = handleToplevelRequestMaximize;
    c.wl_signal_add(&xdg_toplevel.events.request_maximize, &toplevel.request_maximize);
    toplevel.request_fullscreen.notify = handleToplevelRequestFullscreen;
    c.wl_signal_add(&xdg_toplevel.events.request_fullscreen, &toplevel.request_fullscreen);
    // レイアウトに登録 (フォーカス列の隣へ新列, niri 式)
    server.activeLayout().addWindow(toplevel) catch {};
    server.toplevels.append(server.gpa, toplevel) catch {};
    server.applyLayout();
    logInfo("new toplevel (ws {d})", .{server.active_ws + 1});
}

// ---- XDG ポップアップ ----

fn handleNewXdgPopup(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = listener;
    const xdg_popup: *c.wlr_xdg_popup = @ptrCast(@alignCast(data.?));
    const popup = server.gpa.create(Popup) catch return;
    popup.* = .{
        .xdg_popup = xdg_popup,
        .commit = undefined,
        .destroy = undefined,
    };

    // 親の xdg surface から、toplevel 生成時に base->data へ入れた scene tree を得る
    const parent_surface: *c.wlr_surface = @ptrCast(xdg_popup.parent);
    const parent_xdg: *c.wlr_xdg_surface = @ptrCast(c.wlr_xdg_surface_try_from_wlr_surface(parent_surface) orelse {
        server.gpa.destroy(popup);
        return;
    });
    const parent_tree: *c.wlr_scene_tree = @ptrCast(@alignCast(parent_xdg.data));
    const popup_base: *c.wlr_xdg_surface = @ptrCast(xdg_popup.base);
    popup_base.data = c.wlr_scene_xdg_surface_create(parent_tree, popup_base);

    const popup_surface: *c.wlr_surface = @ptrCast(popup_base.surface);
    popup.commit.notify = handlePopupCommit;
    c.wl_signal_add(&popup_surface.events.commit, &popup.commit);
    popup.destroy.notify = handlePopupDestroy;
    c.wl_signal_add(&xdg_popup.events.destroy, &popup.destroy);
    logInfo("new popup", .{});
}

fn handlePopupCommit(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = data;
    const popup: *Popup = @fieldParentPtr("commit", @as(*c.wl_listener, @ptrCast(listener)));
    const popup_base: *c.wlr_xdg_surface = @ptrCast(popup.xdg_popup.base);
    if (popup_base.initial_commit) {
        _ = c.wlr_xdg_surface_schedule_configure(popup_base);
    }
}

fn handlePopupDestroy(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = data;
    const popup: *Popup = @fieldParentPtr("destroy", @as(*c.wl_listener, @ptrCast(listener)));
    c.wl_list_remove(&popup.commit.link);
    c.wl_list_remove(&popup.destroy.link);
    server.gpa.destroy(popup);
}

fn handleToplevelMap(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = data;
    const toplevel: *Toplevel = @fieldParentPtr("map", @as(*c.wl_listener, @ptrCast(listener)));
    logInfo("toplevel mapped: {s}", .{outputName_toplevel(toplevel)});
    dumpScene();
    focusToplevel(toplevel);
}

/// デバッグ: scene root の子ノードと窓の状態を吐く
fn dumpScene() void {
    var n: usize = 0;
    var it = server.scene.tree.children;
    while (it.prev != null) : (it = it.prev.?.*) {
        // 簡易: 先頭から数えるのは難しいので link を数えるだけ
        n += 1;
        if (n > 20) break;
    }
    var wins: usize = 0;
    for (server.toplevels.items) |t| {
        wins += 1;
        const s: *c.wlr_surface = @ptrCast(t.base.surface);
        const has_buffer = s.current.buffer != null;
        logInfo("win {s}: ws={d} enabled={any} mapped={any} buffer={any} size={d}x{d}", .{
            outputName_toplevel(t), t.ws + 1,
            t.scene_tree.node.enabled,
            s.mapped,
            has_buffer,
            s.current.width,
            s.current.height,
        });
    }
    logInfo("scene children(links counted)={d} toplevels={d}", .{ n, wins });
}

fn handleToplevelCommit(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = data;
    const toplevel: *Toplevel = @fieldParentPtr("commit", @as(*c.wl_listener, @ptrCast(listener)));
    // 0.19: initial commit にはコンポジタが configure で応答する義務がある。
    // これがないとクライアントは map せず待ち続ける (kitty が止まった原因)
    if (toplevel.base.initial_commit) {
        // configure サイズはレイアウトが決める (applyLayout 内の set_size)
        server.applyLayout();
    }
}

fn handleToplevelUnmap(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = data;
    const toplevel: *Toplevel = @fieldParentPtr("unmap", @as(*c.wl_listener, @ptrCast(listener)));
    logInfo("toplevel unmapped", .{});
    if (server.focused == toplevel) server.focused = null;
}

fn handleToplevelDestroy(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = data;
    const toplevel: *Toplevel = @fieldParentPtr("destroy", @as(*c.wl_listener, @ptrCast(listener)));
    c.wl_list_remove(&toplevel.map.link);
    c.wl_list_remove(&toplevel.unmap.link);
    c.wl_list_remove(&toplevel.commit.link);
    c.wl_list_remove(&toplevel.destroy.link);
    c.wl_list_remove(&toplevel.request_maximize.link);
    c.wl_list_remove(&toplevel.request_fullscreen.link);
    // フォーカスリングの矩形も破棄しないと画面に残る
    c.wlr_scene_node_destroy(&toplevel.focus_rect.node);
    server.workspaces[toplevel.ws].removeWindow(toplevel);
    for (server.toplevels.items, 0..) |t, i| {
        if (t == toplevel) {
            _ = server.toplevels.orderedRemove(i);
            break;
        }
    }
    if (server.focused == toplevel) server.focused = null;
    server.applyLayout();
    server.gpa.destroy(toplevel);
}

/// 最大化/フルスクリーン要求は M1 では全部「レイアウト全面」で応える
fn handleToplevelRequestMaximize(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = data;
    const toplevel: *Toplevel = @fieldParentPtr("request_maximize", @as(*c.wl_listener, @ptrCast(listener)));
    const size = layoutSize();
    _ = c.wlr_xdg_toplevel_set_size(toplevel.xdg_toplevel, size.w, size.h);
    _ = c.wlr_xdg_toplevel_set_maximized(toplevel.xdg_toplevel, true);
    _ = c.wlr_xdg_surface_schedule_configure(toplevel.base);
}

fn handleToplevelRequestFullscreen(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = data;
    const toplevel: *Toplevel = @fieldParentPtr("request_fullscreen", @as(*c.wl_listener, @ptrCast(listener)));
    const size = layoutSize();
    _ = c.wlr_xdg_toplevel_set_size(toplevel.xdg_toplevel, size.w, size.h);
    _ = c.wlr_xdg_toplevel_set_fullscreen(toplevel.xdg_toplevel, true);
    _ = c.wlr_xdg_surface_schedule_configure(toplevel.base);
}

fn focusToplevel(toplevel: *Toplevel) void {
    // クリック等で別ワークスペースの窓が指定されたら切替 (通常は表示中と同一)
    if (toplevel.ws != server.active_ws) {
        server.active_ws = toplevel.ws;
    }
    if (server.focused) |prev| {
        if (prev != toplevel) {
            _ = c.wlr_xdg_toplevel_set_activated(prev.xdg_toplevel, false);
        }
    }
    server.focused = toplevel;
    _ = c.wlr_xdg_toplevel_set_activated(toplevel.xdg_toplevel, true);
    const surface: *c.wlr_surface = @ptrCast(toplevel.base.surface);
    _ = c.wlr_seat_keyboard_notify_enter(server.seat, surface, null, 0, null);
    server.applyLayout();
}

fn layoutSize() struct { w: i32, h: i32 } {
    // 0.19 から get_box は呼び出し側の box に書き込む方式
    var box: c.wlr_box = std.mem.zeroes(c.wlr_box);
    c.wlr_output_layout_get_box(server.output_layout, null, &box);
    if (box.width > 0 and box.height > 0) {
        return .{ .w = box.width, .h = box.height };
    }
    return .{ .w = 1024, .h = 768 };
}

/// デバッグ用: toplevel の app_id を取る (取れなければ仮名)
fn outputName_toplevel(toplevel: *Toplevel) []const u8 {
    if (toplevel.xdg_toplevel.app_id) |app_id| return std.mem.span(app_id);
    return "(no app-id)";
}

// ---- ポインタ ----

fn handleCursorMotion(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = listener;
    const event: *c.wlr_pointer_motion_event = @ptrCast(@alignCast(data.?));
    const pointer: *c.wlr_pointer = @ptrCast(event.pointer);
    c.wlr_cursor_move(server.cursor, &pointer.base, event.delta_x, event.delta_y);
    c.wlr_cursor_set_xcursor(server.cursor, server.xcursor_manager, "default");
    processPointerMotion(event.time_msec);
}

fn handleCursorMotionAbsolute(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = listener;
    const event: *c.wlr_pointer_motion_absolute_event = @ptrCast(@alignCast(data.?));
    const pointer: *c.wlr_pointer = @ptrCast(event.pointer);
    c.wlr_cursor_warp_absolute(server.cursor, &pointer.base, event.x, event.y);
    c.wlr_cursor_set_xcursor(server.cursor, server.xcursor_manager, "default");
    processPointerMotion(event.time_msec);
}

fn processPointerMotion(time_msec: u32) void {
    // ドラッグ中: 浮動窓の移動/リサイズ
    if (server.cursor_mode != .passthrough) {
        if (server.grabbed) |t| {
            const vx: i32 = @intFromFloat(server.viewport_x);
            if (server.cursor_mode == .move) {
                t.fx = @as(i32, @intFromFloat(server.cursor.x)) + @as(i32, @intFromFloat(server.grab_x)) - vx;
                t.fy = @as(i32, @intFromFloat(server.cursor.y)) + @as(i32, @intFromFloat(server.grab_y));
            } else {
                t.fw = @max(@as(i32, @intFromFloat(server.cursor.x)) - t.fx + vx, 100);
                t.fh = @max(@as(i32, @intFromFloat(server.cursor.y)) - t.fy, 100);
                _ = c.wlr_xdg_toplevel_set_size(t.xdg_toplevel, t.fw, t.fh);
            }
            server.applyLayout();
        }
        return;
    }
    var sx: f64 = 0;
    var sy: f64 = 0;
    const node_raw = c.wlr_scene_node_at(&server.scene.tree.node, server.cursor.x, server.cursor.y, &sx, &sy);
    if (node_raw == null) {
        c.wlr_seat_pointer_notify_clear_focus(server.seat);
        return;
    }
    const node: *c.wlr_scene_node = @ptrCast(node_raw);
    if (node.type != c.WLR_SCENE_NODE_BUFFER) {
        c.wlr_seat_pointer_notify_clear_focus(server.seat);
        return;
    }
    const scene_buffer: *c.wlr_scene_buffer = @ptrCast(node);
    const scene_surface_raw = c.wlr_scene_surface_try_from_buffer(scene_buffer);
    if (scene_surface_raw == null) {
        c.wlr_seat_pointer_notify_clear_focus(server.seat);
        return;
    }
    const scene_surface: *c.wlr_scene_surface = @ptrCast(scene_surface_raw);
    c.wlr_seat_pointer_notify_enter(server.seat, scene_surface.surface, sx, sy);
    c.wlr_seat_pointer_notify_motion(server.seat, time_msec, sx, sy);
}

fn handleCursorButton(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = listener;
    const event: *c.wlr_pointer_button_event = @ptrCast(@alignCast(data.?));

    if (event.state == c.WL_POINTER_BUTTON_STATE_PRESSED) {
        // Mod+ボタンで浮動窓の移動/リサイズを開始 (SPEC §5)
        const mods = c.wlr_keyboard_get_modifiers(c.wlr_seat_get_keyboard(server.seat));
        const target = toplevelAtCursor();
        if ((mods & MODIFIER) != 0 and target != null and target.?.floating) {
            const t = target.?;
            const vx: i32 = @intFromFloat(server.viewport_x);
            server.grabbed = t;
            if (event.button == 0x110) { // BTN_LEFT
                server.cursor_mode = .move;
                server.grab_x = @floatFromInt(t.fx - vx - @as(i32, @intFromFloat(server.cursor.x)));
                server.grab_y = @floatFromInt(t.fy - @as(i32, @intFromFloat(server.cursor.y)));
            } else if (event.button == 0x111) { // BTN_RIGHT
                server.cursor_mode = .resize;
                server.grab_w = t.fw;
                server.grab_h = t.fh;
            }
            focusToplevel(t);
            return;
        }
        // 通常クリック: フォーカス
        if (target) |t| focusToplevel(t);
    } else {
        // ボタン解放でドラッグ終了
        if (server.cursor_mode != .passthrough) {
            server.cursor_mode = .passthrough;
            server.grabbed = null;
        }
    }
    _ = c.wlr_seat_pointer_notify_button(server.seat, event.time_msec, event.button, event.state);
}

/// カーソル位置にある Toplevel を scene 経由で探す
fn toplevelAtCursor() ?*Toplevel {
    var sx: f64 = 0;
    var sy: f64 = 0;
    const node_raw = c.wlr_scene_node_at(&server.scene.tree.node, server.cursor.x, server.cursor.y, &sx, &sy);
    if (node_raw == null) return null;
    const node: *c.wlr_scene_node = @ptrCast(node_raw);
    if (node.type != c.WLR_SCENE_NODE_BUFFER) return null;
    const buf: *c.wlr_scene_buffer = @ptrCast(node);
    if (c.wlr_scene_surface_try_from_buffer(buf) == null) return null;
    var cur: [*c]c.wlr_scene_tree = node.parent;
    while (cur != null) {
        const tree: *c.wlr_scene_tree = @ptrCast(cur);
        if (tree.node.data) |d| return @ptrCast(@alignCast(d));
        cur = tree.node.parent;
    }
    return null;
}

// ---- 終了 ----

fn handleSigint(sig: c_int) callconv(.c) void {
    _ = sig;
    c.wl_display_terminate(server.display);
}
