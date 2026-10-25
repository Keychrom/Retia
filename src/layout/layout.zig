//! Scrollable Columns レイアウトエンジン (SPEC §4)。
//!
//! wlroots に依存しない純粋な状態機械。Window は呼び出し側が定義するハンドル型
//! (実装では *Toplevel、テストではダミー) をジェネリクスで受ける。
//! すべての操作は「状態 + 操作 → 新状態」で、描画は呼び出し側が
//! windowBoxes()/viewportTargetX() を読んで scene node に反映する。
//!
//! 不変条件:
//!   - 窓が 1 つ以上ある限り、focused_column は有効な列を指す
//!   - focused_column の focused_window は有効な窓を指す
//!   - 空の列は存在しない (削除時に畳む)
//!   - 新規窓はフォーカス列の隣に新しい列として開く (niri 互換, SPEC §4.2【決定】)

const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn Layout(comptime Window: type) type {
    return struct {
        const Self = @This();

        pub const Column = struct {
            windows: std.ArrayList(Window) = .empty,
            /// 出力幅に対する幅の比率 (preset 幅でサイクルする)
            width_ratio: f32 = 0.5,
            /// 最大化前の比率 (toggleMaximizeColumn 用)
            prev_ratio: f32 = 0,

            fn deinit(self: *Column, allocator: Allocator) void {
                self.windows.deinit(allocator);
            }
        };

        /// 設定可能な列幅プリセット (Mod+R でサイクル)
        pub const width_presets: []const f32 = &.{ 1.0 / 3.0, 1.0 / 2.0, 2.0 / 3.0 };

        columns: std.ArrayList(Column) = .empty,
        focused_column: usize = 0,
        focused_window: usize = 0,
        usable_w: i32 = 1280,
        usable_h: i32 = 720,
        gap: i32 = 8,

        allocator: Allocator,

        pub fn init(allocator: Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            for (self.columns.items) |*col| col.deinit(self.allocator);
            self.columns.deinit(self.allocator);
        }

        pub fn setUsableSize(self: *Self, w: i32, h: i32) void {
            self.usable_w = w;
            self.usable_h = h;
        }

        fn focusedColumnPtr(self: *Self) *Column {
            return &self.columns.items[self.focused_column];
        }

        pub fn focusedWindow(self: *Self) ?Window {
            if (self.columns.items.len == 0) return null;
            const col = self.focusedColumnPtr();
            if (col.windows.items.len == 0) return null;
            return col.windows.items[self.focused_window];
        }

        // ---- 窓の追加・削除 ----

        /// 新規窓: フォーカス列の隣に新しい列として開く (niri 互換【決定】)。
        /// レイアウトが空のときは全面幅 (M1 からの見た目を維持)、 otherwise 0.5
        pub fn addWindow(self: *Self, window: Window) !void {
            const ratio: f32 = if (self.columns.items.len == 0) 1.0 else 0.5;
            var col = Column{ .width_ratio = ratio };
            try col.windows.append(self.allocator, window);
            const insert_idx = @min(self.focused_column + 1, self.columns.items.len);
            try self.columns.insert(self.allocator, insert_idx, col);
            self.focused_column = insert_idx;
            self.focused_window = 0;
        }

        /// 窓がどこかの列から消えたときに呼ぶ (close 等)。フォーカスを修復する。
        pub fn removeWindow(self: *Self, window: Window) void {
            for (self.columns.items, 0..) |*col, ci| {
                for (col.windows.items, 0..) |w, wi| {
                    if (w != window) continue;
                    _ = col.windows.orderedRemove(wi);

                    if (col.windows.items.len == 0) {
                        // 空になった列の確保済み capacity を解放してから畳む
                        col.deinit(self.allocator);
                        _ = self.columns.orderedRemove(ci);
                        self.clampFocusAfterColumnRemoval(ci);
                    } else {
                        // 同一列内でフォーカスを修復
                        if (ci == self.focused_column) {
                            self.focused_window = @min(self.focused_window, col.windows.items.len - 1);
                        }
                    }
                    return;
                }
            }
        }

        fn clampFocusAfterColumnRemoval(self: *Self, removed_idx: usize) void {
            if (self.columns.items.len == 0) {
                self.focused_column = 0;
                self.focused_window = 0;
                return;
            }
            if (removed_idx < self.focused_column) {
                self.focused_column -= 1;
            } else if (removed_idx == self.focused_column) {
                // 消えたのはフォーカス列 → 同位置の列 (元は右隣) にフォーカス
                self.focused_column = @min(self.focused_column, self.columns.items.len - 1);
                self.focused_window = 0;
            }
        }

        // ---- フォーカス移動 ----

        pub fn focusColumnLeft(self: *Self) void {
            self.focused_column -|= 1;
            self.focused_window = 0;
        }

        pub fn focusColumnRight(self: *Self) void {
            if (self.focused_column + 1 < self.columns.items.len) {
                self.focused_column += 1;
            }
            self.focused_window = 0;
        }

        pub fn focusWindowUp(self: *Self) void {
            self.focused_window -|= 1;
        }

        pub fn focusWindowDown(self: *Self) void {
            const col = self.focusedColumnPtr();
            if (self.focused_window + 1 < col.windows.items.len) {
                self.focused_window += 1;
            }
        }

        pub fn focusColumnFirst(self: *Self) void {
            self.focused_column = 0;
            self.focused_window = 0;
        }

        pub fn focusColumnLast(self: *Self) void {
            self.focused_column = self.columns.items.len -| 1;
            self.focused_window = 0;
        }

        // ---- 移動 ----

        pub fn moveColumnLeft(self: *Self) void {
            if (self.focused_column == 0) return;
            std.mem.swap(Column, &self.columns.items[self.focused_column], &self.columns.items[self.focused_column - 1]);
            self.focused_column -= 1;
        }

        pub fn moveColumnRight(self: *Self) void {
            if (self.focused_column + 1 >= self.columns.items.len) return;
            std.mem.swap(Column, &self.columns.items[self.focused_column], &self.columns.items[self.focused_column + 1]);
            self.focused_column += 1;
        }

        pub fn moveWindowUp(self: *Self) void {
            if (self.focused_window == 0) return;
            const col = self.focusedColumnPtr();
            std.mem.swap(Window, &col.windows.items[self.focused_window], &col.windows.items[self.focused_window - 1]);
            self.focused_window -= 1;
        }

        pub fn moveWindowDown(self: *Self) void {
            const col = self.focusedColumnPtr();
            if (self.focused_window + 1 >= col.windows.items.len) return;
            std.mem.swap(Window, &col.windows.items[self.focused_window], &col.windows.items[self.focused_window + 1]);
            self.focused_window += 1;
        }

        // ---- consume / expel (niri セマンティクス) ----

        /// 左方向: 左列が無ければ窓を切り出して左に新列 (expel)。
        /// 左列が 1 窓なら列ごと吸収、複数ならその末尾の窓を取り込む (consume)。
        pub fn consumeOrExpelLeft(self: *Self) !void {
            if (self.focused_column == 0) {
                // expel: フォーカス列が 2 窓以上のとき、フォーカス窓を左へ新列として切り出す
                const col = self.focusedColumnPtr();
                if (col.windows.items.len < 2) return;
                const w = col.windows.orderedRemove(self.focused_window);
                var new_col = Column{ .width_ratio = col.width_ratio };
                try new_col.windows.append(self.allocator, w);
                try self.columns.insert(self.allocator, self.focused_column, new_col);
                self.focused_window = 0;
                return;
            }
            const left = &self.columns.items[self.focused_column - 1];
            if (left.windows.items.len == 1) {
                // 吸収: 左列の窓をフォーカス窓の直前に挿入し、左列を畳む。
                // フォーカスは元の窓に留まる
                const w = left.windows.pop().?;
                try self.focusedColumnPtr().windows.insert(self.allocator, self.focused_window, w);
                self.focused_window += 1;
                left.deinit(self.allocator); // 空リストの capacity を解放
                _ = self.columns.orderedRemove(self.focused_column - 1);
                self.focused_column -= 1;
            } else {
                // 取り込み: 左列の末尾の窓をフォーカス窓の直前に挿入
                const w = left.windows.pop().?;
                try self.focusedColumnPtr().windows.insert(self.allocator, self.focused_window, w);
                self.focused_window += 1;
            }
        }

        /// 右方向 (consumeOrExpelLeft の鏡像)。
        pub fn consumeOrExpelRight(self: *Self) !void {
            if (self.focused_column + 1 >= self.columns.items.len) {
                const col = self.focusedColumnPtr();
                if (col.windows.items.len < 2) return;
                const w = col.windows.orderedRemove(self.focused_window);
                var new_col = Column{ .width_ratio = col.width_ratio };
                try new_col.windows.append(self.allocator, w);
                try self.columns.insert(self.allocator, self.focused_column + 1, new_col);
                self.focused_window = 0;
                return;
            }
            const right_idx = self.focused_column + 1;
            const right = &self.columns.items[right_idx];
            const col = self.focusedColumnPtr();
            if (right.windows.items.len == 1) {
                const w = right.windows.pop().?;
                try col.windows.insert(self.allocator, self.focused_window + 1, w);
                right.deinit(self.allocator); // 空リストの capacity を解放
                _ = self.columns.orderedRemove(right_idx);
            } else {
                const w = right.windows.orderedRemove(0);
                try col.windows.insert(self.allocator, self.focused_window + 1, w);
            }
        }

        // ---- 幅 ----

        /// フォーカス列の幅をプリセットでサイクル (1/3 → 1/2 → 2/3 → 1/3)
        pub fn cycleColumnWidth(self: *Self) void {
            const col = self.focusedColumnPtr();
            const current = col.width_ratio;
            var next = width_presets[0];
            for (width_presets) |p| {
                if (p > current + 0.001) {
                    next = p;
                    break;
                }
            }
            col.width_ratio = next;
        }

        /// フォーカス列の最大化トグル (全面 ↔ 直前の比率)
        pub fn toggleMaximizeColumn(self: *Self) void {
            const col = self.focusedColumnPtr();
            if (col.width_ratio >= 0.999) {
                col.width_ratio = if (col.prev_ratio > 0) col.prev_ratio else 0.5;
                col.prev_ratio = 0;
            } else {
                col.prev_ratio = col.width_ratio;
                col.width_ratio = 1.0;
            }
        }

        // ---- 列の引き抜き・追加 (ワークスペース間移動用) ----

        pub fn takeFocusedColumn(self: *Self) ?Column {
            if (self.columns.items.len == 0) return null;
            const col = self.columns.orderedRemove(self.focused_column);
            self.clampFocusAfterColumnRemoval(self.focused_column);
            return col;
        }

        pub fn appendColumn(self: *Self, col: Column) !void {
            try self.columns.append(self.allocator, col);
            self.focused_column = self.columns.items.len - 1;
            self.focused_window = 0;
        }

        // ---- 幾何 ----

        pub fn columnWidthPx(self: *Self, idx: usize) i32 {
            return self.columnWidthFor(&self.columns.items[idx]);
        }

        fn columnWidthFor(self: *Self, col: *const Column) i32 {
            const inner_w = @max(self.usable_w - 2 * self.gap, 1);
            return @max(@as(i32, @intFromFloat(col.width_ratio * @as(f32, @floatFromInt(inner_w)))), 1);
        }

        /// 列 idx のストリップ上での x 座標 (viewport 適用前)
        pub fn columnX(self: *Self, idx: usize) i32 {
            var acc: i32 = self.gap;
            var i: usize = 0;
            while (i < idx) : (i += 1) {
                acc += self.columnWidthPx(i) + self.gap;
            }
            return acc;
        }

        /// ストリップ全体の幅
        pub fn stripWidth(self: *Self) i32 {
            if (self.columns.items.len == 0) return self.usable_w;
            var w: i32 = self.gap;
            for (self.columns.items, 0..) |_, i| {
                w += self.columnWidthPx(i) + self.gap;
            }
            return w;
        }

        /// フォーカス列が見える viewport の目标 x (clamp 済み)。
        /// アニメーションは呼び出し側 (コンポジタ) がこの値へイージングする。
        pub fn viewportTargetX(self: *Self) i32 {
            if (self.columns.items.len == 0) return 0;
            const focus_x = self.columnX(self.focused_column);
            const focus_w = self.columnWidthPx(self.focused_column);
            const max_scroll = @max(self.stripWidth() - self.usable_w, 0);
            // フォーカス列が画面に収まるなら中央寄り、はみ出すなら左端に寄せる
            var target: i32 = focus_x - @divTrunc(self.usable_w - focus_w, 2);
            target = @max(target, 0);
            return @min(target, max_scroll);
        }

        pub const WindowBox = struct {
            window: Window,
            x: i32,
            y: i32,
            w: i32,
            h: i32,
        };

        /// 全窓のストリップ座標 (viewport 適用前)。呼び出し側が viewportX を引いて使う。
        pub fn windowBoxes(self: *Self, allocator: Allocator) ![]WindowBox {
            var boxes: std.ArrayList(WindowBox) = .empty;
            errdefer boxes.deinit(allocator);
            var x: i32 = self.gap;
            for (self.columns.items) |*col| {
                const col_w = self.columnWidthFor(col);
                const n = col.windows.items.len;
                if (n == 0) {
                    x += col_w + self.gap;
                    continue;
                }
                const col_h = self.usable_h - 2 * self.gap;
                const win_h = @divTrunc(col_h - self.gap * (@as(i32, @intCast(n)) - 1), @as(i32, @intCast(n)));
                var y: i32 = self.gap;
                for (col.windows.items) |w| {
                    try boxes.append(allocator, .{ .window = w, .x = x, .y = y, .w = col_w, .h = win_h });
                    y += win_h + self.gap;
                }
                x += col_w + self.gap;
            }
            return boxes.toOwnedSlice(allocator);
        }
    };
}

