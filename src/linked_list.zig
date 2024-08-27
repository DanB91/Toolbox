const toolbox = @import("toolbox.zig");

const CT = toolbox.ChildType;

pub fn llnext(cursor: anytype) CT(@TypeOf(cursor)) {
    if (cursor.*) |node| {
        cursor.* = node.next;
        return node;
    }
    return null;
}
pub fn llappend_value(
    list: anytype,
    value: anytype,
    arena: *toolbox.Arena,
    free_list: anytype,
) *@TypeOf(value) {
    const node = llalloc_node(@TypeOf(value), arena, free_list);
    node.* = value;
    llappend(list, node);
    return node;
}
pub fn llappend(
    list: anytype,
    node: anytype,
) void {
    if (list.tail) |t| {
        t.next = node;
    } else {
        list.head = node;
    }
    node.prev = list.tail;
    list.tail = node;
    node.next = null;

    list.len += 1;
}
pub fn llprepend_value(
    list: anytype,
    value: anytype,
    arena: *toolbox.Arena,
    free_list: anytype,
) *@TypeOf(value) {
    const node = llalloc_node(@TypeOf(value), arena, free_list);
    node.* = value;
    llprepend(list, node);
    return node;
}
pub fn llprepend(
    list: anytype,
    node: anytype,
) void {
    if (list.head == null) {
        list.tail = node;
    }
    node.next = list.head;
    list.head = node;
    node.prev = null;

    list.len += 1;
}

pub fn llremove(
    list: anytype,
    node: anytype,
    free_list: anytype,
) void {
    if (list.len == 0) {
        return;
    }
    defer {
        list.len -= 1;
        llfree_node(node, free_list);
    }
    if (node == list.head) {
        list.head = node.next;
        if (list.head) |head| {
            head.prev = null;
        }
        if (node == list.tail) {
            toolbox.assert(list.len == 1, "If head and tail are same, then len should be 1", .{});
            list.tail = node.prev;
            if (list.tail) |tail| {
                tail.next = null;
            }
        }
        return;
    }
    if (node == list.tail) {
        list.tail = node.prev;
        if (list.tail) |tail| {
            tail.next = null;
        }
        return;
    }
    if (node.prev) |prev| {
        prev.next = node.next;
    }
    if (node.next) |next| {
        next.prev = node.prev;
    }
}

pub fn RandomRemovalLinkedList(comptime T: type) type {
    return struct {
        head: ?*T = null,
        tail: ?*T = null,
        len: usize = 0,

        const Self = @This();
        const FreeList = ?*T;
        pub const Iterator = struct {
            cursor: ?*T = null,
            pub inline fn next(self: *Iterator) ?*T {
                return llnext(&self.cursor);
            }
        };

        pub inline fn append(self: *Self, node: *T) void {
            llappend(self, node);
        }
        pub inline fn append_value(self: *Self, value: T, arena: *toolbox.Arena, free_list: *FreeList) *T {
            return llappend_value(self, value, arena, free_list);
        }
        pub inline fn prepend(self: *Self, node: *T) void {
            llprepend(self, node);
        }
        pub inline fn prepend_value(self: *Self, value: T, arena: *toolbox.Arena, free_list: *FreeList) *T {
            return llprepend_value(self, value, arena, free_list);
        }
        pub inline fn remove(self: *Self, node: *T, free_list: ?*FreeList) void {
            llremove(self, node, free_list);
        }
        pub fn clear(self: *Self) void {
            self.* = .{};
        }
        pub fn clear_and_free(self: *Self, free_list: *FreeList) void {
            var it = self.iterator();
            while (it.next()) |node| {
                llfree_node(node, free_list);
            }
        }
        pub fn iterator(self: *const Self) Iterator {
            return .{
                .cursor = self.head,
            };
        }
    };
}

fn llalloc_node(comptime T: type, arena: *toolbox.Arena, free_list: anytype) *T {
    if (free_list.*) |node| {
        free_list.* = node.next;
        return node;
    }
    return arena.push(T);
}
fn llfree_node(node: anytype, free_list: anytype) void {
    if (free_list) |fl| {
        node.next = fl.*;
        fl.* = node;
    }
}
