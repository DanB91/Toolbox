const std = @import("std");
const builtin = @import("builtin");
const toolbox = @import("toolbox.zig");

pub const panic_handler = switch (toolbox.THIS_PLATFORM) {
    .Playdate => playdate_panic,
    else => std.debug.FormattedPanic.call,
};

pub fn playdate_panic(
    _msg: []const u8,
    error_return_trace: ?*std.builtin.StackTrace,
    return_address: ?usize,
) noreturn {
    _ = error_return_trace;
    _ = return_address;

    const panic_msg_arena = toolbox.Arena.init(toolbox.kb(512));
    const panic_msg_z = std.fmt.allocPrintZ(panic_msg_arena.zstd_allocator, "{s}", .{_msg}) catch
        "Uh well that sucks...";

    switch (comptime builtin.os.tag) {
        .freestanding => {
            //Playdate hardware

            //TODO: The Zig std library does not yet support stacktraces on Playdate hardware.
            //We will need to do this manually. Some notes on trying to get it working:
            //Frame pointer is R7
            //Next Frame pointer is *R7
            //Return address is *(R7+4)
            //To print out the trace corrently,
            //We need to know the load address and it doesn't seem to be exactly
            //0x6000_0000 as originally thought

            toolbox.playdate_error("PANIC: %s", panic_msg_z.ptr);
        },
        else => {
            //playdate simulator
            var stack_trace_buffer = [_]u8{0} ** 4096;
            var buffer = [_]u8{0} ** 4096;
            var stream = std.io.fixedBufferStream(&stack_trace_buffer);

            const stack_trace_string = b: {
                if (builtin.strip_debug_info) {
                    break :b "Unable to dump stack trace: Debug info stripped";
                }
                const debug_info = std.debug.getSelfDebugInfo() catch |err| {
                    const to_print = std.fmt.bufPrintZ(
                        &buffer,
                        "Unable to dump stack trace: Unable to open debug info: {s}\n",
                        .{@errorName(err)},
                    ) catch break :b "Unable to dump stack trace: Unable to open debug info due unknown error";
                    break :b to_print;
                };
                std.debug.writeCurrentStackTrace(
                    stream.writer(),
                    debug_info,
                    .no_color,
                    null,
                ) catch break :b "Unable to dump stack trace: Unknown error writng stack trace";

                //NOTE: playdate.system.error (and all Playdate APIs that deal with strings) require a null termination
                const null_char_index = @min(stream.pos, stack_trace_buffer.len - 1);
                stack_trace_buffer[null_char_index] = 0;

                break :b &stack_trace_buffer;
            };
            toolbox.playdate_error(
                "PANIC: %s\n\n%s",
                panic_msg_z.ptr,
                stack_trace_string.ptr,
            );
        },
    }

    while (true) {}
}
