# logfire-zig

unofficial Zig SDK for [Pydantic Logfire](https://logfire.pydantic.dev/) - built on [otel-zig](https://github.com/open-telemetry/opentelemetry-zig) for OTLP/protobuf export.

aiming for parity with [logfire-rust](https://github.com/pydantic/logfire-rust).

see also:
- [Logfire documentation](https://logfire.pydantic.dev/docs/)
- [alternative clients guide](https://logfire.pydantic.dev/docs/how-to-guides/alternative-clients/) for OTLP protocol details

## Using logfire-zig

First [set up a Logfire project](https://logfire.pydantic.dev/docs/#logfire). Configure the SDK by [creating a write token](https://logfire.pydantic.dev/docs/how-to-guides/create-write-tokens/) and setting it as an environment variable (`LOGFIRE_WRITE_TOKEN` or `LOGFIRE_TOKEN`).

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .logfire = .{
        .url = "https://tangled.sh/zzstoatzz.io/logfire-zig/archive/main",
        .hash = "...", // zig build will tell you the hash
    },
},
```

Add to your `build.zig`:

```zig
const logfire = b.dependency("logfire", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("logfire", logfire.module("logfire"));
```

Then instrument your code:

```zig
const std = @import("std");
const logfire = @import("logfire");

pub fn main() !void {
    const lf = try logfire.configure(.{
        .service_name = "my-service",
    });
    defer lf.shutdown();

    // structured logging (console output)
    logfire.info("application started", .{});

    // spans for timing operations (exported to Logfire)
    {
        const span = logfire.span("process.files", .{});
        defer span.end();

        // nested spans automatically link to parent
        {
            const child = logfire.span("process.single_file", .{ .filename = "data.csv" });
            defer child.end();
            std.time.sleep(10 * std.time.ns_per_ms);
        }
    }

    // flush before exit
    try lf.flush();
}
```

Run with your token:

```bash
LOGFIRE_WRITE_TOKEN=pylf_v1_us_xxx zig build run
```

Without a token, output goes to console for local development.

## Features

- **Spans** - timing and tracing with attributes, automatic parent-child linking
- **Instrumentation helpers** - `httpSpan()` and `sqlSpan()` for common patterns
- **Async batched export** - BatchSpanProcessor exports every 500ms (matches Python/Rust)
- **Logging** - trace, debug, info, warn, err (console output)
- **OTLP Export** - HTTP/protobuf via otel-zig to Logfire or any OTLP-compatible backend
- **Zero Config** - reads token and endpoint from environment
- **Cross-platform** - works on macOS and Linux

## API

```zig
// configuration
const lf = try logfire.configure(.{
    .service_name = "my-service",
    .service_version = "1.0.0",
});
defer lf.shutdown();

// spans (exported to Logfire via OTLP/protobuf)
const span = logfire.span("operation.name", .{
    .user_id = @as(i64, 123),
    .request_path = "/api/search",
});
defer span.end();

// add attributes after creation
span.setAttribute("result_count", @as(i64, 42));

// record errors (sets error status + adds exception event)
span.recordError(error.ConnectionFailed);

// instrumentation helpers for common patterns
const http_span = logfire.httpSpan("GET", "/api/users", .{});
defer http_span.end();
// creates span named "HTTP GET /api/users" with http.request.method and url.path attrs

const db_span = logfire.sqlSpan("SELECT * FROM users WHERE id = ?", "postgresql");
defer db_span.end();
// creates span with truncated SQL name and db.system attribute

// logging (console output only for now)
logfire.trace("detailed trace", .{});
logfire.debug("debug info", .{});
logfire.info("something happened", .{});
logfire.warn("warning message", .{});
logfire.err("error occurred", .{});

// manual flush
try lf.flush();
```

## Environment Variables

| Variable | Description |
|----------|-------------|
| `LOGFIRE_WRITE_TOKEN` | Write token (preferred) |
| `LOGFIRE_TOKEN` | Write token (fallback) |
| `LOGFIRE_SERVICE_NAME` | Service name override |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | Custom OTLP endpoint |

## Requirements

- Zig 0.15+

## Development

```bash
zig build test       # run tests
zig build example    # run examples/basic.zig
```

## Status

This is an unofficial community SDK aiming for parity with [logfire-rust](https://github.com/pydantic/logfire-rust). Built on [otel-zig](https://github.com/open-telemetry/opentelemetry-zig).

- [x] Spans with attributes
- [x] Parent-child span linking (thread-local context)
- [x] Error recording (`span.recordError()`)
- [x] OTLP HTTP/protobuf export
- [x] Async batched export (500ms interval, matches Python/Rust)
- [x] Environment-based configuration
- [x] Instrumentation helpers (`httpSpan`, `sqlSpan`)
- [x] Cross-platform (macOS + Linux)
- [ ] Structured logging export (console only, OTLP TODO)
- [ ] Metrics (API stubs, implementation TODO)
- [ ] W3C trace context propagation (cross-service)

## License

MIT
