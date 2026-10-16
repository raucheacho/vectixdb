const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const mod = b.addModule("vectixdb", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .pic = true,
    });

    const lib = b.addLibrary(.{
        .name = "vectixdb",
        .linkage = .static,
        .root_module = mod,
    });
    b.installArtifact(lib);
    lib.installHeader(b.path("include/vectixdb.h"), "vectixdb.h");

    // A C program linked against the static library, to check the header.
    const smoke = b.addExecutable(.{
        .name = "c-smoke",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    smoke.root_module.addCSourceFile(.{ .file = b.path("tests/c/smoke.c"), .flags = &.{ "-std=c99", "-Wall", "-Wextra", "-Werror" } });
    smoke.root_module.addIncludePath(b.path("include"));
    smoke.root_module.linkLibrary(lib);
    const run_smoke = b.addRunArtifact(smoke);
    run_smoke.addArg(b.pathJoin(&.{ b.cache_root.path orelse ".", "c-smoke-db" }));
    b.step("c-test", "Build and run the C smoke test").dependOn(&run_smoke.step);

    const cli = b.addExecutable(.{
        .name = "vectix",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "vectixdb", .module = mod }},
        }),
    });
    b.installArtifact(cli);
    const run_cli = b.addRunArtifact(cli);
    if (b.args) |args| run_cli.addArgs(args);
    b.step("run", "Run the vectix command line tool").dependOn(&run_cli.step);

    const tsan = b.option(bool, "tsan", "Run the tests under ThreadSanitizer") orelse false;
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .sanitize_thread = tsan,
        }),
    });
    if (b.option([]const u8, "test-filter", "Only run tests whose name contains this")) |f| tests.filters = b.dupeStrings(&.{f});
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);
}
