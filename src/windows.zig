const std = @import("std");
const win = std.os.windows;
const win32 = @import("win32.zig");
const events = @import("events.zig");

pub var list = std.ArrayList(*Window).init(allocator);
var _gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = _gpa.allocator();

pub const Window = struct {
    handle: win.HWND,
    name: []const u8,
    rect: *win.RECT,

    const InvalidWindowError = error{
        WindowNonExistent,
        WindowInvisible,
        WindowUnControlable,
        WindowCloaked,
        WindowIsNotRoot,
        WindowAlreadyAdded,
        WindowIsTaskbar,
        WindowIsChild,
        IsSystemApp,
        NullProcess,
    };

    pub fn init(handle: win.HWND) InvalidWindowError!*Window {
        if (findByHandle(handle)) |_| return error.WindowAlreadyAdded;

        if (!win32.window.isWindow(handle)) return error.WindowNonExistent;

        if (!win32.window.visible(handle)) return error.WindowInvisible;

        const style = win32.window.longPtr(handle, .Style);
        if (style.child) return error.WindowIsChild;

        if (handle != win32.window.ancestor(handle, .RootOwner).?) return error.WindowIsNotRoot;

        if (win32.window.Attribute.get(handle, .Cloaked) != win.FALSE) return error.WindowCloaked;

        const exstyle = win32.window.longPtr(handle, .ExStyle);
        if (exstyle.no_activate or exstyle.tool_window) return error.WindowUnControlable;

        const rect = allocator.create(win.RECT) catch unreachable;
        errdefer allocator.destroy(rect);
        rect.* = win32.window.rect.get(handle, true);

        const rect_nc = win32.window.rect.get(handle, false);
        // zig fmt: off
        if (
            rect_nc.bottom == monitor.bottom
            and rect_nc.right == monitor.right
            and rect_nc.top == (monitor.bottom - rect.bottom)
        ) return error.WindowIsTaskbar;
        // zig fmt: on

        const name = processName(handle) catch unreachable;
        errdefer allocator.free(name);

        for (system_apps.items) |sysapp| if (std.mem.eql(u8, sysapp, name)) return error.IsSystemApp;

        const ptr = allocator.create(Window) catch unreachable;
        ptr.* = .{
            .handle = handle,
            .name = name,
            .rect = rect,
        };
        return ptr;
    }

    pub fn deinit(self: *Window) void {
        allocator.free(self.name);
        allocator.destroy(self.rect);
        allocator.destroy(self);
        self.* = undefined;
    }

    fn processName(handle: win.HWND) ![]const u8 {
        const process = win32.process.open(win32.window.processId(handle), .ProcessQueryLimitedInformation).?;
        defer win.CloseHandle(process);

        var buf16: [win.PATH_MAX_WIDE:0]u16 = undefined;
        const path16 = buf16[0..win32.process.path(process, &buf16)];

        var buf8: [std.fs.MAX_PATH_BYTES:0]u8 = undefined;
        const path8 = buf8[0..try std.unicode.utf16leToUtf8(&buf8, path16)];
        return try allocator.dupe(u8, std.fs.path.basename(path8));
    }

    pub fn minimized(self: *const Window) bool {
        return win32.window.minimized(self.handle);
    }
};

pub var desktop: win.RECT = undefined;
pub var monitor: win.RECT = undefined;
pub fn init() !void {
    try initSystemApps();
    const info = win32.window.monitorInfo(win32.window.monitor(win32.window.desktop(), .Null).?);
    desktop = info.rcWork;
    monitor = info.rcMonitor;
    std.debug.assert(win32.window.enumerate(enumerator));
    std.debug.print("[-] Monitor: {any}\n", .{monitor});
    std.debug.print("[0] Desktop: {any}\n", .{desktop});
    for (list.items, 1..) |w, i| std.debug.print("[{d}] {s}: {any}\n", .{ i, w.name, w.rect.* });
    if (win32.window.foreground()) |w| events.process(.Foreground, w);
}

pub fn deinit() void {
    for (list.items) |w| {
        win32.window.Attribute.set(w.handle, .{ .BorderColor = .Default });
        win32.window.Attribute.set(w.handle, .{ .CornerPreference = .Default });
    }
}

pub fn findByHandle(handle: win.HWND) ?*Window {
    for (list.items) |w| if (w.handle == handle) return w;
    return null;
}

fn enumerator(handle: win.HWND, _: win.LPARAM) callconv(win.WINAPI) bool {
    events.process(.Show, handle);
    return true;
}

var _sys = std.heap.ArenaAllocator.init(allocator);
// maybe BoundedArray instead?
var system_apps = std.ArrayList([]const u8).init(_sys.allocator());

/// `$SystemRoot/SystemApps/*/*.exe`
fn initSystemApps() !void {
    // would SHGetKnownFolderPath() be better here?
    const sysroot = try std.process.getEnvVarOwned(allocator, "SystemRoot");
    defer allocator.free(sysroot);

    const sysapps_path = try std.fs.path.join(allocator, &.{ sysroot, "SystemApps" });
    defer allocator.free(sysapps_path);

    // TODO 0.12 https://github.com/ziglang/zig/pull/18076
    var sysapps_dir = try std.fs.openIterableDirAbsolute(sysapps_path, .{});
    defer sysapps_dir.close();

    var sysapps_iter = sysapps_dir.iterate();
    while (try sysapps_iter.next()) |dir| {
        var appdir = try sysapps_dir.dir.openIterableDir(dir.name, .{});
        defer appdir.close();
        var appiter = appdir.iterate();
        while (try appiter.next()) |item|
            if (item.kind == .file and std.mem.endsWith(u8, item.name, ".exe")) {
                try system_apps.append(try _sys.allocator().dupe(u8, item.name));
            };
    }
}
