const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // library module
    const mod = b.addModule("logfire", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // tests
    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "run unit tests");
    test_step.dependOn(&run_tests.step);

    // example executable
    const example = b.addExecutable(.{
        .name = "example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/basic.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "logfire", .module = mod }},
        }),
    });

    const run_example = b.addRunArtifact(example);
    const example_step = b.step("example", "run the basic example");
    example_step.dependOn(&run_example.step);
}
