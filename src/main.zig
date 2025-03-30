const std = @import("std");
const builtin = @import("builtin");
const debug = builtin.mode == std.builtin.Mode.Debug;

// Change to adjust the UNIX socket path
//
// Windows: $USERPROFILE/AppData/LocalLow/$INSTANCE_APPLICATION_NAME/cache/run/instance.lock
// Linux: $HOME/.cache/$INSTANCE_APPLICATION_NAME/cache/run/instance.lock
const INSTANCE_APPLICATION_NAME = "app-name";

// Change to adjust the instance executable path
//
// $LAUNCHER_EXE_DIR/$INSTANCE_EXECUTABLE_NAME
const INSTANCE_EXECUTABLE_NAME = if (builtin.target.os.tag == .windows) "instance-executable.exe" else "instance-executable";

const HELLO_MESSAGE = "{\"msg\":\"HELLO\"}";
const READY_MESSAGE = "{\"msg\":\"READY\"}";
const OK_MESSAGE = "{\"msg\":\"OK\"}";

const ArgsMessage = struct { args: [][]u8 };

const TERMINATOR_CHAR: u8 = '\u{000A}';
const TERMINATOR_STRING: []const u8 = "\u{000A}";
const JSON_MAX_SIZE: usize = 65536;

const LauncherError = error{
    UnknownReadyMessage,
    UnknownOkMessage,
};

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var path_info: EnvInfo = EnvInfo.init(allocator) catch unreachable;
    defer path_info.deinit();
    path_info.debugPrint() catch unreachable;

    if (launcher(allocator, path_info.socket_path, path_info.instance_exe_path, path_info.args_list.items)) {
        std.process.exit(0);
    } else |err| {
        std.debug.print("{s}, aborting!", .{@errorName(err)});
        std.process.exit(1);
    }
}

const EnvInfo = struct {
    allocator: std.mem.Allocator,
    socket_path: []u8,
    instance_exe_path: []u8,
    args_list: std.ArrayList([]u8),

    pub fn init(allocator: std.mem.Allocator) !EnvInfo {
        const self_exe_path = try std.fs.selfExePathAlloc(allocator);
        defer allocator.free(self_exe_path);
        const self_exe_dir = std.fs.path.dirname(self_exe_path).?;
        // Locate UNIX socket
        const socket_path = try locateUnixSocket(allocator);
        // Locate instance executable
        const instance_exe_path = try std.fs.path.join(allocator, &[_][]const u8{ self_exe_dir, INSTANCE_EXECUTABLE_NAME });
        // Gather arguments
        var args_list = std.ArrayList([]u8).init(allocator);
        var args_iterator = try std.process.argsWithAllocator(allocator);
        defer args_iterator.deinit();
        _ = args_iterator.next(); // Skip executable
        while (args_iterator.next()) |arg| {
            const copy = try std.fmt.allocPrint(allocator, "{s}", .{arg});
            try args_list.append(copy);
        }
        return .{ .allocator = allocator, .socket_path = socket_path, .instance_exe_path = instance_exe_path, .args_list = args_list };
    }

    pub fn deinit(self: *EnvInfo) void {
        self.allocator.free(self.socket_path);
        self.allocator.free(self.instance_exe_path);
        for (self.args_list.items) |arg| {
            self.allocator.free(arg);
        }
        self.args_list.deinit();
    }

    fn locateUnixSocket(allocator: std.mem.Allocator) ![]u8 {
        if (builtin.target.os.tag == .windows) {
            // $USERPROFILE/AppData/LocalLow/$INSTANCE_APPLICATION_NAME/cache/run/instance.lock
            const user_dir = try std.process.getEnvVarOwned(allocator, "USERPROFILE");
            defer allocator.free(user_dir);
            return try std.fs.path.join(allocator, &[_][]const u8{ user_dir, "AppData/LocalLow", INSTANCE_APPLICATION_NAME, "cache/run/instance.lock" });
        } else {
            // $HOME/.cache/$INSTANCE_APPLICATION_NAME/cache/run/instance.lock
            const user_dir = try std.process.getEnvVarOwned(allocator, "HOME");
            defer allocator.free(user_dir);
            return try std.fs.path.join(allocator, &[_][]const u8{ user_dir, ".cache", INSTANCE_APPLICATION_NAME, "cache/run/instance.lock" });
        }
    }

    pub fn debugPrint(self: *EnvInfo) !void {
        if (debug) {
            const args_string = try std.mem.join(self.allocator, " ", self.args_list.items);
            defer self.allocator.free(args_string);
            std.debug.print("EnvInfo(\n  socket_path = {s},\n  instance_exe_path = {s},\n  args = {s}\n)\n", .{ self.socket_path, self.instance_exe_path, args_string });
        }
    }
};

