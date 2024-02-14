const std = @import("std");
const clap = @import("plugin_clap.zig");
const c = @import("clap");

const LogWriterError = error{};

const LogWriterContext = struct {
    level: c.clap_log_severity = c.CLAP_LOG_INFO,
    host: *const c.clap_host_t,
    host_log_fn: *const fn ([*c]const c.clap_host_t, c.clap_log_severity, [*c]const u8) callconv(.C) void,
};

fn writeHostLog(context: LogWriterContext, bytes: []const u8) LogWriterError!usize {
    context.host_log_fn(context.host, context.level, bytes.ptr);
    return bytes.len;
}

const LogWriter = std.io.Writer(LogWriterContext, LogWriterError, writeHostLog);
var log_writer: ?LogWriter = null;

pub fn initLogging(host: *const c.clap_host_t) void {
    const log_extension: ?*const c.clap_host_log_t =
        @alignCast(@ptrCast(host.*.get_extension.?(host, &c.CLAP_EXT_LOG)));
    if (log_extension != null and log_extension.?.log != null) {
        log_writer = .{
            .context = LogWriterContext{
                .host = host,
                .host_log_fn = log_extension.?.log.?,
            },
        };
    } else {
        std.log.warn("Couldn't get log extension!", .{});
    }
}

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = scope;
    if (log_writer) |*writer| {
        writer.context.level = switch (message_level) {
            std.log.Level.debug => c.CLAP_LOG_INFO,
            std.log.Level.info => c.CLAP_LOG_INFO,
            std.log.Level.warn => c.CLAP_LOG_WARNING,
            std.log.Level.err => c.CLAP_LOG_ERROR,
        };
        const buf = std.fmt.allocPrintZ(clap.global_allocator, format, args) catch {
            writer.context.level = c.CLAP_LOG_ERROR;
            writer.writeAll("Failed to allocate memory when logging!") catch unreachable;
            return;
        };
        writer.writeAll(buf) catch unreachable;
        clap.global_allocator.free(buf);
    }

    // REAPER debug
    // print("{s}: " ++ format ++ "\n", .{message_level.asText()} ++ args);
}
