const std = @import("std");

const builtin = @import("builtin");
const fs = std.fs;
const log = std.log;
const metadata = @import("metadata.zig");
const win_asni = @cImport(@cInclude("win_ansi_fix.h"));

const MetaStruct = metadata.MetaStruct;
const BufMap = std.BufMap;

const MAX_READ_SIZE = 256;

fn get_erl_exe_name(werl: bool) []const u8 {
    if (builtin.os.tag == .windows and werl) {
        return "werl.exe";
    } else if (builtin.os.tag == .windows) {
        return "erl.exe";
    } else {
        return "erl";
    }
}

pub fn launch(install_dir: []const u8, env_map: *BufMap, meta: *const MetaStruct, args_trimmed: []const []const u8, werl: bool) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var allocator = arena.allocator();

    // Computer directories we care about
    const release_cookie_path = try fs.path.join(allocator, &[_][]const u8{ install_dir, "releases", "COOKIE" });
    const release_lib_path = try fs.path.join(allocator, &[_][]const u8{ install_dir, "lib" });
    const install_vm_args_path = try fs.path.join(allocator, &[_][]const u8{ install_dir, "releases", meta.app_version, "vm.args" });
    const config_sys_path = try fs.path.join(allocator, &[_][]const u8{ install_dir, "releases", meta.app_version, "sys" });
    const rel_vsn_dir = try fs.path.join(allocator, &[_][]const u8{ install_dir, "releases", meta.app_version });
    const boot_path = try fs.path.join(allocator, &[_][]const u8{ rel_vsn_dir, "start" });

    const erts_version_name = try std.fmt.allocPrint(allocator, "erts-{s}", .{meta.erts_version});
    var erl_bin_path = try fs.path.join(allocator, &[_][]const u8{ install_dir, erts_version_name, "bin", get_erl_exe_name(werl) });

    // Read the Erlang COOKIE file for the release
    const release_cookie_file = try fs.openFileAbsolute(release_cookie_path, .{ .read = true, .write = false });
    const release_cookie_content = try release_cookie_file.readToEndAlloc(allocator, MAX_READ_SIZE);

    // Set all the required release arguments
    try env_map.put("ERL_ROOTDIR", install_dir);
    try env_map.put("RELEASE_ROOT", install_dir);
    try env_map.put("RELEASE_SYS_CONFIG", config_sys_path);

    const erlang_cli = &[_][]const u8{
        erl_bin_path[0..],
        "-elixir ansi_enabled true",
        "-noshell",
        "-s elixir start_cli",
        "-mode embedded",
        "-setcookie",
        release_cookie_content,
        "-boot",
        boot_path,
        "-boot_var",
        "RELEASE_LIB",
        release_lib_path,
        "-args_file",
        install_vm_args_path,
        "-config",
        config_sys_path,
    };

    if (builtin.os.tag == .windows) {
        // Fix up Windows 10+ consoles having ANSI escape support, but only if we set some flags
        win_asni.enable_virtual_term();
        const final_args = try std.mem.concat(allocator, []const u8, &.{ erlang_cli,  args_trimmed });

        const win_child_proc = try std.ChildProcess.init(final_args, allocator);
        win_child_proc.env_map = env_map;
        win_child_proc.stdout_behavior = .Inherit;
        win_child_proc.stdin_behavior = .Inherit;

        log.debug("CLI List: {s}", .{final_args});

        const win_term = try win_child_proc.spawnAndWait();
        switch (win_term) {
            .Exited => |code| {
                std.process.exit(code);
            },
            else => std.process.exit(1),
        }
    } else {
        const final_args = try std.mem.concat(allocator, []const u8, &.{ erlang_cli, args_trimmed });

        log.debug("CLI List: {s}", .{final_args});

        return std.process.execve(allocator, final_args, env_map);
    }
}