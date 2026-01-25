//! otel-zig wrapper for logfire
//!
//! provides a simple, logfire-specific wrapper around otel-zig.
//! this is phase 3 of the otel-zig adoption plan.

const std = @import("std");
const otel = @import("otel");
const otel_api = otel.api;
const otel_sdk = otel.sdk;
const otel_exporters = otel.exporters;

const Config = @import("config.zig").Config;

/// logfire wrapper around otel-zig providers
pub const OtelLogfire = struct {
    allocator: std.mem.Allocator,
    config: Config,

    // providers (owned)
    trace_provider: ?*otel_sdk.trace.TracerProvider = null,
    log_provider: ?*otel_sdk.logs.LoggerProvider = null,
    // metric_provider: ?*otel_sdk.metrics.MeterProvider = null,

    // cached instruments
    tracer: ?otel_api.trace.Tracer = null,
    logger: ?otel_api.logs.Logger = null,

    // heap-allocated auth header (must outlive exporter)
    auth_header_value: ?[]u8 = null,
    headers: ?[]std.http.Header = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: Config) !*Self {
        const resolved = config.resolve();

        if (!resolved.shouldSend()) {
            // return no-op instance
            const self = try allocator.create(Self);
            self.* = .{
                .allocator = allocator,
                .config = resolved,
            };
            return self;
        }

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .config = resolved,
        };

        // set up trace provider with OTLP exporter
        if (resolved.token) |token| {
            const endpoint = getEndpointFromToken(token);

            // heap-allocate auth header value (must outlive exporter)
            self.auth_header_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
            errdefer if (self.auth_header_value) |v| allocator.free(v);

            // heap-allocate headers array
            self.headers = try allocator.alloc(std.http.Header, 1);
            errdefer if (self.headers) |h| allocator.free(h);

            self.headers.?[0] = .{
                .name = "Authorization",
                .value = self.auth_header_value.?,
            };

            const otlp_config = otel_exporters.otlp.OtlpExporterConfig{
                .endpoint = endpoint,
                .transport = .http_protobuf,
                .headers = self.headers.?,
            };

            // set up trace provider
            self.trace_provider = try otel_sdk.trace.setupGlobalProvider(
                allocator,
                .{otel_sdk.trace.BasicSpanProcessor.PipelineStep.init({})
                    .flowTo(otel_exporters.otlp.OtlpTraceExporter.PipelineStep.init(otlp_config))},
            );

            // get tracer
            const scope = otel_api.InstrumentationScope{
                .name = resolved.service_name orelse "logfire-zig",
                .version = resolved.service_version orelse "0.1.0",
            };
            self.tracer = try otel_api.getGlobalTracerProvider().getTracerWithScope(scope);
        }

        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.trace_provider) |p| {
            p.deinit();
            p.destroy();
        }
        if (self.log_provider) |p| {
            p.deinit();
            p.destroy();
        }
        otel_api.provider_registry.unsetAllProviders();

        // free heap-allocated header data
        if (self.headers) |h| self.allocator.free(h);
        if (self.auth_header_value) |v| self.allocator.free(v);

        self.allocator.destroy(self);
    }

    /// create a span with the given name and attributes
    pub fn span(self: *Self, name: []const u8) Span {
        if (self.tracer) |*tracer| {
            const ctx = &[_]otel_api.ContextKeyValue{};
            const span_result = tracer.startSpan(name, .{
                .kind = .internal,
            }, ctx) catch {
                return .{ .inner = null };
            };
            return .{ .inner = span_result };
        }
        return .{ .inner = null };
    }

    /// flush any pending data
    pub fn flush(self: *Self) !void {
        if (self.trace_provider) |p| {
            _ = p.forceFlush(null);
        }
    }

    /// shutdown the provider
    pub fn shutdown(self: *Self) void {
        if (self.trace_provider) |p| {
            _ = p.shutdown(null);
        }
        self.deinit();
    }
};

/// span wrapper for ergonomic usage
pub const Span = struct {
    inner: ?otel_api.trace.Span,

    pub fn end(self: *Span) void {
        if (self.inner) |*s| {
            s.end(null);
            s.deinit();
            self.inner = null;
        }
    }

    pub fn setAttribute(self: *Span, key: []const u8, value: anytype) void {
        if (self.inner) |*s| {
            const attr_value = toAttributeValue(value);
            s.setAttribute(.{ .key = key, .value = attr_value });
        }
    }
};

fn toAttributeValue(value: anytype) otel_api.common.AttributeValue {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .int, .comptime_int => .{ .int = @intCast(value) },
        .float, .comptime_float => .{ .double = @floatCast(value) },
        .bool => .{ .bool = value },
        .pointer => |ptr| {
            // handle []const u8 (slices)
            if (ptr.size == .slice and ptr.child == u8) {
                return .{ .string = value };
            }
            // handle *const [N]u8 and *const [N:0]u8 (string literals)
            if (ptr.size == .one) {
                const child_info = @typeInfo(ptr.child);
                if (child_info == .array and child_info.array.child == u8) {
                    return .{ .string = value };
                }
            }
            @compileError("unsupported pointer type for attribute");
        },
        else => @compileError("unsupported type for attribute: " ++ @typeName(T)),
    };
}

/// extract region from logfire token and return base OTLP endpoint
fn getEndpointFromToken(token: []const u8) []const u8 {
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

// convenience function to create and configure
pub fn configure(config: Config) !*OtelLogfire {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    return OtelLogfire.init(gpa.allocator(), config);
}
