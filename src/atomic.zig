const std = @import("std");
pub const TicketLock = struct {
    serving: u64 = 0,
    taken: u64 = 0,

    pub fn lock(self: *TicketLock) void {
        const ticket = @atomicRmw(u64, &self.taken, .Add, 1, .seq_cst);
        while (true) {
            //TODO os_sync_wait_on_address
            if (@cmpxchgWeak(
                u64,
                &self.serving,
                ticket,
                ticket,
                .acq_rel,
                .monotonic,
            ) == null) {
                return;
            } else {
                std.atomic.spinLoopHint();
            }
        }
    }

    pub fn release(self: *TicketLock) void {
        _ = @atomicRmw(u64, &self.serving, .Add, 1, .acq_rel);
    }
};
pub const SpinLock = struct {
    locked: bool = false,

    pub fn lock(self: *SpinLock) void {
        while (true) {
            //TODO os_sync_wait_on_address
            if (@cmpxchgWeak(
                bool,
                &self.locked,
                false,
                true,
                .acq_rel,
                .monotonic,
            ) == null) {
                return;
            } else {
                std.atomic.spinLoopHint();
            }
        }
    }
    pub fn release(self: *SpinLock) void {
        @atomicStore(bool, &self.locked, false, .release);
    }
};
