//! logfire-zig: otel-backed observability SDK for Logfire
//!
//! API modeled after Rust and Python Logfire SDKs.
//!
//! usage:
//!   const lf = try logfire.configure(.{
//!       .service_name = "my-service",
//!   });
//!   defer lf.shutdown();
//!
//!   logfire.info("server started on port {d}", .{port});
//!
//!   const span = logfire.span("http.request", .{ .method = "GET" });
//!   defer span.end();
//!
//!   logfire.counter("requests.total", 1);

const std = @import("std");
const otel = @import("otel");
const otel_api = otel.api;
const otel_sdk = otel.sdk;
const otel_exporters = otel.exporters;

const Config = @import("config").Config;

// ============================================================================
// global state (similar to Python's DEFAULT_LOGFIRE_INSTANCE)
// ============================================================================

var global_instance: ?*Logfire = null;
var global_allocator: ?std.mem.Allocator = null;

// ============================================================================
// Logfire - main SDK type
// ============================================================================

pub const Logfire = struct {
    allocator: std.mem.Allocator,
    config: Config,

    // otel providers
    trace_provider: ?*otel_sdk.trace.TracerProvider = null,
    log_provider: ?*otel_sdk.logs.LoggerProvider = null,

    // cached instruments
    tracer: ?otel_api.trace.Tracer = null,
    logger: ?otel_api.logs.Logger = null,

    // heap-allocated data that must outlive providers
    auth_header_value: ?[]u8 = null,
    headers: ?[]std.http.Header = null,

    const Self = @This();

    /// configure and return a Logfire instance
    /// also sets the global instance for convenience functions
    pub fn init(allocator: std.mem.Allocator, config: Config) !*Self {
        const resolved = config.resolve();

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .config = resolved,
        };

        // set global state
        global_instance = self;
        global_allocator = allocator;

        // if not sending, return no-op instance
        if (!resolved.shouldSend()) {
            return self;
        }

        // set up OTLP exporter with Logfire endpoint
        if (resolved.token) |token| {
            const endpoint = getEndpointFromToken(token);

            // heap-allocate auth header (must outlive exporter)
            self.auth_header_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
            errdefer if (self.auth_header_value) |v| allocator.free(v);

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

            // create trace provider manually to avoid OS-specific resource detection
            // (otel-zig's setupGlobalProvider uses detectResource which only supports macOS)
            const provider_ptr = try allocator.create(otel_sdk.trace.TracerProvider);
            errdefer allocator.destroy(provider_ptr);

            // create minimal resource with service name
            const resource = try createMinimalResource(allocator, resolved.service_name orelse "logfire-zig");
            errdefer resource.deinitOwned(allocator);

            provider_ptr.* = otel_sdk.trace.TracerProvider.init(
                allocator,
                resource,
                otel_sdk.trace.createDefaultIdGenerator(),
                otel_api.trace.Sampler{ .keep = {} },
            );

            // add OTLP exporter pipeline
            try provider_ptr.addProcessor(
                otel_sdk.trace.BasicSpanProcessor.PipelineStep.init({})
                    .flowTo(otel_exporters.otlp.OtlpTraceExporter.PipelineStep.init(otlp_config)),
            );

            // set as global provider
            otel_api.provider_registry.setGlobalTracerProvider(provider_ptr);
            self.trace_provider = provider_ptr;

            // get tracer
            const scope = otel_api.InstrumentationScope{
                .name = resolved.service_name orelse "logfire-zig",
                .version = resolved.service_version orelse "0.1.0",
            };
            self.tracer = try otel_api.getGlobalTracerProvider().getTracerWithScope(scope);
        }

        return self;
    }

    /// shutdown and cleanup all resources
    pub fn shutdown(self: *Self) void {
        if (self.trace_provider) |p| {
            _ = p.shutdown(null);
            p.deinit();
            p.destroy();
        }
        if (self.log_provider) |p| {
            _ = p.shutdown(null);
            p.deinit();
            p.destroy();
        }
        otel_api.provider_registry.unsetAllProviders();

        // free heap-allocated data
        if (self.headers) |h| self.allocator.free(h);
        if (self.auth_header_value) |v| self.allocator.free(v);

        // clear global state
        if (global_instance == self) {
            global_instance = null;
        }

        self.allocator.destroy(self);
    }

    /// force flush pending telemetry
    pub fn flush(self: *Self) !void {
        if (self.trace_provider) |p| {
            _ = p.forceFlush(null);
        }
    }

    // ========================================================================
    // spans
    // ========================================================================

    /// create a span with the given name and attributes
    pub fn createSpan(self: *Self, name: []const u8, attrs: anytype) Span {
        if (self.tracer) |*tracer| {
            const otel_attrs = attrsToOtel(attrs);
            const ctx = &[_]otel_api.ContextKeyValue{};
            const span_result = tracer.startSpan(name, .{
                .kind = .internal,
                .attributes = otel_attrs,
            }, ctx) catch {
                return .{ .inner = null };
            };
            return .{ .inner = span_result };
        }
        return .{ .inner = null };
    }

    // ========================================================================
    // logging
    // ========================================================================

    pub fn logMessage(self: *Self, comptime level: Config.Level, comptime fmt: []const u8, args: anytype) void {
        // console output if enabled
        if (self.config.console) |console| {
            if (console.enabled and @intFromEnum(level) >= @intFromEnum(console.min_level)) {
                std.debug.print("[{s}] ", .{level.name()});
                std.debug.print(fmt ++ "\n", args);
            }
        }

        // TODO: emit to otel logger when log provider is set up
    }
};

