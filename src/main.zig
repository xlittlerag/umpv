const std = @import("std");
const log = std.log.scoped(.umpv);

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = &gpa.backing_allocator;
    defer _ = gpa.deinit();

    const files = try getFiles(alloc);
    defer {
        for (files) |f| {
            alloc.free(f);
        }
        alloc.free(files);
    }

    const socket_path = try getSocketPath(alloc);
    defer alloc.free(socket_path);

    log.info("Socket path = {s}", .{socket_path});

    const socket = std.net.connectUnixSocket(socket_path) catch |err| switch (err) {
        error.ConnectionRefused, error.FileNotFound => {
            var arena = std.heap.ArenaAllocator.init(alloc.*);
            defer arena.deinit();

            var argv = std.ArrayList([]const u8).init(arena.child_allocator);
            try argv.appendSlice(&.{
                "mpv",
                "--no-terminal",
                "--force-window",
                "--script-opts=ytdl_hook-ytdl_path=yt-dlp",
            });
            try argv.append(try std.fmt.allocPrint(arena.child_allocator, "--input-ipc-server={s}", .{socket_path}));
            try argv.append("--");
            try argv.appendSlice(files);

            log.debug("argv =", .{});
            for (argv.items) |arg| {
                log.debug("    {s}", .{arg});
            }

            var child_process = std.ChildProcess.init(argv.items, alloc.*);
            switch (try child_process.spawnAndWait()) {
                .Exited => |code| std.process.exit(code),
                .Signal => |signal| log.warn("Process signaled {}", .{signal}),
                .Stopped => |stop_code| log.warn("Process stopped with code {}", .{stop_code}),
                .Unknown => |unknown_code| log.warn("Process exited with unknown code {}", .{unknown_code}),
            }
            return;
        },
        else => |e| {
            log.err("Unexpected error while checking for socket: {}", .{e});
            return e;
        },
    };

    const out = socket.writer();

    for (files) |f| {
        try out.print("raw loadfile \"{}\" append\n", .{std.zig.fmtEscapes(f)});
        log.info("raw loadfile \"{}\" append\n", .{std.zig.fmtEscapes(f)});
    }
}

fn getSocketPath(alloc: *std.mem.Allocator) ![]const u8 {
    const xdg_runtime_dir = std.process.getEnvVarOwned(alloc.*, "XDG_RUNTIME_DIR") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            log.err("XDG_RUNTIME_DIR must be defined", .{});
            return error.RuntimeDirNotDefined;
        },
        error.InvalidUtf8 => {
            log.err("XDG_RUNTIME_DIR must be valid UTF-8", .{});
            return error.RuntimeDirInvalidUTF8;
        },
        error.OutOfMemory => |e| return e,
    };
    defer alloc.free(xdg_runtime_dir);

    return try std.fs.path.join(alloc.*, &.{ xdg_runtime_dir, "umpv_socket" });
}

fn getFiles(alloc: *std.mem.Allocator) ![]const []const u8 {
    var args = try std.process.argsAlloc(alloc.*);
    defer std.process.argsFree(alloc.*, args);

    std.debug.assert(args.len >= 1);

    var files = try std.ArrayList([]u8).initCapacity(alloc.*, args.len - 1);
    defer {
        for (files.items) |f| {
            alloc.free(f);
        }
        files.deinit();
    }

    for (args[1..]) |arg| {
        if (isURL(arg)) {
            files.appendAssumeCapacity(try alloc.dupe(u8, arg));
        } else {
            const resolved_path = try std.fs.path.resolve(alloc.*, &.{arg});
            files.appendAssumeCapacity(resolved_path);
        }
    }

    return files.toOwnedSlice();
}

fn isURL(string: []const u8) bool {
    var parts_iter = std.mem.split(u8, string, "://");
    const prefix = parts_iter.next() orelse return false;
    _ = parts_iter.next() orelse return false;

    for (prefix) |char| {
        if (!(std.ascii.isAlNum(char) or char == '_')) {
            return false;
        }
    }

    return true;
}
