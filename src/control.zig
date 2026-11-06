const std = @import("std");
const c = @import("c.zig").api;
const support = @import("support.zig");

pub const Command = enum(u8) { hide = 'h', show = 's', quit = 'q', set_video = 'v' };
pub const max_path = 4096;

const Address = struct {
    value: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un),
    fn init(path: []const u8) !Address {
        var self: Address = .{};
        if (path.len >= self.value.sun_path.len) return error.ControlSocketPathTooLong;
        self.value.sun_family = c.AF_UNIX;
        @memcpy(@as([*]u8, @ptrCast(&self.value.sun_path))[0..path.len], path);
        return self;
    }
    fn ptr(self: *const Address) c.__CONST_SOCKADDR_ARG {
        return .{ .__sockaddr_un__ = &self.value };
    }
};

const Paths = struct {
    directory: [:0]u8,
    socket: [:0]u8,
    lock: [:0]u8,
    a: std.mem.Allocator,

    fn init(a: std.mem.Allocator, create: bool) !Paths {
        if (support.env("WAYLAND_SOCKET") != null) return error.InheritedWaylandSocketUnsupported;
        const runtime_env = support.env("XDG_RUNTIME_DIR") orelse return error.RuntimeDirectoryRequired;
        if (!std.fs.path.isAbsolute(runtime_env)) return error.RuntimeDirectoryRequired;
        const runtime_z = try a.dupeSentinel(u8, runtime_env, 0);
        defer a.free(runtime_z);
        const runtime_ptr = c.realpath(runtime_z, null) orelse return error.RuntimeDirectoryRequired;
        defer c.free(runtime_ptr);
        const runtime = std.mem.span(runtime_ptr);
        var runtime_stat: c.struct_stat = undefined;
        if (c.stat(runtime_ptr, &runtime_stat) != 0 or (runtime_stat.st_mode & c.S_IFMT) != c.S_IFDIR or
            runtime_stat.st_uid != c.getuid() or (runtime_stat.st_mode & 0o077) != 0)
            return error.UnsafeRuntimeDirectory;
        const display = support.env("WAYLAND_DISPLAY") orelse "wayland-0";
        const lexical = try std.fs.path.resolve(a, &.{ runtime, display });
        defer a.free(lexical);
        const display_z = try a.dupeSentinel(u8, lexical, 0);
        defer a.free(display_z);
        const resolved = c.realpath(display_z, null);
        defer if (resolved != null) c.free(resolved);
        const canonical = if (resolved != null) std.mem.span(resolved) else lexical;
        const hash = std.hash.Wyhash.hash(0, canonical);
        const dir = try std.fmt.allocPrintSentinel(a, "{s}/stillwave-{x}", .{ runtime, hash }, 0);
        errdefer a.free(dir);
        if (create and c.mkdir(dir, 0o700) != 0 and c.__errno_location().* != c.EEXIST)
            return error.ControlDirectoryFailed;
        var st: c.struct_stat = undefined;
        if (c.lstat(dir, &st) != 0) return error.NoRunningInstance;
        if ((st.st_mode & c.S_IFMT) != c.S_IFDIR or st.st_uid != c.getuid() or (st.st_mode & 0o077) != 0)
            return error.UnsafeControlDirectory;
        const socket = try std.fmt.allocPrintSentinel(a, "{s}/control.sock", .{dir}, 0);
        errdefer a.free(socket);
        const lock = try std.fmt.allocPrintSentinel(a, "{s}/instance.lock", .{dir}, 0);
        return .{ .a = a, .directory = dir, .socket = socket, .lock = lock };
    }

    fn deinit(self: *Paths) void {
        self.a.free(self.lock);
        self.a.free(self.socket);
        self.a.free(self.directory);
    }
};

pub const Request = struct {
    command: ?Command,
    peer: Address,
    peer_len: c.socklen_t,
    path: [max_path]u8 = undefined,
    path_len: usize = 0,
};