const testing = std.testing;

const TestWindow = struct {
    id: u32,
};

test "addWindow: niri 式にフォーカス列の隣へ新列" {
    const a = testing.allocator;
    var w1 = TestWindow{ .id = 1 };
    var w2 = TestWindow{ .id = 2 };
    var w3 = TestWindow{ .id = 3 };

    var l = Layout(*TestWindow).init(a);
    defer l.deinit();

    try l.addWindow(&w1);
    try l.addWindow(&w2);
    try l.addWindow(&w3);

    try testing.expectEqual(@as(usize, 3), l.columns.items.len);
    try testing.expectEqual(@as(usize, 2), l.focused_column);
    try testing.expectEqual(&w3, l.focusedWindow().?);
}

test "focus 移動は端で止まる" {
    const a = testing.allocator;
    var w1 = TestWindow{ .id = 1 };
    var l = Layout(*TestWindow).init(a);
    defer l.deinit();
    try l.addWindow(&w1);

    l.focusColumnLeft(); // 1 列しかない → 止まる
    l.focusColumnRight();
    try testing.expectEqual(@as(usize, 0), l.focused_column);
}

test "consumeOrExpelLeft: 左列 1 窓なら吸収" {
    const a = testing.allocator;
    var w1 = TestWindow{ .id = 1 };
    var w2 = TestWindow{ .id = 2 };
    var l = Layout(*TestWindow).init(a);
    defer l.deinit();
    try l.addWindow(&w1);
    try l.addWindow(&w2); // [w1][w2] フォーカス=右

    try l.consumeOrExpelLeft();

    try testing.expectEqual(@as(usize, 1), l.columns.items.len);
    try testing.expectEqual(@as(usize, 2), l.focusedColumnPtr().windows.items.len);
    try testing.expectEqual(&w1, l.focusedColumnPtr().windows.items[0]);
    try testing.expectEqual(&w2, l.focusedColumnPtr().windows.items[1]);
    try testing.expectEqual(&w2, l.focusedWindow().?);
}