fn launcher(allocator: std.mem.Allocator, socket_path: []u8, instance_exe_path: []u8, args: [][]u8) !void {
    const connection = std.net.connectUnixSocket(socket_path);
    if (connection) |stream| {
        defer stream.close();
        if (debug) std.debug.print("Connected to server\n", .{});
        try sendArgumentsToRunningInstance(allocator, args, stream);
    } else |err| {
        if (debug) std.debug.print("Can't connect ({s}), starting the instance\n", .{@errorName(err)});
        try runInstanceExecutable(allocator, instance_exe_path, args);
    }
}

fn sendArgumentsToRunningInstance(allocator: std.mem.Allocator, args: [][]u8, stream: std.net.Stream) !void {

    // HELLO
    if (debug) std.debug.print("Sending {s}\n", .{HELLO_MESSAGE});
    _ = try stream.writeAll(HELLO_MESSAGE);
    _ = try stream.writeAll(TERMINATOR_STRING);

    // READY
    if (debug) std.debug.print("Waiting for {s}\n", .{READY_MESSAGE});
    const ready_server = try stream.reader().readUntilDelimiterAlloc(allocator, TERMINATOR_CHAR, JSON_MAX_SIZE);
    defer allocator.free(ready_server);
    if (debug) std.debug.print("Client received {s}\n", .{ready_server});

    if (std.mem.eql(u8, ready_server, READY_MESSAGE)) {

        // ARGUMENTS
        const args_json = try std.json.stringifyAlloc(allocator, ArgsMessage{ .args = args }, .{});
        defer allocator.free(args_json);
        if (debug) std.debug.print("Sending {s}\n", .{args_json});
        _ = try stream.writeAll(args_json);
        _ = try stream.writeAll(TERMINATOR_STRING);

        // OK
        if (debug) std.debug.print("Waiting for {s}\n", .{OK_MESSAGE});
        const ok_server = try stream.reader().readUntilDelimiterAlloc(allocator, TERMINATOR_CHAR, JSON_MAX_SIZE);
        defer allocator.free(ok_server);
        if (std.mem.eql(u8, ok_server, OK_MESSAGE)) {
            if (debug) std.debug.print("Server OK'ed arguments\n", .{});
            return;
        } else {
            return LauncherError.UnknownOkMessage;
        }
    } else {
        return LauncherError.UnknownReadyMessage;
    }
}

