const std = @import("std");
const builtin = @import("builtin");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) !void {
    const install_step = b.getInstallStep();
    const check_step = b.step("check", "Run all checks");

    // Cross-compiled release
    const release = b.step("release", "Build release executable for all targets");
    for (TARGETS) |t| {
        const exe = b.addExecutable(.{
            .name = "launcher",
            .root_source_file = b.path("src/main.zig"),
            .target = b.resolveTargetQuery(t),
            .optimize = .ReleaseSmall,
        });

        const target_output = b.addInstallArtifact(exe, .{
            .dest_dir = .{
                .override = .{
                    .custom = try t.zigTriple(b.allocator),
                },
            },
        });

        release.dependOn(&target_output.step);
    }

    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // We will also create a module for our other entry point, 'main.zig'.
    const main_module = b.createModule(.{
        // `root_source_file` is the Zig "entry point" of the module. If a module
        // only contains e.g. external object files, you can make this `null`.
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // This creates another `std.Build.Step.Compile`, but this one builds an executable
    // rather than a static library.
    const main_exe = b.addExecutable(.{
        .name = "launcher-debug",
        .root_module = main_module,
    });

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(main_exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const main_run_cmd = b.addRunArtifact(main_exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    main_run_cmd.step.dependOn(install_step);

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        main_run_cmd.addArgs(args);
    }

    // Copy target executable to output dir
    const test_exe_src = if (builtin.target.os.tag == .windows) "test/test_executable.bat" else "test/test_executable.sh";
    const text_exe_dest = if (builtin.target.os.tag == .windows) "instance-executable.exe" else "instance-executable";
    const install_test_executable_step = b.addInstallBinFile(b.path(test_exe_src), text_exe_dest);
    main_run_cmd.step.dependOn(&install_test_executable_step.step);

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the debug executable");
    run_step.dependOn(&main_run_cmd.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const main_unit_tests = b.addTest(.{ .root_module = main_module });

    const run_exe_unit_tests = b.addRunArtifact(main_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    check_step.dependOn(test_step);

    // Code coverage
    // TODO this requires kcov on $PATH
    const cov_run = b.addSystemCommand(&.{ "kcov", "--clean", "--include-pattern=src/", "zig-out/kcov/" });
    cov_run.addArtifactArg(main_unit_tests);

    const cov_step = b.step("cov", "Generate code coverage");
    cov_step.dependOn(&cov_run.step);

    check_step.dependOn(cov_step);
}

const TARGETS: []const std.Target.Query = &.{
    // .{ .cpu_arch = .aarch64, .os_tag = .macos },
    // .{ .cpu_arch = .x86_64, .os_tag = .macos },
    // .{ .cpu_arch = .aarch64, .os_tag = .linux },
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    // .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
    // .{ .cpu_arch = .aarch64, .os_tag = .windows, .os_version_min = .{ .windows = .win10_rs4 } },
    .{ .cpu_arch = .x86_64, .os_tag = .windows, .os_version_min = .{ .windows = .win10_rs4 } },
};
