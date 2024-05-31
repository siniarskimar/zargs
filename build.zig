const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zargs_mod = b.addModule("zargs", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const Example = struct {
        name: []const u8,
        path: std.Build.LazyPath,
        step_description: []const u8,
    };

    const examples = [_]Example{
        .{ .name = "example-help", .path = b.path("example/help.zig"), .step_description = "Run example/help.zig" },
    };

    for (examples) |example| {
        const exe = b.addExecutable(.{
            .name = example.name,
            .root_source_file = example.path,
            .target = target,
            .optimize = optimize,
        });

        exe.root_module.addImport("zargs", zargs_mod);
        const run = b.addRunArtifact(exe);
        if (b.args) |args| {
            run.addArgs(args);
        }
        const step_example_help = b.step(example.name, example.step_description);
        step_example_help.dependOn(&run.step);
    }
}