fn runInstanceExecutable(allocator: std.mem.Allocator, instance_exe_path: []u8, args: [][]u8) !void {

    // Build ARGV
    var argv_list = std.ArrayList([]u8).init(allocator);
    defer argv_list.deinit();
    try argv_list.append(instance_exe_path);
    try argv_list.appendSlice(args);
    const argv_debug = try std.mem.join(allocator, " ", argv_list.items);
    defer allocator.free(argv_debug);

    // Spawn
    var child = std.process.Child.init(argv_list.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch |err| {
        if (debug) std.debug.print("Unable to spawn! {s}\n", .{argv_debug});
        return err;
    };
    child.waitForSpawn() catch |err| {
        if (debug) std.debug.print("Unable to wait for spawn! {s}\n", .{argv_debug});
        return err;
    };
    if (debug) std.debug.print("Spawned! {s}\n", .{argv_debug});
}

// ============================================================================
//  _____ _____ ____ _____ ____
// |_   _| ____/ ___|_   _/ ___|
//   | | |  _| \___ \ | | \___ \
//   | | | |___ ___) || |  ___) |
//   |_| |_____|____/ |_| |____/
//
// ============================================================================

test "can spawn instance when none running" {
    std.debug.print("\n>> can spawn instance when none running\n", .{});
    const allocator = std.testing.allocator;

    const unix_socket_path = testSocketFilePath(allocator);
    defer allocator.free(unix_socket_path);

    const instance_exe_path = testInstanceExecutablePath(allocator);
    defer allocator.free(instance_exe_path);

    var args = TestArguments.init(allocator);
    defer args.deinit();

    try launcher(allocator, unix_socket_path, instance_exe_path, args.list.items);
}

test "can send arguments to running instance" {
    std.debug.print("\n>> can send arguments to running instance\n", .{});
    const allocator = std.testing.allocator;

    const unix_socket_path = testSocketFilePath(allocator);
    defer allocator.free(unix_socket_path);

    const instance_exe_path = try std.fmt.allocPrint(allocator, "NOPE", .{});
    defer allocator.free(instance_exe_path);

    var args = TestArguments.init(allocator);
    defer args.deinit();

    // Init test server shared mutable state
    var server_state: TestServerState = TestServerState.init(allocator);
    defer server_state.deinit();

    // Start Recording Server in separate Thread
    server_state.wait_group.start();
    const server_thread = try std.Thread.spawn(.{ .allocator = allocator }, startTestServer, .{ allocator, unix_socket_path, &server_state });
    defer server_thread.detach();
    server_state.wait_group.wait();

    // Test Client
    try launcher(allocator, unix_socket_path, instance_exe_path, args.list.items);

    // Expect server received messages
    std.debug.print("Test server received {x} message(s)\n", .{server_state.received_messages.items.len});
    try std.testing.expect(server_state.received_messages.items.len == 2);
    const args_json = try std.json.stringifyAlloc(allocator, ArgsMessage{ .args = args.list.items }, .{});
    defer allocator.free(args_json);
    try std.testing.expect(std.mem.eql(u8, server_state.received_messages.items[1], args_json));
}

test "fails with a qualified error when server replies wrong HELLO" {
    std.debug.print("\n>> fails with a qualified error when server replies wrong HELLO\n", .{});
    const allocator = std.testing.allocator;

    const unix_socket_path = testSocketFilePath(allocator);
    defer allocator.free(unix_socket_path);

    const instance_exe_path = try std.fmt.allocPrint(allocator, "NOPE", .{});
    defer allocator.free(instance_exe_path);

    var args = TestArguments.init(allocator);
    defer args.deinit();

    // Init test server shared mutable state
    const wrong_ready = std.fmt.allocPrint(allocator, "WRONG", .{}) catch unreachable;
    const wrong_ok = std.fmt.allocPrint(allocator, "WRONG", .{}) catch unreachable;
    var server_state: TestServerState = TestServerState.initWithMessages(allocator, wrong_ready, wrong_ok);
    defer server_state.deinit();

    // Start Recording Server in separate Thread
    server_state.wait_group.start();
    const server_thread = try std.Thread.spawn(.{ .allocator = allocator }, startTestServer, .{ allocator, unix_socket_path, &server_state });
    defer server_thread.detach();
    server_state.wait_group.wait();

    // Test Client
    const result = launcher(allocator, unix_socket_path, instance_exe_path, args.list.items);
    try std.testing.expect(result == LauncherError.UnknownReadyMessage);
}

test "fails with a qualified error when server replies wrong OK" {
    std.debug.print("\n>> fails with a qualified error when server replies wrong OK\n", .{});
    const allocator = std.testing.allocator;

    const unix_socket_path = testSocketFilePath(allocator);
    defer allocator.free(unix_socket_path);

    const instance_exe_path = try std.fmt.allocPrint(allocator, "NOPE", .{});
    defer allocator.free(instance_exe_path);

    var args = TestArguments.init(allocator);
    defer args.deinit();

    // Init test server shared mutable state
    const good_ready = std.fmt.allocPrint(allocator, "{s}", .{READY_MESSAGE}) catch unreachable;
    const wrong_ok = std.fmt.allocPrint(allocator, "WRONG", .{}) catch unreachable;
    var server_state: TestServerState = TestServerState.initWithMessages(allocator, good_ready, wrong_ok);
    defer server_state.deinit();

    // Start Recording Server in separate Thread
    server_state.wait_group.start();
    const server_thread = try std.Thread.spawn(.{ .allocator = allocator }, startTestServer, .{ allocator, unix_socket_path, &server_state });
    defer server_thread.detach();
    server_state.wait_group.wait();

    // Test Client
    const result = launcher(allocator, unix_socket_path, instance_exe_path, args.list.items);
    try std.testing.expect(result == LauncherError.UnknownOkMessage);
}

// $CWD/zig-out/test/{random}
fn testSocketFilePath(allocator: std.mem.Allocator) []u8 {
    const base_dir_path = testBaseDirPath(allocator);
    defer allocator.free(base_dir_path);
    const number = std.crypto.random.int(u8);
    // path must be as short as possible to prevent NameTooLong errors
    const name = std.fmt.allocPrint(allocator, "af_{d}", .{number}) catch unreachable;
    defer allocator.free(name);
    const unix_socket_path = std.fs.path.resolve(allocator, &.{ base_dir_path, name }) catch unreachable;
    std.fs.deleteFileAbsolute(unix_socket_path) catch |err| switch (err) {
        else => {},
    };
    std.debug.print("Test unix socket path: {s}\n", .{unix_socket_path});
    return unix_socket_path;
}

// $CWD/zig-out/test/{instance_exe_name}
fn testInstanceExecutablePath(allocator: std.mem.Allocator) []u8 {

    // CWD
    const cwd_path = std.fs.cwd().realpathAlloc(allocator, ".") catch unreachable;
    defer allocator.free(cwd_path);

    // $CWD/test/
    const test_dir_path = std.fs.path.resolve(allocator, &.{ cwd_path, "test" }) catch unreachable;
    defer allocator.free(test_dir_path);

    // $CWD/test/{exe_name}
    const exe_name = if (builtin.target.os.tag == .windows) "test_executable.bat" else "test_executable.sh";
    const test_exe_path = std.fs.path.resolve(allocator, &.{ test_dir_path, exe_name }) catch unreachable;

    return test_exe_path;
}

fn testBaseDirPath(allocator: std.mem.Allocator) []u8 {

    // CWD
    const cwd_path = std.fs.cwd().realpathAlloc(allocator, ".") catch unreachable;
    defer allocator.free(cwd_path);

    // $CWD/zig-out/
    const zig_out_dir_path = std.fs.path.resolve(allocator, &.{ cwd_path, "zig-out" }) catch unreachable;
    defer allocator.free(zig_out_dir_path);
    std.fs.makeDirAbsolute(zig_out_dir_path) catch |err| switch (err) {
        else => {},
    };

    // $CWD/zig-out/test/
    const test_dir_path = std.fs.path.resolve(allocator, &.{ zig_out_dir_path, "test" }) catch unreachable;
    std.fs.makeDirAbsolute(test_dir_path) catch |err| switch (err) {
        else => {},
    };

    return test_dir_path;
}

const TestArguments = struct {
    list: std.ArrayList([]u8),
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) TestArguments {
        var args_list = std.ArrayList([]u8).init(allocator);
        args_list.append(std.fmt.allocPrint(allocator, "foo", .{}) catch unreachable) catch unreachable;
        args_list.append(std.fmt.allocPrint(allocator, "bar", .{}) catch unreachable) catch unreachable;
        args_list.append(std.fmt.allocPrint(allocator, "baz", .{}) catch unreachable) catch unreachable;
        return .{ .list = args_list, .allocator = allocator };
    }
    pub fn deinit(self: *TestArguments) void {
        for (self.list.items) |arg| {
            self.allocator.free(arg);
        }
        self.list.deinit();
    }
};

