//! logfire example
//!
//! demonstrates the otel-zig backed API.
//! API matches current leaflet-search usage patterns.
//!
//! run with:
//!   LOGFIRE_TOKEN=your_token zig build example
//!
//! or without token for console-only output:
//!   zig build example

const std = @import("std");
const logfire = @import("logfire");

pub fn main() !void {
    // configure logfire (reads LOGFIRE_TOKEN from env)
    // API matches: logfire.configure({...})
    _ = logfire.configure(.{
        .service_name = "logfire-zig-otel-example",
        .service_version = "0.1.0",
        .environment = "development",
    }) catch |err| {
        std.debug.print("logfire init failed: {}, continuing\n", .{err});
    };

    // logging - matches: logfire.info("msg", .{args})
    logfire.info("application started", .{});

    // span with attributes - matches: logfire.span("name", .{attrs})
    // uses const span pattern for API compatibility with leaflet-search
    {
        const span = logfire.span("example.work", .{
            .iteration = @as(i64, 1),
            .query = "prefect python",
        });
        defer span.end();

        // simulate work
        std.posix.nanosleep(0, 50 * std.time.ns_per_ms);

        logfire.info("work completed", .{});
    }

    // nested spans
    {
        const outer = logfire.span("example.outer", .{});
        defer outer.end();

        {
            const inner = logfire.span("example.inner", .{});
            defer inner.end();

            std.posix.nanosleep(0, 25 * std.time.ns_per_ms);
        }
    }

    // metrics (stubs for now)
    logfire.counter("requests.total", 1);
    logfire.gaugeInt("connections.active", 42);

    logfire.info("example complete", .{});
}
