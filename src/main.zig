const std = @import("std");
const builtin = @import("builtin");
const debug = builtin.mode == std.builtin.Mode.Debug;

// Launcher for single instance application
//
// Uses a UNIX socket as a lock and communication channel for the single instance.
//
// If the UNIX socket is not connected to a running instance of the application,
// then this program will launch the application, passing arguments.
//
// If the UNIX socket is connected to a running instance of the application,
// then this program will send its arguments to the application via the UNIX socket.
//
// Data is transferred on the UNIX socket using EOL terminated JSON messages.

// TODO review error handling
// TODO review socket and instance paths

const HelloMessage = struct { msg: []const u8 = "HELLO" };
const ReadyMessage = struct { msg: []const u8 = "READY" };
const ArgsMessage = struct { args: [][]u8 };
const OkMessage = struct { msg: []const u8 = "OK" };

const TERMINATOR_CHAR: u8 = '\u{000A}';
const TERMINATOR_STRING: []const u8 = "\u{000A}";
const JSON_MAX_SIZE: usize = 65536;

const AF_SOCKET_NAME = "instance.lock";
const INSTANCE_EXECUTABLE_NAME = if (builtin.target.os.tag == .windows) "target-executable.exe" else "target-executable";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var path_info: EnvInfo = try EnvInfo.init(allocator);
    defer path_info.deinit();
    try path_info.debugPrint();

    try launcher(allocator, path_info.socket_path, path_info.instance_exe_path, path_info.args);
}

fn launcher(allocator: std.mem.Allocator, socket_path: []u8, instance_exe_path: []u8, args: [][]u8) !void {

    // Try connecting to the instance
    const stream = std.net.connectUnixSocket(socket_path) catch |err| switch (err) {
        else => {
            // Start instance
            if (debug) std.debug.print("Can't connect to UNIX socket, starting the instance\n", .{});
            try runInstanceExecutable(allocator, instance_exe_path, args);
            std.process.exit(0);
        },
    };
    defer stream.close();

    // We are the client
    if (debug) std.debug.print("Connected to server\n", .{});
    try sendArgumentsToRunningInstance(allocator, args, stream);
}

const EnvInfo = struct {
    allocator: std.mem.Allocator,
    socket_path: []u8,
    instance_exe_path: []u8,
    args: [][]u8,

    pub fn init(allocator: std.mem.Allocator) !EnvInfo {
        const self_exe_path = try std.fs.selfExePathAlloc(allocator);
        defer allocator.free(self_exe_path);
        const self_exe_dir = std.fs.path.dirname(self_exe_path).?;
        // Locate UNIX socket
        const socket_path = try std.fs.path.join(allocator, &[_][]const u8{ self_exe_dir, "..", "..", AF_SOCKET_NAME });
        // Locate instance executable
        const instance_exe_path = try std.fs.path.join(allocator, &[_][]const u8{ self_exe_dir, "..", "..", INSTANCE_EXECUTABLE_NAME });
        // Gather arguments
        var args_list = std.ArrayList([]u8).init(allocator);
        var args_iterator = try std.process.argsWithAllocator(allocator);
        defer args_iterator.deinit();
        _ = args_iterator.next(); // Skip executable
        while (args_iterator.next()) |arg| {
            const copy = try std.fmt.allocPrint(allocator, "{s}", .{arg});
            try args_list.append(copy);
        }
        return .{ .allocator = allocator, .socket_path = socket_path, .instance_exe_path = instance_exe_path, .args = args_list.items };
    }

    pub fn deinit(self: *EnvInfo) void {
        self.allocator.free(self.socket_path);
        self.allocator.free(self.instance_exe_path);
        self.allocator.free(self.args);
    }

    pub fn debugPrint(self: *EnvInfo) !void {
        if (debug) {
            const args_string = try std.mem.join(self.allocator, " ", self.args);
            std.debug.print("EnvInfo(\n  socket_path = {s},\n  instance_exe_path = {s},\n  args = {s}\n)\n", .{ self.socket_path, self.instance_exe_path, args_string });
        }
    }
};