test "consumeOrExpelLeft: 左列なしなら expel (左へ新列)" {
    const a = testing.allocator;
    var w1 = TestWindow{ .id = 1 };
    var w2 = TestWindow{ .id = 2 };
    var l = Layout(*TestWindow).init(a);
    defer l.deinit();
    try l.addWindow(&w1);
    try l.addWindow(&w2); // [w1][w2] フォーカス=col1(w2)

    // col0 (w1) へフォーカス → 左列なし & 1 窓 → no-op
    l.focusColumnLeft();
    try l.consumeOrExpelLeft();
    try testing.expectEqual(@as(usize, 2), l.columns.items.len);

    // col0 を 2 窓にする: col1 から w2 を吸収
    try l.consumeOrExpelRight();
    try testing.expectEqual(@as(usize, 1), l.columns.items.len);
    try testing.expectEqual(@as(usize, 2), l.focusedColumnPtr().windows.items.len);

    // 左列なし & 2 窓 → expel: フォーカス窓 (w1) が左へ新列
    try l.consumeOrExpelLeft();
    try testing.expectEqual(@as(usize, 2), l.columns.items.len);
    try testing.expectEqual(@as(usize, 0), l.focused_column);
    try testing.expectEqual(&w1, l.focusedWindow().?);
    try testing.expectEqual(&w2, l.columns.items[1].windows.items[0]);
}

