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

pub const free_ring_queue = if (toolbox.THIS_PLATFORM == .MacOS)
    free_magic_ring_queue
else
    free_not_magic_ring_queue;

pub fn make_not_magic_ring_queue(comptime T: type, at_least_n: usize, arena: *toolbox.Arena) NotMagicRingQueue(T) {
    const data = arena.push_slice(T, at_least_n);
    const result = NotMagicRingQueue(T){ .data = data };
    return result;
}

pub fn free_not_magic_ring_queue(q: anytype) void {
    //TODO: do nothing
    _ = q;
}

pub fn make_magic_ring_queue(comptime T: type, at_least_n: usize, _: *toolbox.Arena) MagicRingQueue(T) {
    const byte_buffer = make_magic_ring_byte_buffer(at_least_n * @sizeOf(T), @alignOf(T));
    const data = @as([*]T, @ptrCast(byte_buffer.ptr))[0 .. byte_buffer.len / @sizeOf(T)];
    const result = MagicRingQueue(T){ .data = data };
    return result;
}

pub fn free_magic_ring_queue(q: anytype) void {
    const unit_size = @sizeOf(toolbox.ChildType(@TypeOf(q.data)));
    const data = @as([*]u8, @ptrCast(q.data.ptr))[0 .. unit_size * q.data.len];
    free_magic_ring_byte_buffer(data);
}

pub fn make_magic_ring_byte_buffer(desired_size: usize, comptime alignment: usize) []align(alignment) u8 {
    const page_size: usize = @intCast(c.getpagesize());
    const num_pages = (desired_size / page_size) + @as(usize, if (desired_size % page_size != 0) 1 else 0);
    const n = num_pages * page_size;

    var result_address: u64 = 0;

    var kern_error: c.kern_return_t = 0;
    const self = c.mach_task_self();
    kern_error = c.mach_vm_allocate(
        self,
        &result_address,
        n * 2,
        c.VM_FLAGS_ANYWHERE,
    );
    toolbox.expect(
        kern_error == c.KERN_SUCCESS,
        "Initial allocation for magic ring buffer memory failed! Error: {}",
        .{kern_error},
    );

    var protection: c.vm_prot_t = c.VM_PROT_READ | c.VM_PROT_WRITE;
    var magic_ring_buffer_address_start = result_address + n;

    //TODO: can control alignment this way. Set low bits will be 0 in the resulting address
    const page_mask = alignment - 1;
    const flags = c.VM_FLAGS_FIXED | c.VM_FLAGS_OVERWRITE;
    kern_error = c.mach_vm_remap(
        self,
        &magic_ring_buffer_address_start,
        n,
        page_mask,
        flags,
        self,
        result_address,
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
    const result = @as([*]align(alignment) u8, @ptrFromInt(result_address))[0 .. n * 2];
    return result;
}

pub fn free_magic_ring_byte_buffer(magic_ring_buffer: []u8) void {
    const self = c.mach_task_self();
    const addr = @intFromPtr(magic_ring_buffer.ptr);
    const kern_error = c.mach_vm_deallocate(
        self,
        addr,
        magic_ring_buffer.len,
    );
    toolbox.expect(
        kern_error == c.KERN_SUCCESS,
        "Freeing magic ring buffer failed! Error code: {}",
        .{kern_error},
    );
}

pub fn MagicRingQueue(T: type) type {
    return struct {
        data: []T = toolbox.z([]T),
        rcursor: usize = 0,
        wcursor: usize = 0,
        _len: usize = 0,

        const Self = @This();

        pub fn enqueue(self: *Self, in: []const T) void {
            if (self.cap() - self._len < in.len) {
                toolbox.panic(
                    "Queue is full. Capacity: {}. Tried to enqueue: {}",
                    .{ self.cap(), in.len },
                );
            }
            const buffer = self.enqueue_buffer(in.len);
            @memcpy(buffer, in);
            self.update_enqueued(in.len);
        }
        pub fn dequeue(self: *Self, out: []T) []T {
            const result = self.peek(out);
            self.update_dequeued(result.len);
            return result;
        }
        pub fn peek(self: *Self, out: []T) []T {
            const n = @min(out.len, self._len);
            const result = out[0..n];
            const peek_buffer = self.dequeue_buffer(n);
            @memcpy(result, peek_buffer);
            return result;
        }
        pub inline fn enqueue_buffer(self: *Self, n: usize) []T {
            const result = self.data[self.wcursor .. self.wcursor + n];
            return result;
        }
        pub inline fn dequeue_buffer(self: *Self, n: usize) []T {
            const result = self.data[self.rcursor .. self.rcursor + n];
            return result;
        }
        pub fn update_enqueued(self: *Self, n: usize) void {
            self.advance_cursor(&self.wcursor, n);
            self._len += n;
        }
        pub fn update_dequeued(self: *Self, n: usize) void {
            self.advance_cursor(&self.rcursor, n);
            self._len -= n;
        }
        pub inline fn len(self: Self) usize {
            return self._len;
        }
        pub inline fn cap(self: Self) usize {
            const result = self.data.len / 2;
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
            i.* = (i.* + n) & (self.cap() - 1);
        }
    };
}
pub fn NotMagicRingQueue(T: type) type {
    return struct {
        data: []T = toolbox.z([]T),
        rcursor: usize = 0,
        wcursor: usize = 0,
        _len: usize = 0,

        const Self = @This();

        pub fn enqueue(self: *Self, in: []const T) void {
            if (self.cap() - self._len < in.len) {
                toolbox.panic(
                    "Queue is full. Capacity: {}. Tried to enqueue: {}",
                    .{ self.cap(), in.len },
                );
            }
            const buffer = self.enqueue_buffer(in.len);
            @memcpy(buffer, in[0..buffer.len]);
            self.update_enqueued(buffer.len);

            if (buffer.len < in.len) {
                const n_left = in.len - buffer.len;
                const buffer2 = self.enqueue_buffer(n_left);
                @memcpy(buffer2, in[buffer.len..]);
                self.update_enqueued(buffer2.len);
            }
        }
        pub fn dequeue(self: *Self, out: []T) []T {
            const result = self.peek(out);
            self.update_dequeued(result.len);
            return result;
        }
        pub fn peek(self: *Self, out: []T) []T {
            const n = @min(out.len, self._len);
            const result = out[0..n];
            const buffer = self.dequeue_buffer(n);
            @memcpy(result[0..buffer.len], buffer);

            if (buffer.len < n) {
                const n_left = n - buffer.len;
                const buffer2 = self.data[0..n_left];
                @memcpy(result[buffer.len..], buffer2);
            }
            return result;
        }
        pub inline fn enqueue_buffer(self: *Self, at_most_n: usize) []T {
            const n = @min(self.cap() - self.wcursor, at_most_n);
            const result = self.data[self.wcursor .. self.wcursor + n];
            return result;
        }
        pub inline fn dequeue_buffer(self: *Self, at_most_n: usize) []T {
            const n = @min(self.cap() - self.rcursor, at_most_n);
            const result = self.data[self.rcursor .. self.rcursor + n];
            return result;
        }
        pub fn update_enqueued(self: *Self, n: usize) void {
            self.advance_cursor(&self.wcursor, n);
            self._len += n;
        }
        pub fn update_dequeued(self: *Self, n: usize) void {
            self.advance_cursor(&self.rcursor, n);
            self._len -= n;
        }
        pub inline fn len(self: Self) usize {
            return self._len;
        }
        pub inline fn cap(self: Self) usize {
            const result = self.data.len;
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
            i.* = (i.* + n) & (self.cap() - 1);
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
