const std = @import("std");

const HELLO_MESSAGE = "HELLO\n";
const READY_MESSAGE = "READY\n";
const OK_MESSAGE = "OK\n";

pub fn main() !void {
    var bw = std.io.bufferedWriter(std.io.getStdOut().writer());
    const stdout = bw.writer();

    const allocator = std.heap.page_allocator;

    const stream = try std.net.connectUnixSocket("/tmp/zig-unix-socket");
    defer stream.close();

    try stdout.print("Connected to server\n", .{});
    try bw.flush();

    _ = try stream.write(HELLO_MESSAGE);

    try stdout.print("Sent HELLO, waiting for READY...\n", .{});
    try bw.flush();

    var buffer: [4096]u8 = undefined;
    _ = std.heap.FixedBufferAllocator.init(&buffer);
    _ = try stream.readAtLeast(&buffer, READY_MESSAGE.len);

    if (std.mem.startsWith(u8, &buffer, READY_MESSAGE)) {
        try stdout.print("GOT SERVER READY!\n", .{});
        try bw.flush();

        var message: []u8 = "";
        message = try std.mem.concat(allocator, u8, &[_][]const u8{ message, "OPEN" });

        var args_iterator = try std.process.argsWithAllocator(allocator);
        defer args_iterator.deinit();
        _ = args_iterator.next(); // Skip executable

        while (args_iterator.next()) |arg| {
            message = try std.mem.concat(allocator, u8, &[_][]const u8{ message, " ", arg });
        }
        message = try std.mem.concat(allocator, u8, &[_][]const u8{ message, "\n" });

        try stdout.print("Sending arguments: {s}\n", .{message});
        try bw.flush();

        try stream.writeAll(message);

        _ = try stream.readAtLeast(&buffer, OK_MESSAGE.len);

        if (std.mem.startsWith(u8, &buffer, OK_MESSAGE)) {
            try stdout.print("Server OK'ed arguments\n", .{});
            try bw.flush();
            std.process.exit(0);
        } else {
            std.debug.print("SERVER REPLIED WITH UNKNOWN OK MESSAGE\n", .{});
            std.process.exit(1);
        }
    } else {
        std.debug.print("SERVER REPLIED WITH UNKNOWN READY MESSAGE\n", .{});
        std.process.exit(1);
    }
}

// TODO write tests mocking the unix_socket server for fast turnaround
test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // Try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
