//! otel-zig OTLP export test
//!
//! tests that otel-zig's OTLP exporter works with logfire endpoint.
//!
//! run with:
//!   LOGFIRE_TOKEN=your_token zig build otel-test
//!
//! this validates phase 1 of the otel-zig adoption plan.

const std = @import("std");
const otel = @import("otel");
const otel_api = otel.api;
const otel_sdk = otel.sdk;
const otel_exporters = otel.exporters;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // get logfire token and endpoint from env
    const token = std.posix.getenv("LOGFIRE_WRITE_TOKEN") orelse
        std.posix.getenv("LOGFIRE_TOKEN") orelse {
        std.debug.print("LOGFIRE_TOKEN not set, skipping OTLP test\n", .{});
        return;
    };

    // determine endpoint from token region
    const endpoint = getEndpointFromToken(token);
    std.debug.print("using endpoint: {s}\n", .{endpoint});

    // build authorization header
    var auth_header_buf: [256]u8 = undefined;
    const auth_value = std.fmt.bufPrint(&auth_header_buf, "Bearer {s}", .{token}) catch {
        std.debug.print("token too long\n", .{});
        return;
    };

    // configure OTLP exporter for logfire
    const otlp_config = otel_exporters.otlp.OtlpExporterConfig{
        .endpoint = endpoint,
        .transport = .http_protobuf,
        .headers = &[_]std.http.Header{
            .{ .name = "Authorization", .value = auth_value },
        },
    };

    // set up trace provider with OTLP exporter
    const provider = try otel_sdk.trace.setupGlobalProvider(
        allocator,
        .{otel_sdk.trace.BasicSpanProcessor.PipelineStep.init({})
            .flowTo(otel_exporters.otlp.OtlpTraceExporter.PipelineStep.init(otlp_config))},
    );
    defer {
        provider.deinit();
        provider.destroy();
    }
    defer otel_api.provider_registry.unsetAllProviders();

    // get tracer
    const scope = otel_api.InstrumentationScope{
        .name = "logfire-zig-otel-test",
        .version = "0.1.0",
    };
    var tracer = try otel_api.getGlobalTracerProvider().getTracerWithScope(scope);

    // create a test span
    const ctx = &[_]otel_api.ContextKeyValue{};
    var span_result = try tracer.startSpan("otel-zig-test-span", .{
        .kind = .internal,
        .attributes = &[_]otel_api.common.AttributeKeyValue{
            .{ .key = "test.source", .value = .{ .string = "logfire-zig" } },
            .{ .key = "test.type", .value = .{ .string = "otel-adoption-validation" } },
        },
    }, ctx);

    // simulate some work
    std.posix.nanosleep(0, 50 * std.time.ns_per_ms);

    // end span (triggers export)
    span_result.end(null);
    span_result.deinit();

    std.debug.print("span exported successfully!\n", .{});
    std.debug.print("check logfire dashboard for 'otel-zig-test-span'\n", .{});
}

/// extract region from logfire token and return base OTLP endpoint
/// note: otel-zig appends /v1/traces path automatically
fn getEndpointFromToken(token: []const u8) []const u8 {
    // token format: pylf_v{version}_{region}_{token}
    if (std.mem.startsWith(u8, token, "pylf_v")) {
        var it = std.mem.splitScalar(u8, token, '_');
        _ = it.next(); // pylf
        _ = it.next(); // v1
        if (it.next()) |region| {
            if (std.mem.eql(u8, region, "eu")) {
                return "https://logfire-eu.pydantic.dev:443";
            }
        }
    }
    return "https://logfire-us.pydantic.dev:443";
}