test "removeWindow: フォーカス修復と空列の畳み" {
    const a = testing.allocator;
    var w1 = TestWindow{ .id = 1 };
    var w2 = TestWindow{ .id = 2 };
    var w3 = TestWindow{ .id = 3 };
    var l = Layout(*TestWindow).init(a);
    defer l.deinit();
    try l.addWindow(&w1);
    try l.addWindow(&w2);
    try l.addWindow(&w3);

    l.removeWindow(&w2); // 中間列を削除 → 右隣にフォーカス
    try testing.expectEqual(@as(usize, 2), l.columns.items.len);
    try testing.expectEqual(@as(usize, 1), l.focused_column);
    try testing.expectEqual(&w3, l.focusedWindow().?);

    l.removeWindow(&w3);
    try testing.expectEqual(@as(usize, 1), l.columns.items.len);
    try testing.expectEqual(&w1, l.focusedWindow().?);
}

test "cycleColumnWidth: 1/3 → 1/2 → 2/3 → 1/3" {
    const a = testing.allocator;
    var w1 = TestWindow{ .id = 1 };
    var l = Layout(*TestWindow).init(a);
    defer l.deinit();
    try l.addWindow(&w1);

    const col = l.focusedColumnPtr();
    col.width_ratio = 0.5; // 新規列は空レイアウト時 ratio 1.0 で作られるため揃える
    l.cycleColumnWidth();
    try testing.expectApproxEqAbs(@as(f32, 2.0 / 3.0), col.width_ratio, 0.001);
    l.cycleColumnWidth();
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 3.0), col.width_ratio, 0.001);
    l.cycleColumnWidth();
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 2.0), col.width_ratio, 0.001);
}

