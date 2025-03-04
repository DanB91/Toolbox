const toolbox = @import("toolbox.zig");
const std = @import("std");
const Common = @This();
const c = @cImport({
    @cInclude("mach/mach_vm.h");
    @cInclude("mach/mach_init.h");
    @cInclude("unistd.h");
});
pub const RingQueue = if (toolbox.THIS_PLATFORM == .MacOS)
    MagicRingQueue
else
    NotMagicRingQueue;

pub const make_ring_queue = if (toolbox.THIS_PLATFORM == .MacOS)
    make_magic_ring_queue
else
    make_not_magic_ring_queue;

pub fn make_not_magic_ring_queue(comptime T: type, at_least_n: usize, arena: *toolbox.Arena) NotMagicRingQueue(T) {
    const n_pow_of_2 = toolbox.next_power_of_2(at_least_n);
    const data = arena.push_slice(T, n_pow_of_2);
    const result = NotMagicRingQueue(T){ .data = data };
    return result;
}

pub fn make_magic_ring_queue(comptime T: type, at_least_n: usize, arena: *toolbox.Arena) MagicRingQueue(T) {
    const n_pow_of_2 = toolbox.next_power_of_2(at_least_n);
    const page_size: usize = @intCast(c.getpagesize());
    var lcm = (page_size * n_pow_of_2) / std.math.gcd(page_size, n_pow_of_2);
    lcm = (lcm * @sizeOf(T)) / std.math.gcd(@sizeOf(T), lcm);

    const n_bytes = lcm;
    const n = lcm / @sizeOf(T);

    toolbox.expect(toolbox.is_power_of_2(n), "n was not a power of 2 as expected, but was: {}", .{n});

    const backing_store_bytes = arena.push_bytes_aligned_runtime(n_bytes, page_size);
    const backing_store = @as([*]T, @ptrCast(@alignCast(backing_store_bytes.ptr)))[0..n];

    var magic_ring_buffer_address_start: u64 = 0;
    const src_address = @intFromPtr(backing_store.ptr);

    const page_mask = page_size - 1;
    var protection: c.vm_prot_t = c.VM_PROT_READ | c.VM_PROT_WRITE;
    var kern_error: c.kern_return_t = 0;
    const self = c.mach_task_self();

    kern_error = c.mach_vm_remap(
        self,
        &magic_ring_buffer_address_start,
        n_bytes,
        page_mask,
        c.VM_FLAGS_ANYWHERE,
        self,
        src_address,
        0,
        &protection,
        &protection,
        c.VM_INHERIT_NONE,
    );
    toolbox.expect(
        kern_error == c.KERN_SUCCESS,
        "Magic ring buffer memory mapping failed! Error code: {}",
        .{kern_error},
    );

    var ring_buffer_second_half = magic_ring_buffer_address_start + n_bytes;
    kern_error = c.mach_vm_remap(
        self,
        &ring_buffer_second_half,
        n_bytes,
        page_mask,
        c.VM_FLAGS_FIXED | c.VM_FLAGS_OVERWRITE,
        self,
        src_address,
        0,
        &protection,
        &protection,
        c.VM_INHERIT_NONE,
    );
    toolbox.expect(
        kern_error == c.KERN_SUCCESS,
        "Magic ring buffer memory mapping failed! Error code: {}",
        .{kern_error},
    );

    const ring_buffer = @as([*]T, @ptrFromInt(magic_ring_buffer_address_start))[0 .. n * 2];
    const result = MagicRingQueue(T){
        .data = ring_buffer,
    };
    return result;
}

