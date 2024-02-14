const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const clap = b.addModule("clap", .{
        .source_file = .{ .path = "src/ext/clap.zig" },
    });

    const gui_shared = b.addModule("gui_shared", .{
        .source_file = .{ .path = "src/gui_shared.zig" },
    });

    const gui = switch (target.getOsTag()) {
        .linux => blk: {
            std.log.info("Building for linux...", .{});
            break :blk b.addModule("gui", .{
                .source_file = .{ .path = "src/platform/linux/gui.zig" },
                .dependencies = &.{
                    .{
                        .name = "clap",
                        .module = clap,
                    },
                    .{
                        .name = "gui_shared",
                        .module = gui_shared,
                    },
                },
            });
        },
        .macos => {
            std.log.err("MacOS not supported!", .{});
            return;
        },
        .windows => {
            std.log.err("Windows not supported!", .{});
            return;
        },
        else => return,
    };

    const text = switch (target.getOsTag()) {
        .linux => b.addModule("gui", .{
            .source_file = .{ .path = "src/platform/linux/text.zig" },
            .dependencies = &.{
                .{
                    .name = "gui_shared",
                    .module = gui_shared,
                },
            },
        }),
        .macos => {
            std.log.err("MacOS not supported!", .{});
            return;
        },
        .windows => {
            std.log.err("Windows not supported!", .{});
            return;
        },
        else => return,
    };

    const lib = b.addSharedLibrary(.{
        .name = "HelloCLAP_zig.clap",
        .root_source_file = .{ .path = "src/plugin.zig" },
        .target = target,
        .optimize = optimize,
    });

    lib.addModule("gui", gui);
    lib.addModule("text", text);
    lib.addModule("clap", clap);

    switch (target.getOsTag()) {
        .linux => {
            lib.linkSystemLibrary("X11");
            lib.linkSystemLibrary("freetype2");
        },
        .macos => {
            std.log.err("MacOS not supported!", .{});
            return;
        },
        .windows => {
            std.log.err("Windows not supported!", .{});
            return;
        },
        else => {
            std.log.err("Unsupported OS!", .{});
            return;
        },
    }

    lib.linkLibC();
    b.installArtifact(lib);
}