const TestServerState = struct {
    wait_group: std.Thread.WaitGroup,
    received_messages: std.ArrayList([]const u8),
    ready_message: []u8,
    ok_message: []u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TestServerState {
        const ready_message = std.fmt.allocPrint(allocator, "{s}", .{READY_MESSAGE}) catch unreachable;
        const ok_message = std.fmt.allocPrint(allocator, "{s}", .{OK_MESSAGE}) catch unreachable;
        return initWithMessages(allocator, ready_message, ok_message);
    }

    pub fn initWithMessages(allocator: std.mem.Allocator, ready_message: []u8, ok_message: []u8) TestServerState {
        var wg: std.Thread.WaitGroup = undefined;
        wg.reset();
        const list = std.ArrayList([]const u8).init(allocator);
        return .{ .wait_group = wg, .received_messages = list, .ready_message = ready_message, .ok_message = ok_message, .allocator = allocator };
    }

    pub fn deinit(self: *TestServerState) void {
        for (self.received_messages.items) |received_message| {
            self.allocator.free(received_message);
        }
        self.received_messages.deinit();
        self.allocator.free(self.ready_message);
        self.allocator.free(self.ok_message);
    }

    pub fn appendMessage(self: *TestServerState, message: []const u8) void {
        self.received_messages.append(message) catch unreachable;
    }
};

