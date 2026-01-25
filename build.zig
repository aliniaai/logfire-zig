const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // otel-zig dependency
    const otel_dep = b.dependency("opentelemetry", .{
        .target = target,
        .optimize = optimize,
    });

    // config module (shared between modules)
    const config_mod = b.createModule(.{
        .root_source_file = b.path("src/config.zig"),
        .target = target,
        .optimize = optimize,
    });

    // main module: otel-backed wrapper (recommended)
    const logfire_mod = b.addModule("logfire", .{
        .root_source_file = b.path("src/otel_wrapper.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "otel", .module = otel_dep.module("otel") },
            .{ .name = "config", .module = config_mod },
        },
    });

    // legacy module: direct OTLP/JSON implementation (deprecated)
    const legacy_mod = b.addModule("logfire-legacy", .{
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

    // tests (run against main module)
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/otel_wrapper.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "otel", .module = otel_dep.module("otel") },
                .{ .name = "config", .module = config_mod },
            },
        }),
    });
    const run_tests = b.addRunArtifact(tests);

    // legacy tests
    const legacy_tests = b.addTest(.{ .root_module = legacy_mod });
    const run_legacy_tests = b.addRunArtifact(legacy_tests);

    const test_step = b.step("test", "run unit tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_legacy_tests.step);

    // example executable (uses new otel-backed module)
    const example = b.addExecutable(.{
        .name = "example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/otel_basic.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "logfire", .module = logfire_mod }},
        }),
    });

    const run_example = b.addRunArtifact(example);
    const example_step = b.step("example", "run the otel-based example");
    example_step.dependOn(&run_example.step);

    // legacy example (for testing old API during transition)
    const legacy_example = b.addExecutable(.{
        .name = "legacy-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/basic.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "logfire", .module = legacy_mod }},
        }),
    });

    const run_legacy_example = b.addRunArtifact(legacy_example);
    const legacy_example_step = b.step("legacy-example", "run the legacy example");
    legacy_example_step.dependOn(&run_legacy_example.step);

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