// ============================================================================
// Span wrapper
// ============================================================================

pub const Span = struct {
    inner: ?otel_api.trace.Span,

    /// end the span - takes *const for API compatibility with legacy logfire
    pub fn end(self: *const Span) void {
        if (self.inner != null) {
            // use @constCast for API compatibility (allows const span = ... pattern)
            const mutable = @constCast(self);
            if (mutable.inner) |*s| {
                s.end(null);
                s.deinit();
                mutable.inner = null;
            }
        }
    }

    pub fn setAttribute(self: *const Span, key: []const u8, value: anytype) void {
        if (self.inner != null) {
            const mutable = @constCast(self);
            if (mutable.inner) |*s| {
                s.setAttribute(.{ .key = key, .value = toOtelValue(value) });
            }
        }
    }
};

// ============================================================================
// convenience functions (use global instance)
// ============================================================================

/// configure logfire with the given options
/// returns the configured instance
pub fn configure(config: Config) !*Logfire {
    const allocator = std.heap.page_allocator;
    return Logfire.init(allocator, config);
}

/// create a span (uses global instance)
pub fn span(name: []const u8, attrs: anytype) Span {
    if (global_instance) |lf| {
        return lf.createSpan(name, attrs);
    }
    return .{ .inner = null };
}

/// log at trace level
pub fn trace(comptime fmt: []const u8, args: anytype) void {
    if (global_instance) |lf| lf.logMessage(.trace, fmt, args);
}

/// log at debug level
pub fn debug(comptime fmt: []const u8, args: anytype) void {
    if (global_instance) |lf| lf.logMessage(.debug, fmt, args);
}

/// log at info level
pub fn info(comptime fmt: []const u8, args: anytype) void {
    if (global_instance) |lf| lf.logMessage(.info, fmt, args);
}

/// log at warn level
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    if (global_instance) |lf| lf.logMessage(.warn, fmt, args);
}

/// log at error level
pub fn err(comptime fmt: []const u8, args: anytype) void {
    if (global_instance) |lf| lf.logMessage(.err, fmt, args);
}

// ============================================================================
// metrics (stubs for now - TODO: implement with otel metrics)
// ============================================================================

pub fn counter(name: []const u8, value: i64) void {
    _ = name;
    _ = value;
    // TODO: implement with otel-zig metrics
}

pub fn counterWithOpts(name: []const u8, value: i64, opts: anytype) void {
    _ = name;
    _ = value;
    _ = opts;
}

pub fn gaugeInt(name: []const u8, value: i64) void {
    _ = name;
    _ = value;
}

pub fn gaugeDouble(name: []const u8, value: f64) void {
    _ = name;
    _ = value;
}

// ============================================================================
// helpers
// ============================================================================