/// One datagram per command, one reply after the owner applies it. The private
/// directory restricts access to this user; nonblocking replies cannot stall rendering.
pub const Server = struct {
    fd: c_int,
    lock_fd: c_int,
    paths: Paths,

    pub fn init(a: std.mem.Allocator) !Server {
        var paths = try Paths.init(a, true);
        errdefer paths.deinit();
        const lock = c.open(paths.lock, c.O_RDWR | c.O_CREAT | c.O_CLOEXEC | c.O_NOFOLLOW, @as(c_uint, 0o600));
        if (lock < 0) return error.ControlLockFailed;
        errdefer _ = c.close(lock);
        var st: c.struct_stat = undefined;
        if (c.fstat(lock, &st) != 0 or (st.st_mode & c.S_IFMT) != c.S_IFREG or st.st_uid != c.getuid() or (st.st_mode & 0o077) != 0)
            return error.UnsafeControlLock;
        if (c.flock(lock, c.LOCK_EX | c.LOCK_NB) != 0) {
            if (c.__errno_location().* == c.EWOULDBLOCK) return error.AlreadyRunning;
            return error.ControlLockFailed;
        }
        const fd = c.socket(c.AF_UNIX, c.SOCK_DGRAM | c.SOCK_CLOEXEC | c.SOCK_NONBLOCK, 0);
        if (fd < 0) return error.ControlSocketFailed;
        errdefer _ = c.close(fd);
        const address = try Address.init(paths.socket);
        // Only the lock holder may remove a socket left behind by a crashed owner.
        if (c.unlink(paths.socket) != 0 and c.__errno_location().* != c.ENOENT)
            return error.ControlSocketFailed;
        if (c.bind(fd, address.ptr(), @sizeOf(c.struct_sockaddr_un)) != 0) return error.ControlSocketFailed;
        return .{ .fd = fd, .lock_fd = lock, .paths = paths };
    }

    pub fn deinit(self: *Server) void {
        _ = c.close(self.fd);
        _ = c.unlink(self.paths.socket);
        // Never unlink the lock inode: another starter could already have it open.
        _ = c.close(self.lock_fd);
        self.paths.deinit();
    }

    pub fn receive(self: *Server) !?Request {
        var request: Request = .{ .command = null, .peer = .{}, .peer_len = @sizeOf(c.struct_sockaddr_un) };
        var bytes: [max_path + 1]u8 = undefined;
        const n = c.recvfrom(self.fd, &bytes, bytes.len, c.MSG_DONTWAIT | c.MSG_TRUNC, .{ .__sockaddr_un__ = &request.peer.value }, &request.peer_len);
        if (n < 0) {
            if (c.__errno_location().* == c.EAGAIN or c.__errno_location().* == c.EINTR) return null;
            return error.ControlReceiveFailed;
        }
        if (n == 1) request.command = switch (bytes[0]) {
            'h' => .hide,
            's' => .show,
            'q' => .quit,
            else => null,
        };
        if (n > 1 and n <= bytes.len and bytes[0] == 'v') {
            const path = bytes[1..@intCast(n)];
            if (std.fs.path.isAbsolute(path) and std.mem.indexOfScalar(u8, path, 0) == null) {
                request.command = .set_video;
                request.path_len = path.len;
                @memcpy(request.path[0..path.len], path);
            }
        }
        return request;
    }

    pub fn reject(self: *Server, request: Request, message: []const u8) void {
        var bytes: [512]u8 = undefined;
        bytes[0] = 'E';
        const len = @min(message.len, bytes.len - 1);
        @memcpy(bytes[1..][0..len], message[0..len]);
        _ = c.sendto(self.fd, &bytes, len + 1, c.MSG_DONTWAIT | c.MSG_NOSIGNAL, request.peer.ptr(), request.peer_len);
    }

    pub fn reply(self: *Server, request: Request, success: bool) void {
        const byte = [_]u8{if (success) 'K' else 'E'};
        _ = c.sendto(self.fd, &byte, 1, c.MSG_DONTWAIT | c.MSG_NOSIGNAL, request.peer.ptr(), request.peer_len);
    }
};

pub fn send(a: std.mem.Allocator, command: Command) !void {
    return sendRequest(a, command, null, null);
}

pub fn setVideo(a: std.mem.Allocator, path: []const u8, d: *support.Diagnostic) !void {
    if (path.len == 0 or path.len > max_path or std.mem.indexOfScalar(u8, path, 0) != null)
        return d.fail(a, "invalid or oversized video path", .{});
    return sendRequest(a, .set_video, path, d);
}

fn sendRequest(a: std.mem.Allocator, command: Command, path: ?[]const u8, d: ?*support.Diagnostic) !void {
    var paths = try Paths.init(a, false);
    defer paths.deinit();
    const fd = c.socket(c.AF_UNIX, c.SOCK_DGRAM | c.SOCK_CLOEXEC | c.SOCK_NONBLOCK, 0);
    if (fd < 0) return error.ControlSocketFailed;
    defer _ = c.close(fd);
    // Linux autobind creates a unique abstract reply address, cleaned up on close.
    var local = std.mem.zeroes(c.struct_sockaddr_un);
    local.sun_family = c.AF_UNIX;
    if (c.bind(fd, .{ .__sockaddr_un__ = &local }, @sizeOf(c.sa_family_t)) != 0) return error.ControlSocketFailed;
    const address = try Address.init(paths.socket);
    if (c.connect(fd, address.ptr(), @sizeOf(c.struct_sockaddr_un)) != 0) return error.NoRunningInstance;
    var bytes: [max_path + 1]u8 = undefined;
    bytes[0] = @backingInt(command);
    const len = if (path) |p| p.len + 1 else 1;
    if (path) |p| @memcpy(bytes[1..len], p);
    if (c.send(fd, &bytes, len, c.MSG_NOSIGNAL) != len) return error.ControlSendFailed;
    var pollfd: c.struct_pollfd = .{ .fd = fd, .events = c.POLLIN, .revents = 0 };
    // Commands acknowledge application, not actual compositor presentation.
    if (c.poll(&pollfd, 1, if (path != null) 60000 else 5000) <= 0) return error.ControlReplyTimeout;
    var reply: [512]u8 = undefined;
    const n = c.recv(fd, &reply, reply.len, 0);
    if (n != 1 or reply[0] != 'K') {
        if (d) |diagnostic| if (n > 1 and reply[0] == 'E') {
            diagnostic.message = try a.dupe(u8, reply[1..@intCast(n)]);
        };
        return error.ControlCommandFailed;
    }
}
