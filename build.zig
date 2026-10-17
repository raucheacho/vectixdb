const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    // Release artifacts drop debug info: it is most of the static library.
    const strip = b.option(bool, "strip", "Omit debug info from the library and the CLI");
    const shared = b.option(bool, "shared", "Also build the shared library") orelse false;

    const mod = b.addModule("vectixdb", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .pic = true,
        .strip = strip,
    });

    const lib = b.addLibrary(.{
        .name = "vectixdb",
        .linkage = .static,
        .root_module = mod,
    });
    // Linked by foreign toolchains (cgo, gcc): carry the compiler runtime
    // (e.g. __zig_probe_stack on x86_64). Not on arm64 macOS, where Apple's
    // linker rejects the bundled member and nothing from it is needed.
    lib.bundle_compiler_rt = !(target.result.os.tag.isDarwin() and target.result.cpu.arch == .aarch64);
    b.installArtifact(lib);
    lib.installHeader(b.path("include/vectixdb.h"), "vectixdb.h");

    // For FFI users (Python, Node, ...) that load the library at run time.
    if (shared) {
        const dylib = b.addLibrary(.{
            .name = "vectixdb",
            .linkage = .dynamic,
            .root_module = mod,
            .version = std.SemanticVersion.parse(@import("build.zig.zon").version) catch unreachable,
        });
        b.installArtifact(dylib);
    }

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
            .strip = strip,
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
