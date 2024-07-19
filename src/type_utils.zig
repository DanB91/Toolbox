const toolbox = @import("toolbox.zig");
const std = @import("std");
pub fn is_iterable(x: anytype) bool {
    const T = if (@TypeOf(x) == type) x else @TypeOf(x);
    const ti = @typeInfo(T);
    const ret = switch (comptime ti) {
        .Pointer => |ptr_info| switch (ptr_info.size) {
            .Slice, .Many, .C => true,
            .One => !is_single_pointer(ptr_info.child) and is_iterable(ptr_info.child),
        },
        .Array => true,
        else => false,
    };
    if (@TypeOf(T) != type and ret) {
        //compile time assertion that the type is iterable
        for (x) |_| {}
    }
    return ret;
}
pub fn is_single_pointer(x: anytype) bool {
    const T = if (@TypeOf(x) == type) x else @TypeOf(x);
    const ti = @typeInfo(T);
    switch (comptime ti) {
        .Pointer => |ptr_info| return ptr_info.size == .One,
        else => return false,
    }
}

pub fn is_string_type(comptime Type: type) bool {
    if (Type == toolbox.String8) {
        return true;
    }
    const ti = @typeInfo(Type);
    switch (comptime ti) {
        .Pointer => |info| {
            return info.child == u8;
        },
        else => {
            return false;
        },
    }
}

pub fn ChildType(comptime T: type) type {
    const ti = @typeInfo(T);
    switch (comptime ti) {
        .Pointer => |info| {
            return info.child;
        },
        .Optional => |info| {
            return info.child;
        },
        else => {
            @compileError("Must be a pointer or optional type!");
        },
    }
}

pub fn is_optional(x: anytype) bool {
    const ti = @typeInfo(@TypeOf(x));
    return ti == .Optional;
}

pub fn enum_size(comptime T: type) usize {
    return comptime @typeInfo(T).Enum.fields.len;
}

pub fn ptr_cast(comptime T: type, ptr: anytype) T {
    const ti = @typeInfo(T);
    if (ti != .Pointer) {
        @compileError("T in ptr_cast must be a pointer");
    }
    return @as(T, @ptrCast(@alignCast(ptr)));
}

pub fn format_struct(
    value: anytype,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    const Type = @TypeOf(value);
    const ti = if (@typeInfo(Type) == .Pointer)
        @typeInfo(@typeInfo(Type).Pointer.child)
    else
        @typeInfo(Type);
    inline for (ti.Struct.fields, 0..) |field, i| {
        const name = field.name;
        try writer.writeAll(name ++ ": ");
        switch (@typeInfo(field.type)) {
            .Int, .ComptimeInt => {
                if (std.mem.eql(u8, fmt, "X") or std.mem.eql(u8, fmt, "x")) {
                    try writer.writeAll("0x");
                }
                try std.fmt.formatIntValue(
                    @field(value, name),
                    fmt,
                    options,
                    writer,
                );
            },
            else => {
                if (field.type == []const u8) {
                    try std.fmt.format(
                        writer,
                        "{s}",
                        .{@field(value, name)},
                    );
                } else {
                    try std.fmt.format(
                        writer,
                        "{}",
                        .{@field(value, name)},
                    );
                }
            },
        }
        if (i != ti.Struct.fields.len - 1) {
            if ((i + 1) % 4 == 0) {
                try writer.writeAll("\n");
            } else {
                try writer.writeAll(", ");
            }
        }
    }
}
