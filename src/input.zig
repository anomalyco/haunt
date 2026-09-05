const std = @import("std");

pub const Mouse = struct {
    kind: enum { down, up, move },
    button: u8,
    x: u32,
    y: u32,
};
pub const Event = union(enum) { key: u32, mouse: Mouse, focus: bool };

/// Incremental parser: terminal replies and fragmented escape sequences never become keystrokes.
pub const Parser = struct {
    buffer: [8192]u8 = undefined,
    length: usize = 0,

    pub fn feed(self: *Parser, bytes: []const u8) void {
        if (bytes.len > self.buffer.len - self.length) self.length = 0;
        const count = @min(bytes.len, self.buffer.len - self.length);
        @memcpy(self.buffer[self.length..][0..count], bytes[0..count]);
        self.length += count;
    }

    fn consume(self: *Parser, count: usize) void {
        std.mem.copyForwards(u8, self.buffer[0 .. self.length - count], self.buffer[count..self.length]);
        self.length -= count;
    }

    pub fn escapePending(self: Parser) bool {
        return self.length == 1 and self.buffer[0] == 27;
    }

    pub fn flushEscape(self: *Parser) ?Event {
        if (!self.escapePending()) return null;
        self.consume(1);
        return .{ .key = 27 };
    }

    pub fn next(self: *Parser) ?Event {
        while (self.length > 0) {
            if (self.buffer[0] != 27) {
                const length = std.unicode.utf8ByteSequenceLength(self.buffer[0]) catch {
                    self.consume(1);
                    continue;
                };
                if (self.length < length) return null;
                const code = std.unicode.utf8Decode(self.buffer[0..length]) catch {
                    self.consume(length);
                    continue;
                };
                self.consume(length);
                return .{ .key = code };
            }
            if (self.length < 2) return null;
            if (self.buffer[1] == '[') {
                var end: usize = 2;
                while (end < self.length and (self.buffer[end] < 0x40 or self.buffer[end] > 0x7e)) : (end += 1) {}
                if (end == self.length) return null;
                const final = self.buffer[end];
                if (end == 2 and (final == 'I' or final == 'O')) {
                    self.consume(end + 1);
                    return .{ .focus = final == 'I' };
                }
                if (end > 3 and self.buffer[2] == '<' and (final == 'M' or final == 'm')) {
                    const mouse = parseMouse(self.buffer[3..end], final == 'm');
                    self.consume(end + 1);
                    if (mouse) |value| return .{ .mouse = value };
                } else {
                    self.consume(end + 1);
                }
                continue;
            }
            if (self.buffer[1] == ']' or self.buffer[1] == 'P' or self.buffer[1] == '_') {
                var end: usize = 2;
                var complete: usize = 0;
                while (end < self.length) : (end += 1) {
                    if (self.buffer[end] == 7) {
                        complete = end + 1;
                        break;
                    }
                    if (self.buffer[end] == 27 and end + 1 < self.length and self.buffer[end + 1] == '\\') {
                        complete = end + 2;
                        break;
                    }
                }
                if (complete == 0) return null;
                self.consume(complete);
                continue;
            }
            // Unknown two-byte escape (including Alt+key) is consumed as a unit.
            self.consume(2);
        }
        return null;
    }
};

fn parseMouse(payload: []const u8, release: bool) ?Mouse {
    var parts = std.mem.splitScalar(u8, payload, ';');
    const button = std.fmt.parseInt(u32, parts.next() orelse return null, 10) catch return null;
    const x = std.fmt.parseInt(u32, parts.next() orelse return null, 10) catch return null;
    const y = std.fmt.parseInt(u32, parts.next() orelse return null, 10) catch return null;
    if (parts.next() != null or x == 0 or y == 0 or x > 65535 or y > 65535 or button >= 64) return null;
    return .{
        .x = x - 1,
        .y = y - 1,
        .button = @intCast(button & 3),
        .kind = if (release) .up else if (button & 32 != 0) .move else .down,
    };
}
