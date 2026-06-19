const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vaxis_dep = b.dependency("vaxis", .{ .target = target, .optimize = optimize });
    const vaxis_mod = vaxis_dep.module("vaxis");

    const mod = b.addModule("zest", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "vaxis", .module = vaxis_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "zest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zest", .module = mod },
                .{ .name = "vaxis", .module = vaxis_mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the app").dependOn(&run_cmd.step);

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_mod_tests.step);

    // --- Examples -----------------------------------------------------------
    //
    // Each entry under examples/ is its own runnable executable, sharing the
    // top-level zest module and the vaxis dependency. Add `zig build dashboard`
    // (and so on) to launch a specific example; `zig build run-examples`
    // builds them all into the install prefix.
    const examples = [_]struct {
        name: []const u8,
        path: []const u8,
        desc: []const u8,
    }{
        .{
            .name = "dashboard",
            .path = "examples/dashboard/main.zig",
            .desc = "Run the system-stats dashboard example",
        },
    };
    for (examples) |ex| {
        const ex_exe = b.addExecutable(.{
            .name = ex.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(ex.path),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zest", .module = mod },
                    .{ .name = "vaxis", .module = vaxis_mod },
                },
            }),
        });
        b.installArtifact(ex_exe);
        const ex_run = b.addRunArtifact(ex_exe);
        ex_run.step.dependOn(b.getInstallStep());
        if (b.args) |args| ex_run.addArgs(args);
        b.step(ex.name, ex.desc).dependOn(&ex_run.step);
    }

    // --- Benchmarks ---------------------------------------------------------
    //
    // `zig build bench` runs the micro-benchmark harness. Built in
    // ReleaseFast so the measurements aren't dominated by the debug
    // safety checks; release-mode is the mode the performance targets
    // in the README quote against.
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "zest", .module = mod },
                .{ .name = "vaxis", .module = vaxis_mod },
            },
        }),
    });
    const bench_run = b.addRunArtifact(bench_exe);
    if (b.args) |args| bench_run.addArgs(args);
    b.step("bench", "Run the micro-benchmark harness in ReleaseFast")
        .dependOn(&bench_run.step);
}