pub fn MagicRingQueue(T: type) type {
    return struct {
        data: []T = toolbox.z([]T),
        rcursor: usize = 0,
        wcursor: usize = 0,
        //TODO:
        // lock: std.Thread.Mutex = .{},
        _len: usize = 0, // for debugger purposes only

        const Self = @This();
        pub fn enqueue(self: *Self, in: []const T) void {
            toolbox.expect(self.unoccupied() >= in.len, "Queue full!", .{});
            const buf = self.enqueue_buffer();
            const n = @min(buf.len, in.len);
            @memcpy(buf[0..n], in[0..n]);
            self.update_enqueued(n);
        }
        pub fn dequeue(self: *Self, out: []T) []T {
            var buf = self.dequeue_buffer();
            const n = @min(buf.len, out.len);
            const result = out[0..n];
            @memcpy(result, buf[0..n]);
            if (comptime toolbox.IS_DEBUG) {
                @memset(buf[0..n], undefined);
            }
            self.update_dequeued(n);
            return result;
        }
        pub fn enqueue_one(self: *Self, value: T) void {
            var store = [1]T{value};
            self.enqueue(&store);
        }

        pub fn dequeue_one(self: *Self) ?T {
            var store = [1]T{undefined};
            const slice = self.dequeue(&store);
            if (slice.len > 0) {
                return slice[0];
            } else {
                return null;
            }
        }

        pub fn peek(self: *Self, out: []T) []T {
            var buf = self.dequeue_buffer();
            const n = @min(buf.len, out.len);
            const result = out[0..n];
            @memcpy(result, buf[0..n]);
            return result;
        }

        pub inline fn enqueue_buffer(self: *Self) []T {
            const n = self.unoccupied();
            const result = self.data[self.wcursor .. self.wcursor + n];
            return result;
        }
        pub inline fn dequeue_buffer(self: *Self) []T {
            const n = self.len();
            const result = self.data[self.rcursor .. self.rcursor + n];
            return result;
        }
        pub fn update_enqueued(self: *Self, n: usize) void {
            self.advance_cursor(&self.wcursor, n);
            self._len += n;
            self.validate_cursors();
        }
        pub fn update_dequeued(self: *Self, n: usize) void {
            if (toolbox.IS_DEBUG) {
                @memset(self.data[self.rcursor .. self.rcursor + n], undefined);
            }
            self.advance_cursor(&self.rcursor, n);
            self._len -= n;
            self.validate_cursors();
        }
        pub inline fn len(self: Self) usize {
            var result: usize = 0;
            if (self.wcursor >= self.rcursor) {
                result = self.wcursor - self.rcursor;
            } else {
                result = (self.cap() + 1 - self.rcursor) + self.wcursor;
            }
            return result;
        }
        pub inline fn cap(self: Self) usize {
            if (self.data.len == 0) {
                return 0;
            }
            const result = (self.data.len / 2) - 1;
            return result;
        }
        pub inline fn unoccupied(self: Self) usize {
            const result = self.cap() - self.len();
            return result;
        }
        pub inline fn clear(self: *Self) void {
            self.rcursor = 0;
            self.wcursor = 0;
            self._len = 0;
        }
        inline fn advance_cursor(self: Self, i: *usize, n: usize) void {
            i.* = (i.* + n) & self.cap();
        }

        fn validate_cursors(self: Self) void {
            if (comptime toolbox.IS_DEBUG) {
                const expected = self._len;
                const actual = self.len();
                toolbox.asserteq(
                    expected,
                    actual,
                    "Unexpected ring queue len",
                );
            }
        }
    };
}
pub fn NotMagicRingQueue(T: type) type {
    return struct {
        data: []T = toolbox.z([]T),
        rcursor: usize = 0,
        wcursor: usize = 0,
        _len: usize = 0, // for debugger purposes only
        //TODO
        // lock: std.Thread.Mutex = .{},

        const Self = @This();

        pub fn enqueue(self: *Self, in: []const T) void {
            toolbox.expect(self.unoccupied() >= in.len, "Queue full!", .{});
            var buf = self.enqueue_buffer();
            var n = @min(buf.len, in.len);
            @memcpy(buf[0..n], in[0..n]);
            self.update_enqueued(n);

            if (buf.len < in.len) {
                const cursor = buf.len;
                const left = in.len - cursor;
                buf = self.enqueue_buffer();
                toolbox.expect(buf.len >= left, "Nooo!", .{});
                n = @min(buf.len, left);
                @memcpy(buf[0..n], in[cursor..]);
                self.update_enqueued(n);
            }
        }
        pub fn dequeue(self: *Self, out: []T) []T {
            const to_dequeue = @min(out.len, self.len());
            var left = to_dequeue;
            var buf = self.dequeue_buffer();
            const first_part = @min(buf.len, out.len);
            @memcpy(out[0..first_part], buf[0..first_part]);
            self.update_dequeued(first_part);
            left -= first_part;
            if (left > 0) {
                buf = self.dequeue_buffer();
                const second_part = @min(buf.len, left);
                @memcpy(
                    out[first_part .. first_part + second_part],
                    buf[0..second_part],
                );
                self.update_dequeued(second_part);
            }
            const result = out[0..to_dequeue];
            return result;
        }
        pub fn peek(self: *Self, out: []T) []T {
            const to_dequeue = @min(out.len, self.len());
            var left = to_dequeue;
            var buf = self.dequeue_buffer();
            const first_part = @min(buf.len, out.len);
            @memcpy(out[0..first_part], buf[0..first_part]);
            left -= first_part;
            if (left > 0) {
                buf = self.data[0..@min(left, self.wcursor - 1)];
                const second_part = @min(buf.len, left);
                @memcpy(
                    out[first_part .. first_part + second_part],
                    buf[0..second_part],
                );
            }
            const result = out[0..to_dequeue];
            return result;
        }
        pub fn enqueue_one(self: *Self, value: T) void {
            var store = [1]T{value};
            self.enqueue(&store);
        }

        pub fn dequeue_one(self: *Self) ?T {
            var store = [1]T{undefined};
            const slice = self.dequeue(&store);
            if (slice.len > 0) {
                return slice[0];
            } else {
                return null;
            }
        }

        pub inline fn enqueue_buffer(self: *Self) []T {
            const n = @min(self.unoccupied(), self.data.len - self.wcursor);
            const result = self.data[self.wcursor .. self.wcursor + n];
            return result;
        }
        pub inline fn dequeue_buffer(self: *Self) []T {
            const n = @min(self.len(), self.data.len - self.rcursor);
            const result = self.data[self.rcursor .. self.rcursor + n];
            return result;
        }
        pub fn update_enqueued(self: *Self, n: usize) void {
            self.advance_cursor(&self.wcursor, n);
            self._len += n;
            self.validate_cursors();
        }
        pub fn update_dequeued(self: *Self, n: usize) void {
            if (toolbox.IS_DEBUG) {
                @memset(self.data[self.rcursor .. self.rcursor + n], undefined);
            }
            self.advance_cursor(&self.rcursor, n);
            self._len -= n;
            self.validate_cursors();
        }
        pub inline fn len(self: Self) usize {
            var result: usize = 0;
            const wcursor = @atomicLoad(usize, &self.wcursor, .acquire);
            const rcursor = @atomicLoad(usize, &self.rcursor, .acquire);
            if (wcursor >= rcursor) {
                result = wcursor - rcursor;
            } else {
                result = (self.cap() + 1 - rcursor) + wcursor;
            }
            return result;
        }
        pub inline fn cap(self: Self) usize {
            if (self.data.len == 0) {
                return 0;
            }
            const result = (self.data.len) - 1;
            return result;
        }
        pub inline fn unoccupied(self: Self) usize {
            const result = self.cap() - self.len();
            return result;
        }
        pub inline fn clear(self: *Self) void {
            self.rcursor = 0;
            self.wcursor = 0;
            self._len = 0;
        }
        inline fn advance_cursor(self: Self, i: *usize, n: usize) void {
            i.* = (i.* + n) & self.cap();
        }

        fn validate_cursors(self: Self) void {
            if (comptime toolbox.IS_DEBUG) {
                const expected = self._len;
                const actual = self.len();
                toolbox.asserteq(
                    expected,
                    actual,
                    "Unexpected ring queue len",
                );
            }
        }
    };
}
// pub fn Channel(T: type) type {
//     return struct {
//         data: []T = toolbox.z([]T),
//         rcursor: usize = 0,
//         wcursor: usize = 0,
//         lock: u32 = 0,
//         _len: usize = 0,

