const std = @import("std");
const toolbox = @import("toolbox.zig");

extern fn write(filedes: c_int, buffer: ?*anyopaque, len: usize) isize;
pub fn println_str8(string: toolbox.String8) void {
    platform_print_to_console("{s}", .{string.bytes}, false, true);
}
pub fn print_str8(string: toolbox.String8) void {
    platform_print_to_console("{s}", .{string.bytes}, false, false);
}
pub fn println(comptime fmt: []const u8, args: anytype) void {
    platform_print_to_console(fmt, args, false, true);
}
pub fn print(comptime fmt: []const u8, args: anytype) void {
    platform_print_to_console(fmt, args, false, false);
}
pub fn printerr(comptime fmt: []const u8, args: anytype) void {
    platform_print_to_console(fmt, args, true, true);
}
pub fn tprint(comptime fmt: []const u8, args: anytype) toolbox.String8 {
    const arena = toolbox.get_scratch_arena(null);
    const ret = toolbox.str8fmt(fmt, args, arena);
    return ret;
}

pub fn panic(comptime fmt: []const u8, args: anytype) noreturn {
    var buffer = [_]u8{0} ** 2048;
    const to_print = std.fmt.bufPrint(&buffer, "PANIC: " ++ fmt ++ "\n", args) catch "Unknown error!";
    @panic(to_print);
}

fn platform_print_to_console(comptime fmt: []const u8, args: anytype, comptime is_err: bool, comptime include_newline: bool) void {
    const nl = if (include_newline) "\n" else "";

    const eff_fmt = if (is_err)
        "ERROR: " ++ fmt ++ nl
    else
        fmt ++ nl;

    const arena = toolbox.get_scratch_arena(null);
    defer arena.restore();

    const count: usize = @intCast(std.fmt.count(eff_fmt, args) + 1); //plus 1 for null byte

    const buffer = arena.push_slice_clear(u8, count);

    const to_print =
        std.fmt.bufPrintZ(buffer, eff_fmt, args) catch unreachable;

    switch (comptime toolbox.THIS_PLATFORM) {
        .Emscripten, .MacOS, .Linux => {

            //-1 for removing null byte
            _ = write(if (is_err) 2 else 1, to_print.ptr, to_print.len);
        },
        .Playdate => {
            toolbox.playdate_log_to_console("%s", to_print.ptr);
        },
        .Wozmon64, .UEFI, .BoksOS => {
            switch (toolbox.THIS_HARDWARE) {
                .AMD64 => {
                    const COM1_PORT_ADDRESS = 0x3F8;
                    for (to_print) |b| {
                        asm volatile (
                            \\outb %%al, %%dx
                            :
                            : [data] "{al}" (b),
                              [port] "{dx}" (COM1_PORT_ADDRESS),
                            : "rax", "rdx"
                        );
                    }
                },
                else => {
                    //TODO
                },
            }
        },
        else => @compileError("TODO"),
    }
    //TODO think about stderr
    //TODO won't work on windows
}
