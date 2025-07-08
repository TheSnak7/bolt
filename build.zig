const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zig_aio = b.dependency("zig-aio", .{ .target = target, .optimize = optimize });

    const bolt_mod = b.addModule("bolt", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    bolt_mod.addImport("aio", zig_aio.module("aio"));
    bolt_mod.addImport("coro", zig_aio.module("coro"));

    // Create both build and run steps for examples
    const example_step = b.step("example", "Build all examples");
    const example_run_step = b.step("example-run", "Run an example. Usage: zig build example-run -- [name]");

    var examples = std.StringHashMap(*std.Build.Step.Compile).init(b.allocator);
    defer examples.deinit();

    inline for (.{ .hello_world, .echo, .graceful }) |name| {
        const example = b.addExecutable(.{
            .name = @tagName(name),
            .root_source_file = b.path("examples/" ++ @tagName(name) ++ ".zig"),
            .target = target,
            .optimize = optimize,
        });
        example.root_module.addImport("bolt", bolt_mod);
        examples.put(@tagName(name), example) catch @panic("OOM");
        const install = b.addInstallArtifact(example, .{});
        b.getInstallStep().dependOn(&install.step);
        example_step.dependOn(&install.step);
    }

    // Handle running examples if args are provided
    if (b.args) |args| {
        if (args.len > 0) {
            const example_name = args[0];
            if (examples.get(example_name)) |example| {
                const run_cmd = b.addRunArtifact(example);
                if (args.len > 1) {
                    run_cmd.addArgs(args[1..]);
                }
                example_run_step.dependOn(&run_cmd.step);
            } else {
                std.debug.print("Unknown example '{s}'\nAvailable examples:\n", .{example_name});
                var it = examples.keyIterator();
                while (it.next()) |key| {
                    std.debug.print("  {s}\n", .{key.*});
                }
                std.process.exit(1);
            }
        } else {
            std.debug.print("No example name provided\nAvailable examples:\n", .{});
            var it = examples.keyIterator();
            while (it.next()) |key| {
                std.debug.print("  {s}\n", .{key.*});
            }
            std.process.exit(1);
        }
    } else {
        const missing_example = b.addFail("Usage: zig build example-run -- [hello_world|echo|graceful]");
        example_run_step.dependOn(&missing_example.step);
    }

    const exe_unit_tests = b.addTest(.{
        .root_module = bolt_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
