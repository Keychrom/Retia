const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "retia",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    // ---- wlroots (pkg-config。パッケージ名はバージョン付き wlroots-0.19) ----
    const pkg_name = "wlroots-0.19";

    var wlr_include_dir: ?[]const u8 = null;

    // b.run() の出力には末尾の改行が含まれるため、区切りに改行も含める
    const cflags = b.run(&.{ "pkg-config", "--cflags", pkg_name });
    var cflags_it = std.mem.tokenizeAny(u8, cflags, " \t\r\n");
    while (cflags_it.next()) |flag| {
        if (std.mem.startsWith(u8, flag, "-I")) {
            const dir = flag[2..];
            exe.root_module.addIncludePath(.{ .cwd_relative = dir });
            // wlr ヘッダのディレクトリを覚えておく (下のプロトコルヘッダ検出で使う)
            if (std.mem.endsWith(u8, dir, "/" ++ pkg_name)) wlr_include_dir = dir;
        }
    }

    const libs = b.run(&.{ "pkg-config", "--libs", pkg_name });
    var libs_it = std.mem.tokenizeAny(u8, libs, " \t\r\n");
    while (libs_it.next()) |flag| {
        if (std.mem.startsWith(u8, flag, "-l")) {
            exe.root_module.linkSystemLibrary(flag[2..], .{});
        } else if (std.mem.startsWith(u8, flag, "-L")) {
            exe.root_module.addLibraryPath(.{ .cwd_relative = flag[2..] });
        }
    }

    // wlroots のヘッダは WLR_USE_UNSTABLE なしでは include できない
    exe.root_module.addCMacro("WLR_USE_UNSTABLE", "1");

    // ---- プロトコルヘッダの生成 (wayland-scanner) ----
    //
    // wlroots 0.19 は生成済みプロトコルヘッダをインストールしない設計。
    // wlr ヘッダは `#include "xdg-shell-protocol.h"` のように生成ヘッダを直接
    // 引くため、コンポジタ側で生成して include パスに載せる (river 方式)。
    // XML の所在: wayland-protocols パッケージの pkgdatadir と、
    // wlroots ソースツリー同梱の protocol/ ディレクトリ。
    const inc = wlr_include_dir orelse
        std.debug.panic("pkg-config '{s}' の cflags に include ディレクトリが無い", .{pkg_name});

    // インストール済み wlr ヘッダが参照している生成ヘッダ名を収集
    const grep_cmd = std.fmt.allocPrint(
        b.allocator,
        "grep -rhoE '#include \"[a-zA-Z0-9_-]+-protocol\\.h\"' '{s}' | sort -u",
        .{inc},
    ) catch unreachable;
    const refs = b.run(&.{ "sh", "-c", grep_cmd });

    const wlr_protocol_dir = b.option(
        []const u8,
        "wlroots-protocol-dir",
        "wlroots ソースツリーの protocol/ ディレクトリ (既定: $HOME/src/wlroots/protocol)",
    ) orelse std.mem.trim(
        u8,
        b.run(&.{ "sh", "-c", "echo $HOME/src/wlroots/protocol" }),
        " \t\r\n",
    );

    const wl_protocols_dir = std.mem.trim(
        u8,
        b.run(&.{ "pkg-config", "--variable=pkgdatadir", "wayland-protocols" }),
        " \t\r\n",
    );

    std.fs.cwd().makePath("zig-out/gen") catch {};

    var gen_steps: [128]*std.Build.Step = undefined;
    var gen_n: usize = 0;

    var lines = std.mem.tokenizeAny(u8, refs, "\r\n");
    while (lines.next()) |line| {
        const q1 = std.mem.indexOfScalar(u8, line, '"') orelse continue;
        const q2 = std.mem.lastIndexOfScalar(u8, line, '"') orelse continue;
        if (q2 <= q1 + 1) continue;
        const header_name = line[q1 + 1 .. q2];

        // xdg-shell-protocol.h → xdg-shell.xml
        const suffix = "-protocol.h";
        if (!std.mem.endsWith(u8, header_name, suffix)) continue;
        const xml_name = std.fmt.allocPrint(
            b.allocator,
            "{s}.xml",
            .{header_name[0 .. header_name.len - suffix.len]},
        ) catch unreachable;

        const find_cmd = std.fmt.allocPrint(
            b.allocator,
            "find '{s}' '{s}' -name '{s}' 2>/dev/null | head -n1",
            .{ wl_protocols_dir, wlr_protocol_dir, xml_name },
        ) catch unreachable;
        const xml = std.mem.trim(u8, b.run(&.{ "sh", "-c", find_cmd }), " \t\r\n");
        if (xml.len == 0) {
            std.debug.print("warning: protocol XML not found: {s}\n", .{xml_name});
            continue;
        }

        const out_path = std.fmt.allocPrint(
            b.allocator,
            "zig-out/gen/{s}",
            .{header_name},
        ) catch unreachable;
        const gen = b.addSystemCommand(&.{ "wayland-scanner", "server-header", xml, out_path });
        gen_steps[gen_n] = gen.step;
        gen_n += 1;
        if (gen_n == gen_steps.len) break;
    }

    if (gen_n > 0) {
        exe.root_module.addIncludePath(b.path("zig-out/gen"));
        for (gen_steps[0..gen_n]) |step| exe.step.dependOn(step);
    }

    b.installArtifact(exe);
}
