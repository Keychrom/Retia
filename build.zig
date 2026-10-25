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

    // wlroots は C ライブラリ。パッケージ名はバージョン付き (wlroots-0.19) なので注意
    const cflags = b.run(&.{ "pkg-config", "--cflags", "wlroots-0.19" });
    var cflags_it = std.mem.tokenizeScalar(u8, cflags, ' ');
    while (cflags_it.next()) |flag| {
        if (std.mem.startsWith(u8, flag, "-I")) {
            exe.root_module.addIncludePath(.{ .cwd_relative = flag[2..] });
        }
    }

    const libs = b.run(&.{ "pkg-config", "--libs", "wlroots-0.19" });
    var libs_it = std.mem.tokenizeScalar(u8, libs, ' ');
    while (libs_it.next()) |flag| {
        if (std.mem.startsWith(u8, flag, "-l")) {
            exe.root_module.linkSystemLibrary(flag[2..], .{});
        } else if (std.mem.startsWith(u8, flag, "-L")) {
            exe.root_module.addLibraryPath(.{ .cwd_relative = flag[2..] });
        }
    }

    // wlroots のヘッダは WLR_USE_UNSTABLE なしでは include できない
    exe.root_module.addCMacro("WLR_USE_UNSTABLE", "1");

    b.installArtifact(exe);
}
