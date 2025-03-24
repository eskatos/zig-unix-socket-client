const std = @import("std");

const AF_SOCKET_NAME = "instance.lock";
const INSTANCE_EXECUTABLE_NAME = "target-executable"; // TODO Windows

const HELLO_MESSAGE = "HELLO\n";
const READY_MESSAGE = "READY\n";
const OK_MESSAGE = "OK\n";

const MESSAGE_PAYLOAD = struct { message: []const u8 };
const ARGUMENTS_PAYLOAD = struct { arguments: [][]const u8 };

pub fn main() !void {
    var bw = std.io.bufferedWriter(std.io.getStdOut().writer());
    const stdout = bw.writer();

    const allocator = std.heap.page_allocator;

    // Locate self exe
    const self_exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(self_exe_path);
    const opt_self_exe_dir = std.fs.path.dirname(self_exe_path);
    if (opt_self_exe_dir) |self_exe_dir| {
        // Locate UNIX socket
        const socket_path = try std.fs.path.join(allocator, &[_][]const u8{ self_exe_dir, "..", "..", AF_SOCKET_NAME });
        defer allocator.free(socket_path);
        std.debug.print("UNIX socket at {s}.\n", .{socket_path});

        // Open UNIX socket
        const stream = std.net.connectUnixSocket(socket_path) catch |err| switch (err) {
            else => {
                // FAILED, start instance
                std.debug.print("Can't connect to UNIX socket, starting the instance\n", .{});

                // Locate instance executable
                const instance_exe_path = try std.fs.path.join(allocator, &[_][]const u8{ self_exe_dir, "..", "..", INSTANCE_EXECUTABLE_NAME });
                defer allocator.free(instance_exe_path);
                std.debug.print("Instance executable at {s}.\n", .{instance_exe_path});

                // Build instance ARGV
                const args = try std.process.argsAlloc(allocator);
                defer allocator.free(args);
                var argv_list = std.ArrayList([]u8).init(allocator);
                defer argv_list.deinit();
                try argv_list.append(instance_exe_path);
                try argv_list.appendSlice(args[1..]);

                // Spawn instance
                var child = std.process.Child.init(argv_list.items, allocator);
                child.stdin_behavior = .Ignore;
                child.stdout_behavior = .Ignore;
                child.stderr_behavior = .Ignore;
                try child.spawn();
                try child.waitForSpawn();
                std.debug.print("Instance spawned!\n", .{});

                // Exit
                std.process.exit(0);
            },
        };
        defer stream.close();

        // UNIX socket SUCCESS, we are the client
        try stdout.print("Connected to server\n", .{});
        try bw.flush();

        // HELLO / READY
        const hello_message = MESSAGE_PAYLOAD{ .message = "HELLO" };
        var buf: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        var string = std.ArrayList(u8).init(fba.allocator());
        try std.json.stringify(hello_message, .{}, string.writer());
        try stdout.print("{s}", .{string.items});

        _ = try stream.write(string.items);
        _ = try stream.write("\n");

        try stdout.print("Sent HELLO, waiting for READY...\n", .{});
        try bw.flush();

        var buffer: [4096]u8 = undefined;
        _ = std.heap.FixedBufferAllocator.init(&buffer);
        _ = try stream.readAtLeast(&buffer, READY_MESSAGE.len);

        if (std.mem.startsWith(u8, &buffer, READY_MESSAGE)) {
            try stdout.print("GOT SERVER READY!\n", .{});
            try bw.flush();

            // MESSAGE / OK
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
    } else {
        std.debug.print("Unable to locate self executable", .{});
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
