# logfire-zig

unofficial Zig SDK for [Pydantic Logfire](https://logfire.pydantic.dev/) - OTLP HTTP/JSON export for traces, logs, and metrics.

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

    // structured logging
    logfire.info("application started", .{});

    // spans for timing operations
    {
        const span = logfire.span("process.files", .{});
        defer span.end();

        // work happens here
        std.time.sleep(10 * std.time.ns_per_ms);
    }

    // metrics
    logfire.counter("files.processed", 42);
    logfire.gaugeInt("queue.depth", 10);

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

- **Spans** - timing and tracing with attributes
- **Logging** - trace, debug, info, warn, err with structured data
- **Metrics** - counters, gauges (int/double)
- **OTLP Export** - HTTP/JSON to logfire or any OTLP-compatible backend
- **Zero Config** - reads token and endpoint from environment

## API

```zig
// configuration
const lf = try logfire.configure(.{
    .service_name = "my-service",
    .service_version = "1.0.0",
    .environment = "production",
});
defer lf.shutdown();

// spans
const span = logfire.span("operation.name", .{
    .user_id = @as(i64, 123),
    .request_path = "/api/search",
});
defer span.end();

// logging
logfire.trace("detailed trace", .{});
logfire.debug("debug info", .{});
logfire.info("something happened", .{});
logfire.warn("warning message", .{});
logfire.err("error occurred", .{});

// metrics
logfire.counter("requests.total", 1);
logfire.gaugeInt("connections.active", 42);
logfire.gaugeDouble("cpu.usage", 0.75);

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

This is an unofficial community SDK aiming for parity with [logfire-rust](https://github.com/pydantic/logfire-rust). Current status:

- [x] Spans with attributes
- [x] Structured logging (trace/debug/info/warn/err)
- [x] Metrics (counter, gauge)
- [x] OTLP HTTP/JSON export
- [x] Environment-based configuration
- [x] Batched async export (background flush thread)
- [x] Parent-child span linking (thread-local)
- [ ] Histograms (types implemented, no convenience API yet)
- [ ] Protobuf encoding (JSON only)
- [ ] W3C trace context propagation (cross-service)

## License

MIT
