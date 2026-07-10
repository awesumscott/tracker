// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Scott Lowe
const std = @import("std");

// `tracker` — the in-repo issue-tracker host tool (Wave 2: library + store +
// the `trk` CLI + the render/tree projections + host unit tests). Std-only, no
// OS-specific syscalls beyond std.Io, so it cross-compiles cleanly (verified
// with `zig build -Dtarget=x86_64-windows-gnu`).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The platform-free library module (importable by a host project's adoption
    // and by the CLI).
    const tracker = b.addModule("tracker", .{
        .root_source_file = b.path("src/tracker.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The `trk` executable. main.zig is a thin shell over cli.zig (same dir, so
    // `@import("cli.zig")` resolves); cli.zig imports the `tracker` module.
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "tracker", .module = tracker }},
    });
    const exe = b.addExecutable(.{ .name = "trk", .root_module = exe_mod });
    // Install trk. Default lands in `zig-out/bin/trk`. To deploy onto your PATH,
    // use Zig's built-in install prefix (cross-platform, picks `trk.exe` on
    // Windows automatically):
    //   zig build --prefix ~/.local -Doptimize=ReleaseSafe   -> ~/.local/bin/trk
    //   zig build --prefix C:\Tools -Doptimize=ReleaseSafe   -> C:\Tools\bin\trk.exe
    // If your PATH dir is flat (no trailing `bin`), drop the exe straight in with
    //   zig build --prefix <dir> --prefix-exe-dir . -Doptimize=ReleaseSafe -> <dir>/trk
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the trk CLI (pass args after --)").dependOn(&run.step);

    // `zig build test` runs all unit tests (ulid + model + json_codec + store +
    // the disk-backed integration tests).
    const test_step = b.step("test", "Run tracker unit tests");
    const unit = b.addTest(.{ .root_module = tracker });
    test_step.dependOn(&b.addRunArtifact(unit).step);

    // CLI + projection tests (cli_test.zig drives cli.zig). It imports the
    // `tracker` module and cli.zig, so it gets its own test module with that
    // import wired.
    const cli_test_mod = b.createModule(.{
        .root_source_file = b.path("src/cli_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "tracker", .module = tracker }},
    });
    const cli_test = b.addTest(.{ .root_module = cli_test_mod });
    test_step.dependOn(&b.addRunArtifact(cli_test).step);
}
