const toolbox = @import("toolbox.zig");
const std = @import("std");
pub const INITIAL_HASH_MAP_CAPACITY = 32;
pub fn HashMap(comptime Key: type, comptime Value: type) type {
    return struct {
        keys: toolbox.DynamicArray(?Key) = .{},
        values: toolbox.DynamicArray(Value) = .{},
        len: usize = 0,
        cap: usize = 0,

        //debugging fields
        hash_collisions: usize = 0,
        index_collisions: usize = 0,
        reprobe_collisions: usize = 0,
        bad_reprobe_collisions: usize = 0,

        pub const KeyValue = struct {
            k: Key,
            v: Value,
        };
        const Self = @This();
        pub const Iterator = struct {
            hash_map: *const Self,
            cursor: usize = 0,

            pub fn next(self: *Iterator) ?KeyValue {
                while (self.cursor < self.hash_map.keys.len) : (self.cursor += 1) {
                    if (self.hash_map.keys.items()[self.cursor]) |key| {
                        defer self.cursor += 1;
                        return .{
                            .k = key,
                            .v = self.hash_map.values.items()[self.cursor],
                        };
                    }
                }
                return null;
            }
        };

        pub fn put(self: *Self, key: Key, value: Value, arena: *toolbox.Arena) void {
            if (self.cap == 0) {
                self.expand(INITIAL_HASH_MAP_CAPACITY, arena);
                const index = self.index_for_key(key);
                self.keys.items()[index] = key;
                self.values.items()[index] = value;
                self.len += 1;
                return;
            }
            var index = self.index_for_key(key);
            if (self.keys.items()[index] == null) {
                if (self.len == self.cap) {
                    self.expand(self.cap * 2, arena);
                    index = self.index_for_key(key);
                }
                self.keys.items()[index] = key;
                self.len += 1;
            }
            self.values.items()[index] = value;
        }

        pub fn get(self: *Self, key: Key) ?Value {
            if (self.len == 0) {
                return null;
            }

            const index = self.index_for_key(key);
            if (self.keys.items()[index] != null) {
                return self.values.items()[index];
            }
            return null;
        }

        pub fn get_or_put(self: *Self, key: Key, initial_value: Value, arena: *toolbox.Arena) Value {
            if (self.cap == 0) {
                self.expand(INITIAL_HASH_MAP_CAPACITY, arena);
                const index = self.index_for_key(key);
                self.keys.items()[index] = key;
                self.values.items()[index] = initial_value;
                self.len += 1;
                return initial_value;
            }
            var index = self.index_for_key(key);
            if (self.keys.items()[index] == null) {
                if (self.len == self.cap) {
                    self.expand(self.cap * 2, arena);
                    index = self.index_for_key(key);
                }
                self.keys.items()[index] = key;
                self.values.items()[index] = initial_value;
                self.len += 1;
                return initial_value;
            }
            return self.values.items()[index];
        }

        //Pointer may be invalid if expand, put, get_or_put, or get_or_put_ptr is called after this
        //Use sparingly
        pub fn get_ptr(self: *Self, key: Key) ?*Value {
            //Please do not try to merge get() and get_ptr().
            //When you try to do that, you'll see why it doesn't make sense
            if (self.len == 0) {
                return null;
            }

            const index = self.index_for_key(key);
            if (self.keys.items()[index] != null) {
                return &self.values.items()[index];
            }
            return null;
        }

        //Pointer may be invalid if expand, put, get_or_put, or get_or_put_ptr is called after this
        //Use sparingly
        pub fn get_or_put_ptr(self: *Self, key: Key, initial_value: Value, arena: *toolbox.Arena) *Value {
            if (self.cap == 0) {
                self.expand(INITIAL_HASH_MAP_CAPACITY, arena);
                const index = self.index_for_key(key);
                self.keys.items()[index] = key;
                const value_ptr = &self.values.items()[index];
                value_ptr.* = initial_value;
                self.len += 1;
                return value_ptr;
            }
            var index = self.index_for_key(key);
            var value_ptr = &self.values.items()[index];
            if (self.keys.items()[index] == null) {
                if (self.len == self.cap) {
                    self.expand(self.cap * 2, arena);
                    index = self.index_for_key(key);
                    value_ptr = &self.values.items()[index];
                }
                self.keys.items()[index] = key;
                value_ptr.* = initial_value;
                self.len += 1;
            }
            return value_ptr;
        }

        pub fn remove(self: *Self, key: Key) void {
            if (self.len == 0) {
                return;
            }

            const key_bytes = if (comptime toolbox.is_string_type(Key))
                toolbox.to_const_bytes(key)
            else
                toolbox.to_const_bytes(&key);
            const h = hash_fnv1a64(key_bytes);

            var index: usize = @intCast(h & (self.keys.len - 1));
            var key_ptr = &self.keys.items()[index];
            var did_delete = false;
            if (key_ptr.*) |bucket_key| {
                if (eql(key, bucket_key)) {
                    key_ptr.* = null;
                    did_delete = true;
                }
            } else {
                return;
            }
            self.len -= 1;

            const dest = index;

            //now move collisions "up"

            //re-probe

            {
                const index_bit_size: u6 = @intCast(@ctz(self.keys.len));
                var i = index_bit_size;
                while (i < @bitSizeOf(usize)) : (i += index_bit_size) {
                    index = @intCast((h >> i) & (self.keys.len - 1));
                    key_ptr = &self.keys.items()[index];
                    if (key_ptr.*) |bucket_key| {
                        if (did_delete) {
                            //NOTE: This checks to see if there is a chain
                            if (self.index_for_key(bucket_key) == index) {
                                return;
                            }
                            //TODO: Goddammit, this isn't gonna work if there is a chain of
                            //      entries.  Only works for a chain of 2 entries
                            self.keys.items()[dest] = bucket_key;
                            self.values.items()[dest] = self.values.items()[index];
                            key_ptr.* = null;
                        } else if (eql(bucket_key, key)) {
                            key_ptr.* = null;
                            did_delete = true;
                        }
                    } else {
                        return;
                    }
                }
            }

            //last ditch effort
            {
                const end = index;
                index += 1;
                while (index != end) : (index = (index + 1) & (self.keys.len - 1)) {
                    key_ptr = &self.keys.items()[index];
                    if (key_ptr.*) |bucket_key| {
                        if (did_delete) {
                            self.keys.items()[dest] = bucket_key;
                            self.values.items()[dest] = self.values.items()[index];
                            key_ptr.* = null;
                        } else if (eql(bucket_key, key)) {
                            key.* = null;
                            did_delete = true;
                        }
                    } else {
                        return;
                    }
                }
            }
            toolbox.panic("Should not get here!", .{});
        }
        pub inline fn clear(self: *Self) void {
            self.len = 0;
            for (self.keys) |*key| key.* = null;
        }

        pub fn clone(self: *const Self, arena: *toolbox.Arena) Self {
            const k = self.keys.clone(arena);
            const v = self.values.clone(arena);
            return .{
                .keys = k,
                .values = v,
                .len = self.len,
            };
        }
        pub fn expand(self: *Self, new_capacity: usize, arena: *toolbox.Arena) void {
            const _cap = @max(new_capacity, INITIAL_HASH_MAP_CAPACITY);
            const new_num_buckets =
                toolbox.next_power_of_2(@as(usize, @intFromFloat(@as(f64, @floatFromInt(_cap)) * 1.5)));

            var keys = toolbox.DynamicArray(?Key){};
            keys.expand(new_num_buckets, arena);
            keys.len = keys.cap;
            @memset(keys.items(), null);

            var values = toolbox.DynamicArray(Value){};
            values.expand(new_num_buckets, arena);
            values.len = values.cap;

            if (self.len > 0) {
                var tmp_map = Self{
                    .keys = keys,
                    .values = values,
                };
                for (self.keys.items(), self.values.items()) |key_opt, value| {
                    if (key_opt) |key| {
                        const index = tmp_map.index_for_key(key);
                        tmp_map.keys.items()[index] = key;
                        tmp_map.values.items()[index] = value;
                    }
                }
            }
            self.keys = keys;
            self.values = values;
            self.cap = _cap;
        }

        pub fn iterator(self: *const Self) Iterator {
            return .{
                .hash_map = self,
            };
        }

        fn index_for_key(self: *Self, key: Key) usize {
            const key_bytes = if (comptime toolbox.is_string_type(Key))
                toolbox.to_const_bytes(key)
            else
                toolbox.to_const_bytes(&key);
            const h = hash_fnv1a64(key_bytes);

            var index: usize = @intCast(h & (self.keys.len - 1));

            var key_ptr = &self.keys.items()[index];

            if (key_ptr.*) |bucket_key| {
                if (eql(bucket_key, key)) {
                    return index;
                }
            } else {
                return index;
            }

            self.index_collisions += 1;
            //re-probe
            {
                const index_bit_size: u6 = @intCast(@ctz(self.keys.len));
                var i = index_bit_size;
                while (i < @bitSizeOf(usize)) : (i += index_bit_size) {
                    self.reprobe_collisions += 1;
                    index = @intCast((h >> i) & (self.keys.len - 1));
                    key_ptr = &self.keys.items()[index];

                    if (key_ptr.*) |bucket_key| {
                        if (eql(bucket_key, key)) {
                            return index;
                        }
                    } else {
                        return index;
                    }
                }
            }

            //last ditch effort
            {
                const end = index;
                index += 1;
                while (index != end) : (index = (index + 1) & (self.keys.len - 1)) {
                    self.bad_reprobe_collisions += 1;
                    key_ptr = &self.keys.items()[index];
                    if (key_ptr.*) |bucket_key| {
                        if (eql(bucket_key, key)) {
                            return index;
                        }
                    } else {
                        return index;
                    }
                }
            }
            toolbox.panic("Should not get here!", .{});
        }
    };
}
pub fn hash_fnv1a64(data: []const u8) u64 {
    const seed = 0xcbf29ce484222325;
    var h: u64 = seed;
    for (data) |b| {
        h = (h ^ @as(u64, b)) *% 0x100000001b3;
    }
    return h;
}