//         const Self = @This();

//         pub fn enqueue(self: *Self, in: []const T) void {
//             if (self.cap() - self._len < in.len) {
//                 toolbox.panic(
//                     "Queue is full. Capacity: {}. Tried to enqueue: {}",
//                     .{ self.cap(), in.len },
//                 );
//             }
//             @memcpy(self.data[self.wcursor .. self.wcursor + in.len], in);
//             self.update_enqueued(in.len);
//         }
//         pub fn dequeue(self: *Self, out: []T) []T {
//             const result = self.peek(out);
//             self.update_dequeued(result.len);
//             return result;
//         }
//         pub fn peek(self: *Self, out: []T) []T {
//             const n = @min(out.len, self._len);
//             const result = out[0..n];
//             @memcpy(result, self.data[self.rcursor .. self.rcursor + n]);
//             return result;
//         }
//         pub inline fn enqueue_buffer(self: *Self, n: usize) []T {
//             const result = self.data[self.wcursor .. self.wcursor + n];
//             return result;
//         }
//         pub inline fn dequeue_buffer(self: *Self, n: usize) []T {
//             const result = self.data[self.rcursor .. self.rcursor + n];
//             return result;
//         }
//         pub fn update_enqueued(self: *Self, n: usize) void {
//             self.advance_cursor(&self.wcursor, n);
//             self._len += n;
//         }
//         pub fn update_dequeued(self: *Self, n: usize) void {
//             self.advance_cursor(&self.rcursor, n);
//             self._len -= n;
//         }
//         pub inline fn len(self: Self) usize {
//             return @atomicLoad(usize, self._len, .acquire);
//         }
//         pub inline fn cap(self: Self) usize {
//             const result = self.data.len / 2;
//             return result;
//         }
//         pub inline fn unoccupied(self: Self) usize {
//             const result = self.cap() - self.len();
//             return result;
//         }
//         pub inline fn clear(self: *Self) void {
//             self.rcursor = 0;
//             self.wcursor = 0;
//             self._len = 0;
//         }
//         inline fn advance_cursor(self: Self, i: *usize, n: usize) void {
//             i.* = (i.* + n) & (self.cap() - 1);
//         }
//         fn lock(self: *Self) void {
//             while (@cmpxchgStrong(
//                 u32,
//                 &self.lock,
//                 0,
//                 1,
//                 .acquire,
//                 .monotonic,
//             )) |val| {
//                 std.Thread.Futex.wait(&self.lock, val);
//             }
//         }
//         fn unlock(self: *Self) void {
//             @atomicStore(u32, &self.lock, 0, .release);
//             std.Thread.Futex.wake(&self.lock, 1);
//         }
//     };
// }

