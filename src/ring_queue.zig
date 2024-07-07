const toolbox = @import("toolbox.zig");

const Common = @This();
//
//[] rcursor = 0, wcursor = 0, len = 0, max = 3
//[1] rcursor = 0, wcursor = 1, len = 1, max =3
//[1, 2] rcursor = 0, wcursor = 2, len = 2, max =3
//[1, 2, 3] rcursor = 0, wcursor = 0, len = 3, max =3
//
//
pub fn RingQueue(comptime T: type) type {
    return struct {
        data: []T,
        rcursor: usize,
        wcursor: usize,

        pub const Iterator = struct {
            cursor: usize,
            queue: *const Self,

            pub fn next(self: *@This()) ?T {
                if (self.cursor == self.queue.wcursor) {
                    return null;
                }
                const ret = self.queue.data[self.cursor];
                next_ring_index(&self.cursor, self.queue.data.len);
                return ret;
            }
        };

        const Self = @This();

        pub fn init(ring_len: usize, arena: *toolbox.Arena) Self {
            if (ring_len == 0) {
                toolbox.panic("RingQueue len must be > 0! Was: {}", .{ring_len});
            }
            var len = ring_len;
            if (!toolbox.is_power_of_2(ring_len)) {
                len = toolbox.next_power_of_2(ring_len);
            }
            return .{
                .data = arena.push_slice(T, len),
                .rcursor = 0,
                .wcursor = 0,
            };
        }

        pub fn iterator(self: *const Self) Iterator {
            return .{
                .cursor = self.rcursor,
                .queue = self,
            };
        }

        pub fn clone(self: *const Self, arena: *toolbox.Arena) Self {
            const data_copy = arena.push_slice(T, self.data.len);
            for (data_copy, self.data) |*d, s| d.* = s;
            return .{
                .data = data_copy,
                .rcursor = self.rcursor,
                .wcursor = self.wcursor,
            };
        }

        pub fn clear(self: *Self) void {
            self.rcursor = 0;
            self.wcursor = 0;
        }

        //returns false if queue is full, else true
        pub fn enqueue(self: *Self, value: T) bool {
            var next_wcursor = self.wcursor;
            next_ring_index(&next_wcursor, self.data.len);
            if (next_wcursor == self.rcursor) {
                return false;
            }
            self.data[self.wcursor] = value;
            self.wcursor = next_wcursor;
            return true;
        }
        pub fn force_enqueue(self: *Self, value: T) void {
            if (!self.enqueue(value)) {
                _ = self.dequeue();
                if (!self.enqueue(value)) {
                    toolbox.panic("Could not force enqueue after enqueuing! Ensure only 1 thread is enqueueing.", .{});
                }
            }
        }
        pub inline fn enqueue_expecting_room(self: *Self, value: T) void {
            if (!self.enqueue(value)) {
                toolbox.panic("Queue full!", .{});
            }
        }
        pub fn dequeue(self: *Self) ?T {
            if (self.rcursor == self.wcursor) {
                return null;
            }
            const ret = self.data[self.rcursor];
            next_ring_index(&self.rcursor, self.data.len);
            return ret;
        }
        pub inline fn is_empty(self: Self) bool {
            return self.rcursor == self.wcursor;
        }
        pub inline fn is_full(self: Self) bool {
            var tmp_cursor = self.wcursor;
            next_ring_index(&tmp_cursor, self.data.len);
            return tmp_cursor == self.rcursor;
        }
    };
}
pub fn MultiProducerMultiConsumerRingQueue(comptime T: type) type {
    return struct {
        data: []T,
        rcursor: usize,
        wcursor: usize,
        reserved_wcursor: usize,
        reserved_rcursor: usize,
        used: isize,
        free: isize,

        const Self = @This();

        pub fn init(ring_len: usize, arena: *toolbox.Arena) Self {
            if (ring_len == 0) {
                toolbox.panic("RingQueue len must be > 0! Was: {}", .{ring_len});
            }
            var len = ring_len;
            if (!toolbox.is_power_of_2(ring_len)) {
                len = toolbox.next_power_of_2(ring_len);
            }
            return .{
                .data = arena.push_slice(T, len),
                .rcursor = 0,
                .wcursor = 0,
                .reserved_wcursor = 0,
                .reserved_rcursor = 0,
                .used = 0,
                .free = @intCast(len),
            };
        }
        pub inline fn is_empty(self: Self) bool {
            return @atomicLoad(usize, &self.free, .acquire) == self.data.len;
        }
        pub inline fn is_full(self: Self) bool {
            return @atomicLoad(usize, &self.used, .acquire) == self.data.len;
        }
        pub fn enqueue(self: *Self, value: T) bool {
            const NUMBER_OF_ITEMS = 1;
            while (true) {
                const wcursor = @atomicLoad(usize, &self.reserved_wcursor, .acquire);
                if (@atomicLoad(isize, &self.free, .monotonic) < NUMBER_OF_ITEMS) {
                    return false;
                }
                var next_wcursor = wcursor;
                next_ring_index(&next_wcursor, self.data.len);
                _ = @atomicRmw(isize, &self.free, .Sub, NUMBER_OF_ITEMS, .monotonic);
                if (@cmpxchgStrong(
                    usize,
                    &self.reserved_wcursor,
                    wcursor,
                    next_wcursor,
                    .acquire,
                    .monotonic,
                ) == null) {
                    self.data[wcursor] = value;
                    @fence(.release);
                    while (@cmpxchgStrong(
                        usize,
                        &self.wcursor,
                        wcursor,
                        next_wcursor,
                        .acquire,
                        .monotonic,
                    ) != null) {}
                    _ = @atomicRmw(isize, &self.used, .Add, NUMBER_OF_ITEMS, .monotonic);

                    return true;
                } else {
                    _ = @atomicRmw(isize, &self.free, .Add, NUMBER_OF_ITEMS, .monotonic);
                }
            }
        }

        //In order to support force_enqueue this we must support multiple consumers
        //since it we can call dequeue and it is assumed the producer is on a separate thread
        pub fn force_enqueue(self: *Self, value: T) void {
            if (!self.enqueue(value)) {
                _ = self.dequeue();
                if (!self.enqueue(value)) {
                    toolbox.panic("Could not force enqueue after dequeuing! Ensure only 1 thread is enqueueing.", .{});
                }
            }
        }
        pub fn dequeue(self: *Self) ?T {
            const NUMBER_OF_ITEMS = 1;
            while (true) {
                const rcursor = @atomicLoad(usize, &self.reserved_rcursor, .monotonic);
                if (@atomicLoad(isize, &self.used, .acquire) < NUMBER_OF_ITEMS) {
                    return null;
                }
                var next_rcursor = rcursor;
                next_ring_index(&next_rcursor, self.data.len);
                _ = @atomicRmw(isize, &self.used, .Sub, NUMBER_OF_ITEMS, .monotonic);
                if (@cmpxchgStrong(
                    usize,
                    &self.reserved_rcursor,
                    rcursor,
                    next_rcursor,
                    .acquire,
                    .monotonic,
                ) == null) {
                    const ret = self.data[rcursor];
                    @fence(.release);
                    while (@cmpxchgStrong(
                        usize,
                        &self.rcursor,
                        rcursor,
                        next_rcursor,
                        .acquire,
                        .monotonic,
                    ) != null) {}
                    _ = @atomicRmw(isize, &self.free, .Add, NUMBER_OF_ITEMS, .monotonic);

                    return ret;
                } else {
                    _ = @atomicRmw(isize, &self.used, .Add, NUMBER_OF_ITEMS, .monotonic);
                }
            }
        }
    };
}
inline fn next_ring_index(i: *usize, len: usize) void {
    i.* = (i.* + 1) & (len - 1);
}