fn runInstanceExecutable(allocator: std.mem.Allocator, instance_exe_path: []u8, args: [][]u8) !void {

    // Build ARGV
    var argv_list = std.ArrayList([]u8).init(allocator);
    defer argv_list.deinit();
    try argv_list.append(instance_exe_path);
    try argv_list.appendSlice(args);

    // Spawn
    var child = std.process.Child.init(argv_list.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    try child.waitForSpawn();
    const argv_debug = try std.mem.join(allocator, " ", argv_list.items);
    defer allocator.free(argv_debug);
    if (debug) std.debug.print("Spawned! {s}\n", .{argv_debug});
}

fn sendArgumentsToRunningInstance(allocator: std.mem.Allocator, args: [][]u8, stream: std.net.Stream) !void {

    // HELLO
    const hello_json = try std.json.stringifyAlloc(allocator, HelloMessage{}, .{});
    defer allocator.free(hello_json);
    if (debug) std.debug.print("Sending {s}\n", .{hello_json});

    _ = try stream.writeAll(hello_json);
    _ = try stream.writeAll(TERMINATOR_STRING);

    // READY
    const ready_json = try std.json.stringifyAlloc(allocator, ReadyMessage{}, .{});
    defer allocator.free(ready_json);
    if (debug) std.debug.print("Waiting for {s}\n", .{ready_json});

    const ready_server = try stream.reader().readUntilDelimiterAlloc(allocator, TERMINATOR_CHAR, JSON_MAX_SIZE);
    defer allocator.free(ready_server);

    if (std.mem.eql(u8, ready_server, ready_json)) {
        if (debug) std.debug.print("SERVER READY!\n", .{});

        // ARGUMENTS
        const args_json = try std.json.stringifyAlloc(allocator, ArgsMessage{ .args = args }, .{});
        defer allocator.free(args_json);
        if (debug) std.debug.print("Sending {s}\n", .{args_json});
        _ = try stream.writeAll(args_json);
        _ = try stream.writeAll(TERMINATOR_STRING);

        // OK
        const ok_json = try std.json.stringifyAlloc(allocator, OkMessage{}, .{});
        defer allocator.free(ok_json);
        if (debug) std.debug.print("Waiting for {s}\n", .{ok_json});
        const ok_server = try stream.reader().readUntilDelimiterAlloc(allocator, TERMINATOR_CHAR, JSON_MAX_SIZE);
        defer allocator.free(ok_server);
        if (std.mem.eql(u8, ok_server, ok_json)) {
            if (debug) std.debug.print("Server OK'ed arguments\n", .{});
            std.process.exit(0);
        } else {
            std.debug.print("ERROR Server replied with unknown OK message, aborting\n", .{});
            std.process.exit(1);
        }
    } else {
        std.debug.print("ERROR Server replied with unknown READY message, aborting\n", .{});
        std.process.exit(1);
    }
}

test "can spawn instance when none running" {
    const allocator = std.testing.allocator;

    const unix_socket_path = try testSocketFilePath(allocator);
    const instance_exe_path = try testInstanceExecutablePath(allocator);
    const args = try testArguments(allocator);
    defer allocator.free(unix_socket_path);
    defer allocator.free(instance_exe_path);
    defer allocator.free(args);

    try launcher(allocator, unix_socket_path, instance_exe_path, args);
}

test "can send arguments to running instance" {
    const allocator = std.testing.allocator;

    const unix_socket_path = try testSocketFilePath(allocator);
    const instance_exe_path = try std.fmt.allocPrint(allocator, "NOPE", .{});
    const args = try testArguments(allocator);
    defer allocator.free(unix_socket_path);
    defer allocator.free(instance_exe_path);
    defer allocator.free(args);

    // Init test server shared mutable state
    var server_state: TestServerState = TestServerState.init(allocator);
    defer server_state.deinit();
    try std.testing.expect(server_state.received_messages.items.len == 0);

    // Start Recording Server in separate Thread
    server_state.wait_group.start();
    const server_thread = try std.Thread.spawn(.{ .allocator = allocator }, startTestServer, .{ allocator, unix_socket_path, &server_state });
    defer server_thread.detach();
    server_state.wait_group.wait();

    // Test Client
    server_state.wait_group.start();
    try launcher(allocator, unix_socket_path, instance_exe_path, args);
    server_state.wait_group.wait();

    // Expect server received messages
    std.debug.print("Test server received {x} message(s)\n", .{server_state.received_messages.items.len});
    try std.testing.expect(server_state.received_messages.items.len == 2);
    const args_json = try std.json.stringifyAlloc(allocator, ArgsMessage{ .args = args }, .{});
    defer allocator.free(args_json);
    try std.testing.expect(std.mem.eql(u8, server_state.received_messages.items[1], args_json));
}

// $CWD/zig-out/test/instance.lock
fn testSocketFilePath(allocator: std.mem.Allocator) ![]u8 {
    const base_dir_path = try testBaseDirPath(allocator);
    defer allocator.free(base_dir_path);
    const unix_socket_path = try std.fs.path.resolve(allocator, &.{ base_dir_path, "instance.lock" });
    std.fs.deleteFileAbsolute(unix_socket_path) catch |err| switch (err) {
        else => {},
    };
    return unix_socket_path;
}

// $CWD/zig-out/test/{instance_exe_name}
fn testInstanceExecutablePath(allocator: std.mem.Allocator) ![]u8 {

    // CWD
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);

    // $CWD/test/
    const test_dir_path = try std.fs.path.resolve(allocator, &.{ cwd_path, "test" });
    defer allocator.free(test_dir_path);

    // $CWD/test/{exe_name}
    const exe_name = if (builtin.target.os.tag == .windows) "test_executable.bat" else "test_executable.sh";
    const test_exe_path = try std.fs.path.resolve(allocator, &.{ test_dir_path, exe_name });

    return test_exe_path;
}

