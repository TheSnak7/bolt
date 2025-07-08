const std = @import("std");
const aio = @import("aio");
const coro = @import("coro");
const Btx = @import("BoltContext.zig");
const TcpListener = @import("TcpListener.zig");
const TcpStream = @import("stream.zig").TcpStream;
const Http1 = @import("Http1.zig");
const DispatchServer = @import("dispatch.zig").DispatchServer;
const Service = @import("service.zig").Service;

const Self = @This();

pub const Options = struct {
    http1: Http1.Options = .{},
    max_connections: usize = 256,
    // Time to finish active responses before canceling the remaining tasks.
    shutdown_timeout: u64 = 5 * std.time.ns_per_s,
};

listener: TcpListener,
http: Http1,
options: Options,
changed: aio.EventSource,
clients: std.ArrayListUnmanaged(*Client) = .empty,
task: ?coro.Task = null,
started: bool = false,
stopping: bool = false,
closed: bool = false,

const Client = struct {
    server: *Self,
    stream: TcpStream,
    dispatcher: DispatchServer = undefined,
    task: ?coro.Task = null,
    done: bool = false,

    fn run(self: *Client, btx: Btx) void {
        defer {
            self.task = null;
            self.done = true;
            self.server.changed.notify();
        }
        defer self.dispatcher.deinit();
        self.dispatcher.call(btx) catch |err| switch (err) {
            error.Canceled, error.Timeout, error.ConnectionResetByPeer, error.BrokenPipe, error.SocketNotConnected => {},
            else => std.log.err("Connection failed: {s}", .{@errorName(err)}),
        };
    }
};

pub fn bind(address: *const std.net.Address, options: Options) !Self {
    if (options.max_connections == 0) return error.InvalidOptions;
    const http = try Http1.init(options.http1);
    var listener = try TcpListener.bind(address);
    errdefer listener.deinit();
    return .{
        .listener = listener,
        .http = http,
        .options = options,
        .changed = try aio.EventSource.init(),
    };
}

pub fn localAddress(self: *Self) !std.net.Address {
    if (self.closed or self.listener.closed) return error.ServerClosed;
    return self.listener.localAddress();
}

// The service and server storage must stay alive until serve returns.
// All operations on a server run on the same scheduler thread.
pub fn serve(self: *Self, btx: Btx, service: Service) !void {
    if (self.closed) return error.ServerClosed;
    if (self.started) return error.AlreadyStarted;
    if (self.stopping) return error.ServerStopped;
    self.task = coro.Task.current() orelse return error.NotInTask;
    self.started = true;
    defer self.task = null;
    defer self.listener.deinit();
    defer {
        for (self.clients.items) |client| {
            if (client.task) |task| task.cancel();
            btx.allocator.destroy(client);
        }
        self.clients.deinit(btx.allocator);
        self.clients = .empty;
    }

    while (!self.stopping) {
        self.reap(btx.allocator);
        if (self.clients.items.len >= self.options.max_connections) {
            coro.io.single(.wait_event_source, .{ .source = &self.changed }) catch |err| {
                if (self.stopping and err == error.Canceled) break;
                return err;
            };
            continue;
        }
        const stream = self.listener.accept() catch |err| {
            if (self.stopping and err == error.Canceled) break;
            if (err == error.ConnectionAborted) continue;
            return err;
        };
        if (self.stopping) {
            stream.deinit();
            break;
        }
        try self.spawnClient(btx, stream, service);
    }

    self.listener.deinit();
    // Idle and unfinished requests can close now. Parsed requests finish with close.
    for (self.clients.items) |client| {
        if (client.done) continue;
        client.dispatcher.connection.state.keep_alive = false;
        if (client.dispatcher.connection.state.reading == .Init) {
            if (client.task) |task| task.signal();
        }
    }

    var timer = try std.time.Timer.start();
    while (self.clients.items.len > 0) {
        self.reap(btx.allocator);
        if (self.clients.items.len == 0) break;
        const elapsed = timer.read();
        if (elapsed >= self.options.shutdown_timeout) break;
        // The deadline covers the entire drain, including slow services.
        coro.io.multi(.{
            aio.op(.wait_event_source, .{ .source = &self.changed }, .soft),
            aio.op(.link_timeout, .{ .ns = self.options.shutdown_timeout - elapsed }, .unlinked),
        }) catch |err| switch (err) {
            error.SomeOperationFailed => break,
            else => return err,
        };
    }
}

pub fn stop(self: *Self) void {
    if (self.stopping or self.closed) return;
    self.stopping = true;
    for (self.clients.items) |client| {
        if (!client.done) client.dispatcher.connection.state.keep_alive = false;
    }
    if (self.task) |task| task.signal();
}

// Call stop and wait for serve before destroying the server.
pub fn deinit(self: *Self) void {
    if (self.closed) return;
    std.debug.assert(self.task == null);
    self.closed = true;
    self.listener.deinit();
    self.changed.deinit();
}

fn spawnClient(self: *Self, btx: Btx, stream: TcpStream, service: Service) !void {
    const client = btx.allocator.create(Client) catch |err| {
        stream.deinit();
        return err;
    };
    client.* = .{ .server = self, .stream = stream };
    client.dispatcher = self.http.makeDispatcher(btx.allocator, client.stream.any(), service) catch |err| {
        stream.deinit();
        btx.allocator.destroy(client);
        return err;
    };
    errdefer {
        client.dispatcher.deinit();
        btx.allocator.destroy(client);
    }
    try self.clients.append(btx.allocator, client);
    errdefer _ = self.clients.pop();
    const task = try btx.scheduler.spawn(Client.run, .{ client, btx }, .{ .detached = true });
    // spawn runs immediately, so the connection may already have finished.
    if (!client.done) client.task = task.any();
}

fn reap(self: *Self, allocator: std.mem.Allocator) void {
    var i: usize = 0;
    while (i < self.clients.items.len) {
        const client = self.clients.items[i];
        if (!client.done) {
            i += 1;
            continue;
        }
        _ = self.clients.swapRemove(i);
        allocator.destroy(client);
    }
}