test "geometry: 単窓は gap を除いて全面" {
    const a = testing.allocator;
    var w1 = TestWindow{ .id = 1 };
    var l = Layout(*TestWindow).init(a);
    defer l.deinit();
    l.setUsableSize(1280, 720);
    try l.addWindow(&w1);

    const boxes = try l.windowBoxes(a);
    defer a.free(boxes);
    try testing.expectEqual(@as(usize, 1), boxes.len);
    try testing.expectEqual(l.gap, boxes[0].x);
    try testing.expectEqual(l.gap, boxes[0].y);
    try testing.expectEqual(@as(i32, 1280 - 16), boxes[0].w);
    try testing.expectEqual(@as(i32, 720 - 16), boxes[0].h);
    try testing.expectEqual(@as(i32, 0), l.viewportTargetX());
}

test "geometry: 3 列でスクロール target が clamp される" {
    const a = testing.allocator;
    var w1 = TestWindow{ .id = 1 };
    var w2 = TestWindow{ .id = 2 };
    var w3 = TestWindow{ .id = 3 };
    var l = Layout(*TestWindow).init(a);
    defer l.deinit();
    l.setUsableSize(1280, 720);
    try l.addWindow(&w1);
    try l.addWindow(&w2);
    try l.addWindow(&w3);

    // フォーカスは最右 → viewport は右端に clamp
    const target = l.viewportTargetX();
    const max_scroll = l.stripWidth() - l.usable_w;
    try testing.expect(target <= max_scroll);
    try testing.expect(target > 0);

    // フォーカスを最左へ → viewport 0
    l.focusColumnFirst();
    try testing.expectEqual(@as(i32, 0), l.viewportTargetX());
}
