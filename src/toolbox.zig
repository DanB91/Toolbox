pub usingnamespace @import("print.zig");
pub usingnamespace @import("assert.zig");
pub usingnamespace @import("type_utils.zig");
pub usingnamespace @import("time.zig");
pub usingnamespace @import("memory.zig");
pub usingnamespace @import("byte_math.zig");
pub usingnamespace @import("linked_list.zig");
pub usingnamespace @import("hash_map.zig");
pub usingnamespace @import("string.zig");
pub usingnamespace @import("stack.zig");
pub usingnamespace @import("fixed_list.zig");
pub usingnamespace @import("ring_queue.zig");
pub usingnamespace @import("random.zig");
pub usingnamespace @import("dynamic_array.zig");
pub usingnamespace @import("os_utils.zig");
pub usingnamespace @import("atomic.zig");
pub usingnamespace @import("bit_flags.zig");
pub usingnamespace @import("panic.zig");

pub const fiber = @import("fiber.zig");
pub const profiler = @import("profiler.zig");
const builtin = @import("builtin");
const build_flags = @import("build_flags");
const root = @import("root");
const std = @import("std");
const byte_math = @import("byte_math.zig");
const os_utils = @import("os_utils.zig");
const print = @import("print.zig");

pub const Platform = enum {
    MacOS,
    Linux,
    Windows,
    Playdate,
    BoksOS,
    Wozmon64,
    Emscripten,
    UEFI,
};

pub const Hardware = enum {
    AMD64,
    ARM64,
    WASM32,
    Playdate,
};

pub const THIS_PLATFORM: Platform = if (@hasDecl(root, "THIS_PLATFORM"))
    root.THIS_PLATFORM
else switch (builtin.os.tag) {
    .macos => .MacOS,
    .linux => .Linux,
    .windows => .Windows,
    .uefi => .UEFI,
    .emscripten => .Emscripten,
    else => @compileError("Platform not yet supported"),
};

pub const THIS_HARDWARE: Hardware = switch (builtin.cpu.arch) {
    .x86_64 => .AMD64,
    .aarch64 => .ARM64,
    .wasm32 => .WASM32,
    .thumb => if (THIS_PLATFORM == .Playdate)
        .Playdate
    else
        @compileError("Hardware not yet supported"),
    else => @compileError("Hardware not yet supported"),
};

pub const IS_DEBUG = builtin.mode == .Debug;

////BoksOS runtime functions
pub var boksos_kernel_heap: *std.mem.Allocator = undefined;
pub fn init_boksos_runtime(kernel_heap: *std.mem.Allocator) void {
    boksos_kernel_heap = kernel_heap;
}

////Playdate runtime functions
pub var playdate_realloc: *const fn (?*anyopaque, usize) callconv(.C) ?*anyopaque = undefined;
pub var playdate_log_to_console: *const fn ([*c]const u8, ...) callconv(.C) void = undefined;
pub var playdate_error: *const fn ([*c]const u8, ...) callconv(.C) void = undefined;
pub var playdate_get_seconds: *const fn () callconv(.C) f32 = undefined;
pub var playdate_get_milliseconds: *const fn () callconv(.C) u32 = undefined;

pub fn init_playdate_runtime(
    _playdate_realloc: *const fn (?*anyopaque, usize) callconv(.C) ?*anyopaque,
    _playdate_log_to_console: *const fn ([*c]const u8, ...) callconv(.C) void,
    _playdate_error: *const fn ([*c]const u8, ...) callconv(.C) void,
    _playdate_get_seconds: *const fn () callconv(.C) f32,
    _playdate_get_milliseconds: *const fn () callconv(.C) u32,
) void {
    if (comptime THIS_PLATFORM != .Playdate) {
        @compileError("Only call this for the Playdate!");
    }
    playdate_realloc = _playdate_realloc;
    playdate_log_to_console = _playdate_log_to_console;
    playdate_error = _playdate_error;
    playdate_get_seconds = _playdate_get_seconds;
    playdate_get_milliseconds = _playdate_get_milliseconds;
}

//C bridge functions
export fn c_assert(cond: bool) void {
    if (!cond) {
        unreachable;
    }
}
