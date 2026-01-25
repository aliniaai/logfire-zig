const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // otel-zig dependency
    const otel_dep = b.dependency("opentelemetry", .{
        .target = target,
        .optimize = optimize,
    });

    // library module (legacy API)
    const mod = b.addModule("logfire", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "otel-api", .module = otel_dep.module("otel-api") },
            .{ .name = "otel-sdk", .module = otel_dep.module("otel-sdk") },
            .{ .name = "otel-exporters", .module = otel_dep.module("otel-exporters") },
            .{ .name = "otel-semconv", .module = otel_dep.module("otel-semconv") },
        },
    });

    // otel-based wrapper module (new API)
    const otel_mod = b.addModule("logfire-otel", .{
        .root_source_file = b.path("src/otel_wrapper.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "otel", .module = otel_dep.module("otel") },
            .{ .name = "config", .module = b.createModule(.{
                .root_source_file = b.path("src/config.zig"),
                .target = target,
                .optimize = optimize,
            }) },
        },
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

    // otel-based example
    const otel_example = b.addExecutable(.{
        .name = "otel-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/otel_basic.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "logfire-otel", .module = otel_mod }},
        }),
    });

    const run_otel_example = b.addRunArtifact(otel_example);
    const otel_example_step = b.step("otel-example", "run the otel-based example");
    otel_example_step.dependOn(&run_otel_example.step);

    // validation script for otel-zig OTLP export (not in CI, requires LOGFIRE_TOKEN)
    const validate_otel = b.addExecutable(.{
        .name = "validate-otel-export",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/validate_otel_export.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "otel", .module = otel_dep.module("otel") },
            },
        }),
    });

    const run_validate_otel = b.addRunArtifact(validate_otel);
    const validate_step = b.step("validate-otel", "validate otel-zig OTLP export to logfire (requires LOGFIRE_TOKEN)");
    validate_step.dependOn(&run_validate_otel.step);
}