/// create a minimal resource without OS-specific detection
/// this avoids otel-zig's ProcessDetector which only supports macOS
fn createMinimalResource(allocator: std.mem.Allocator, service_name: []const u8) !otel_sdk.resource.Resource {
    const builtin = @import("builtin");

    // build attributes
    var attrs = otel_api.common.AttributeBuilder.init(allocator);

    // telemetry SDK info
    attrs = attrs.add(.{ .key = "telemetry.sdk.name", .value = .{ .string = "logfire-zig" } });
    attrs = attrs.add(.{ .key = "telemetry.sdk.language", .value = .{ .string = "zig" } });
    attrs = attrs.add(.{ .key = "telemetry.sdk.version", .value = .{ .string = "0.1.0" } });

    // service name
    attrs = attrs.add(.{ .key = "service.name", .value = .{ .string = service_name } });

    // process.pid (works on all POSIX systems)
    const pid = std.c.getpid();
    attrs = attrs.add(.{ .key = "process.pid", .value = .{ .int = @intCast(pid) } });

    // process.executable.name via /proc/self/exe (Linux) or _NSGetExecutablePath (macOS)
    switch (builtin.os.tag) {
        .linux => {
            // read /proc/self/exe symlink
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            if (std.fs.readLinkAbsolute("/proc/self/exe", &buf)) |path| {
                const basename = std.fs.path.basename(path);
                const owned_path = try allocator.dupe(u8, path);
                const owned_basename = try allocator.dupe(u8, basename);
                attrs = attrs.add(.{ .key = "process.executable.path", .value = .{ .string = owned_path } });
                attrs = attrs.add(.{ .key = "process.executable.name", .value = .{ .string = owned_basename } });
            } else |_| {}
        },
        .macos => {
            var size: u32 = std.fs.max_path_bytes;
            var buf: [std.fs.max_path_bytes:0]u8 = undefined;
            if (std.c._NSGetExecutablePath(&buf, &size) == 0) {
                const path = std.mem.sliceTo(&buf, 0);
                const basename = std.fs.path.basename(path);
                const owned_path = try allocator.dupe(u8, path);
                const owned_basename = try allocator.dupe(u8, basename);
                attrs = attrs.add(.{ .key = "process.executable.path", .value = .{ .string = owned_path } });
                attrs = attrs.add(.{ .key = "process.executable.name", .value = .{ .string = owned_basename } });
            }
        },
        else => {}, // skip executable info on other OSes
    }

    return try otel_sdk.resource.Resource.initOwnedFromBuilder(allocator, null, &attrs);
}

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

fn toOtelValue(value: anytype) ?otel_api.common.AttributeValue {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .int, .comptime_int => .{ .int = @intCast(value) },
        .float, .comptime_float => .{ .double = @floatCast(value) },
        .bool => .{ .bool = value },
        .optional => {
            // handle optional types - return null if the value is null
            if (value) |v| {
                return toOtelValue(v);
            }
            return null;
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                return .{ .string = value };
            }
            if (ptr.size == .one) {
                const child_info = @typeInfo(ptr.child);
                if (child_info == .array and child_info.array.child == u8) {
                    return .{ .string = value };
                }
            }
            @compileError("unsupported pointer type");
        },
        else => @compileError("unsupported type for attribute: " ++ @typeName(T)),
    };
}

fn attrsToOtel(attrs: anytype) []const otel_api.common.AttributeKeyValue {
    const T = @TypeOf(attrs);
    if (@typeInfo(T) != .@"struct") {
        return &[_]otel_api.common.AttributeKeyValue{};
    }

    const fields = @typeInfo(T).@"struct".fields;
    if (fields.len == 0) {
        return &[_]otel_api.common.AttributeKeyValue{};
    }

    // use static storage per type - populated at runtime
    // note: not thread-safe, but attributes are copied by otel-zig immediately
    const Storage = struct {
        var result: [fields.len]otel_api.common.AttributeKeyValue = undefined;
        var count: usize = 0;
    };

    Storage.count = 0;
    inline for (fields) |field| {
        if (toOtelValue(@field(attrs, field.name))) |val| {
            Storage.result[Storage.count] = .{
                .key = field.name,
                .value = val,
            };
            Storage.count += 1;
        }
    }
    return Storage.result[0..Storage.count];
}
