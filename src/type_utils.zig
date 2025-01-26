const toolbox = @import("toolbox.zig");
const std = @import("std");
pub fn is_iterable(x: anytype) bool {
    const T = if (@TypeOf(x) == type) x else @TypeOf(x);
    const ti = @typeInfo(T);
    const ret = switch (comptime ti) {
        .pointer => |ptr_info| switch (ptr_info.size) {
            .slice, .many, .c => true,
            .one => !is_single_pointer(ptr_info.child) and is_iterable(ptr_info.child),
        },
        .array => true,
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
        .pointer => |ptr_info| return ptr_info.size == .one,
        else => return false,
    }
}

pub fn is_string_type(comptime Type: type) bool {
    if (Type == toolbox.String8) {
        return true;
    }
    const ti = @typeInfo(Type);
    switch (comptime ti) {
        .pointer => |info| {
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
        .pointer => |info| {
            return info.child;
        },
        .optional => |info| {
            return info.child;
        },
        else => {
            @compileError("Must be a pointer or optional type!");
        },
    }
}

pub fn FieldType(comptime T: type, comptime field_name: []const u8) type {
    const ti = @typeInfo(T);
    switch (ti) {
        .@"struct" => |s| {
            inline for (s.fields) |f| {
                if (std.mem.eql(u8, field_name, f.name)) {
                    return f.type;
                }
            }
        },
        else => {},
    }
    @compileError("No field '" ++ field_name ++ "' found for type " ++ @typeName(T));
}

pub fn is_optional(x: anytype) bool {
    const ti = @typeInfo(@TypeOf(x));
    return ti == .optional;
}

pub fn enum_size(comptime T: type) usize {
    return comptime @typeInfo(T).@"enum".fields.len;
}

pub fn ptr_cast(comptime T: type, ptr: anytype) T {
    const ti = @typeInfo(T);
    if (ti != .pointer) {
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
    const ti = if (@typeInfo(Type) == .pointer)
        @typeInfo(@typeInfo(Type).pointer.child)
    else
        @typeInfo(Type);
    inline for (ti.@"struct".fields, 0..) |field, i| {
        const name = field.name;
        try writer.writeAll(name ++ ": ");
        switch (@typeInfo(field.type)) {
            .int, .comptime_int => {
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
        if (i != ti.@"struct".fields.len - 1) {
            if ((i + 1) % 4 == 0) {
                try writer.writeAll("\n");
            } else {
                try writer.writeAll(", ");
            }
        }
    }
}

pub fn to_const_bytes(v: anytype) []const u8 {
    const T = @TypeOf(v);
    if (comptime T == []const u8) {
        return v;
    }
    if (comptime T == toolbox.String8) {
        return v.bytes;
    }
    const ti = @typeInfo(T);
    switch (comptime ti) {
        .pointer => |info| {
            const Child = info.child;
            switch (comptime info.size) {
                .slice => {
                    return @as([*]const u8, @ptrCast(v.ptr))[0 .. @sizeOf(Child) * v.len];
                },
                .one => {
                    return @as([*]const u8, @ptrCast(v))[0..@sizeOf(Child)];
                },
                else => {
                    @compileError("Parameter must be a single pointer or slice!");
                },
            }
        },
        else => {
            @compileError("Parameter must be a single pointer or slice!");
        },
    }
}

pub fn to_bytes(v: anytype) []u8 {
    const T = @TypeOf(v);
    if (comptime T == []u8) {
        return v;
    }
    if (comptime T == toolbox.String8) {
        return v.bytes;
    }
    const ti = @typeInfo(T);
    switch (comptime ti) {
        .pointer => |info| {
            const Child = info.child;
            switch (comptime info.size) {
                .slice => {
                    return @as([*]u8, @ptrCast(v.ptr))[0 .. @sizeOf(Child) * v.len];
                },
                .one => {
                    return @as([*]u8, @ptrCast(v))[0..@sizeOf(Child)];
                },
                else => {
                    @compileError("Parameter must be a single pointer or slice!");
                },
            }
        },
        else => {
            @compileError("Parameter must be a single pointer or slice!");
        },
    }
}