fn startTestServer(allocator: std.mem.Allocator, unix_socket_path: []u8, server_state: *TestServerState) void {
    std.debug.print("Starting test server at {s}\n", .{unix_socket_path});

    // Bind server
    const address = std.net.Address.initUnix(unix_socket_path) catch unreachable;
    var server = address.listen(std.net.Address.ListenOptions{}) catch unreachable;
    defer server.deinit();

    // Server is listening
    std.debug.print("Test server accepting incoming connections\n", .{});
    server_state.wait_group.finish();

    // Wait for client
    const connection = server.accept() catch unreachable;

    // Server receives HELLO
    if (connection.stream.reader().readUntilDelimiterAlloc(allocator, TERMINATOR_CHAR, JSON_MAX_SIZE)) |hello_message| {
        std.debug.print("Server received: {s}\n", .{hello_message});
        server_state.appendMessage(hello_message);

        if (std.mem.eql(u8, hello_message, HELLO_MESSAGE)) {

            // Server sends READY
            _ = connection.stream.writeAll(server_state.ready_message) catch unreachable;
            _ = connection.stream.writeAll(TERMINATOR_STRING) catch unreachable;
            std.debug.print("Server sent: {s}\n", .{server_state.ready_message});

            // Server receives ARGUMENTS
            if (connection.stream.reader().readUntilDelimiterAlloc(allocator, TERMINATOR_CHAR, JSON_MAX_SIZE)) |args_message| {
                std.debug.print("Server received: {s}\n", .{args_message});
                server_state.appendMessage(args_message);

                // Server sends OK
                _ = connection.stream.writeAll(server_state.ok_message) catch unreachable;
                _ = connection.stream.writeAll(TERMINATOR_STRING) catch unreachable;
                std.debug.print("Server sent: {s}\n", .{server_state.ok_message});
            } else |err| {
                std.debug.print("Server failed to read ARGUMENTS: {s}", .{@errorName(err)});
            }
        } else {
            std.debug.print("Server expected HELLO, received garbage", .{});
        }
    } else |err| {
        std.debug.print("Server failed to read HELLO: {s}", .{@errorName(err)});
    }
}