fn testBaseDirPath(allocator: std.mem.Allocator) ![]u8 {

    // CWD
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);

    // $CWD/zig-out/
    const zig_out_dir_path = try std.fs.path.resolve(allocator, &.{ cwd_path, "zig-out" });
    defer allocator.free(zig_out_dir_path);
    std.fs.makeDirAbsolute(zig_out_dir_path) catch |err| switch (err) {
        else => {},
    };

    // $CWD/zig-out/test/
    const test_dir_path = try std.fs.path.resolve(allocator, &.{ zig_out_dir_path, "test" });
    std.fs.makeDirAbsolute(test_dir_path) catch |err| switch (err) {
        else => {},
    };

    return test_dir_path;
}

fn testArguments(allocator: std.mem.Allocator) ![][]u8 {
    // Arguments
    var args_list = std.ArrayList([]u8).init(allocator);
    try args_list.append(try std.fmt.allocPrint(allocator, "foo", .{}));
    try args_list.append(try std.fmt.allocPrint(allocator, "bar", .{}));
    try args_list.append(try std.fmt.allocPrint(allocator, "baz", .{}));
    return args_list.items;
}

const TestServerState = struct {
    wait_group: std.Thread.WaitGroup,
    received_messages: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) TestServerState {
        var wg: std.Thread.WaitGroup = undefined;
        wg.reset();
        const list = std.ArrayList([]const u8).init(allocator);
        return .{ .wait_group = wg, .received_messages = list };
    }

    pub fn deinit(self: *TestServerState) void {
        self.received_messages.deinit();
    }

    pub fn appendMessage(self: *TestServerState, message: []const u8) !void {
        try self.received_messages.append(message);
    }
};

fn startTestServer(allocator: std.mem.Allocator, unix_socket_path: []u8, server_state: *TestServerState) !void {
    std.debug.print("Starting test server at {s}\n", .{unix_socket_path});

    // Bind server
    const address = try std.net.Address.initUnix(unix_socket_path);
    var server = try address.listen(std.net.Address.ListenOptions{});
    defer server.deinit();

    // Server is listening
    std.debug.print("Test server accepting incoming connections\n", .{});
    server_state.wait_group.finish();

    // Wait for client
    const connection = try server.accept();

    // Server receives HELLO
    const hello_message = try connection.stream.reader().readUntilDelimiterAlloc(allocator, TERMINATOR_CHAR, JSON_MAX_SIZE);
    std.debug.print("Server received: {s}\n", .{hello_message});
    try server_state.appendMessage(hello_message);

    const hello_json = try std.json.stringifyAlloc(allocator, HelloMessage{}, .{});
    defer allocator.free(hello_json);

    if (std.mem.eql(u8, hello_message, hello_json)) {
        std.debug.print("Server got {s}", .{hello_message});

        // Server sends READY
        const ready_json = try std.json.stringifyAlloc(allocator, ReadyMessage{}, .{});
        defer allocator.free(ready_json);
        _ = try connection.stream.writeAll(ready_json);
        _ = try connection.stream.writeAll(TERMINATOR_STRING);

        // Server receives ARGUMENTS
        const args_message = try connection.stream.reader().readUntilDelimiterAlloc(allocator, TERMINATOR_CHAR, JSON_MAX_SIZE);
        std.debug.print("Server received: {s}\n", .{args_message});
        try server_state.appendMessage(args_message);

        // Server sends OK
        const ok_json = try std.json.stringifyAlloc(allocator, OkMessage{}, .{});
        defer allocator.free(ok_json);
        _ = try connection.stream.writeAll(ok_json);
        _ = try connection.stream.writeAll(TERMINATOR_STRING);
    } else {
        std.debug.print("Server expected HELLO, received garbage", .{});
    }
    server_state.wait_group.finish();
}