//
//[] rcursor = 0, wcursor = 0, len = 0, max = 3
//[1] rcursor = 0, wcursor = 1, len = 1, max =3
//[1, 2] rcursor = 0, wcursor = 2, len = 2, max =3
//[1, 2, 3] rcursor = 0, wcursor = 0, len = 3, max =3
//
//
// pub fn RingQueue(comptime T: type) type {
//     return struct {
//         data: []T,
//         rcursor: usize,
//         wcursor: usize,

//         pub const Iterator = struct {
//             cursor: usize,
//             queue: *const Self,

//             pub fn next(self: *@This()) ?T {
//                 if (self.cursor == self.queue.wcursor) {
//                     return null;
//                 }
//                 const ret = self.queue.data[self.cursor];
//                 next_ring_index(&self.cursor, self.queue.data.len);
//                 return ret;
//             }
//         };

//         const Self = @This();

//         pub fn init(ring_len: usize, arena: *toolbox.Arena) Self {
//             if (ring_len == 0) {
//                 toolbox.panic("RingQueue len must be > 0! Was: {}", .{ring_len});
//             }
//             var len = ring_len;
//             if (!toolbox.is_power_of_2(ring_len)) {
//                 len = toolbox.next_power_of_2(ring_len);
//             }
//             return .{
//                 .data = arena.push_slice(T, len),
//                 .rcursor = 0,
//                 .wcursor = 0,
//             };
//         }

