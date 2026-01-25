//! otel-based logfire example
//!
//! demonstrates the new otel-zig backed API.
//!
//! run with:
//!   LOGFIRE_TOKEN=your_token zig build otel-example
//!
//! or without token for no-op behavior:
//!   zig build otel-example

const std = @import("std");
const logfire = @import("logfire-otel");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // configure with otel-zig backend
    const lf = try logfire.OtelLogfire.init(allocator, .{
        .service_name = "logfire-zig-otel-example",
        .service_version = "0.1.0",
        .environment = "development",
    });
    defer lf.shutdown();

    std.debug.print("logfire initialized (otel backend)\n", .{});

    // create a span
    {
        var s = lf.span("example.work");
        defer s.end();

        // add attributes
        s.setAttribute("iteration", @as(i64, 1));
        s.setAttribute("query", "prefect python");

        // simulate work
        std.posix.nanosleep(0, 50 * std.time.ns_per_ms);
    }

    // nested spans
    {
        var outer = lf.span("example.outer");
        defer outer.end();

        {
            var inner = lf.span("example.inner");
            defer inner.end();

            std.posix.nanosleep(0, 25 * std.time.ns_per_ms);
        }
    }

    // flush to ensure export
    try lf.flush();

    std.debug.print("example complete - check logfire dashboard\n", .{});
}