fn eql(a: anytype, b: @TypeOf(a)) bool {
    const T = @TypeOf(a);
    if (comptime T == toolbox.String8) {
        return toolbox.string_equals(a, b);
    }

    switch (comptime @typeInfo(T)) {
        .@"struct" => |info| {
            inline for (info.fields) |field_info| {
                if (!eql(@field(a, field_info.name), @field(b, field_info.name))) return false;
            }
            return true;
        },
        .error_union => {
            if (a) |a_p| {
                if (b) |b_p| return eql(a_p, b_p) else |_| return false;
            } else |a_e| {
                if (b) |_| return false else |b_e| return a_e == b_e;
            }
        },
        //.@"union" => |info| {
        //if (info.tag_type) |UnionTag| {
        //const tag_a = activeTag(a);
        //const tag_b = activeTag(b);
        //if (tag_a != tag_b) return false;

        //inline for (info.fields) |field_info| {
        //if (@field(UnionTag, field_info.name) == tag_a) {
        //return eql(@field(a, field_info.name), @field(b, field_info.name));
        //}
        //}
        //return false;
        //}

        //@compileError("cannot compare untagged union type " ++ @typeName(T));
        //},
        .array => {
            if (a.len != b.len) return false;
            for (a, 0..) |e, i|
                if (!eql(e, b[i])) return false;
            return true;
        },
        .vector => |info| {
            var i: usize = 0;
            while (i < info.len) : (i += 1) {
                if (!eql(a[i], b[i])) return false;
            }
            return true;
        },
        .pointer => |info| {
            return switch (info.size) {
                .One, .Many, .C => a == b,
                //changed from std.meta.eql
                .Slice => std.mem.eql(info.child, a, b),
            };
        },
        .optional => {
            if (a == null and b == null) return true;
            if (a == null or b == null) return false;
            return eql(a.?, b.?);
        },
        else => return a == b,
    }
}