//         pub fn iterator(self: *const Self) Iterator {
//             return .{
//                 .cursor = self.rcursor,
//                 .queue = self,
//             };
//         }

//         pub fn clone(self: *const Self, arena: *toolbox.Arena) Self {
//             const data_copy = arena.push_slice(T, self.data.len);
//             for (data_copy, self.data) |*d, s| d.* = s;
//             return .{
//                 .data = data_copy,
//                 .rcursor = self.rcursor,
//                 .wcursor = self.wcursor,
//             };
//         }

//         pub fn clear(self: *Self) void {
//             self.rcursor = 0;
//             self.wcursor = 0;
//         }

//         //returns false if queue is full, else true
//         pub fn enqueue(self: *Self, value: T) bool {
//             var next_wcursor = self.wcursor;
//             next_ring_index(&next_wcursor, self.data.len);
//             if (next_wcursor == self.rcursor) {
//                 return false;
//             }
//             self.data[self.wcursor] = value;
//             self.wcursor = next_wcursor;
//             return true;
//         }
//         pub fn force_enqueue(self: *Self, value: T) void {
//             if (!self.enqueue(value)) {
//                 _ = self.dequeue();
//                 if (!self.enqueue(value)) {
//                     toolbox.panic("Could not force enqueue after enqueuing! Ensure only 1 thread is enqueueing.", .{});
//                 }
//             }
//         }
//         pub inline fn enqueue_expecting_room(self: *Self, value: T) void {
//             if (!self.enqueue(value)) {
//                 toolbox.panic("Queue full!", .{});
//             }
//         }
//         pub fn dequeue(self: *Self) ?T {
//             if (self.rcursor == self.wcursor) {
//                 return null;
//             }
//             const ret = self.data[self.rcursor];
//             next_ring_index(&self.rcursor, self.data.len);
//             return ret;
//         }
//         pub inline fn is_empty(self: Self) bool {
//             return self.rcursor == self.wcursor;
//         }
//         pub inline fn is_full(self: Self) bool {
//             var tmp_cursor = self.wcursor;
//             next_ring_index(&tmp_cursor, self.data.len);
//             return tmp_cursor == self.rcursor;
//         }
//     };
// }
pub fn MultiProducerMultiConsumerRingQueue(comptime T: type) type {
    return struct {
        data: []T,
        rcursor: usize,
        wcursor: usize,
        lock: toolbox.SpinLock = .{},

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

        //returns false if queue is full, else true
        pub fn enqueue(self: *Self, value: T) bool {
            self.lock.lock();
            defer self.lock.release();

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
            while (!self.enqueue(value)) {
                _ = self.dequeue();
            }
        }
        pub inline fn enqueue_expecting_room(self: *Self, value: T) void {
            if (!self.enqueue(value)) {
                toolbox.panic("Queue full!", .{});
            }
        }
        pub fn dequeue(self: *Self) ?T {
            self.lock.lock();
            defer self.lock.release();

            if (self.rcursor == self.wcursor) {
                return null;
            }
            const ret = self.data[self.rcursor];
            next_ring_index(&self.rcursor, self.data.len);
            return ret;
        }
        pub fn peek(self: *Self) ?T {
            self.lock.lock();
            defer self.lock.release();

            if (self.rcursor == self.wcursor) {
                return null;
            }
            const ret = self.data[self.rcursor];
            return ret;
        }
        pub fn clear(self: *Self) void {
            self.lock.lock();
            defer self.lock.release();
            self.rcursor = 0;
            self.wcursor = 0;
        }
    };
}
inline fn next_ring_index(i: *usize, len: usize) void {
    i.* = (i.* + 1) & (len - 1);
}
