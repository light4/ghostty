const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const global = @import("../global.zig");

const log = std.log.scoped(.resourcesdir);

pub const ResourcesDir = struct {
    /// Avoid accessing these directly, use the app() and host() methods instead.
    app_path: ?[]const u8 = null,
    host_path: ?[]const u8 = null,

    /// Free resources held. Requires the same allocator as when resourcesDir()
    /// is called.
    pub fn deinit(self: *ResourcesDir, alloc: Allocator) void {
        if (self.app_path) |p| alloc.free(p);
        if (self.host_path) |p| alloc.free(p);
    }

    /// Get the directory to the bundled resources directory accessible
    /// by the application.
    pub fn app(self: *const ResourcesDir) ?[]const u8 {
        return self.app_path;
    }

    /// Get the directory to the bundled resources directory accessible
    /// by the host environment (i.e. for sandboxed applications). The
    /// returned directory might not be accessible from the application
    /// itself.
    ///
    /// In non-sandboxed environment, this should be the same as app().
    pub fn host(self: *const ResourcesDir) ?[]const u8 {
        return self.host_path orelse self.app_path;
    }
};

/// Gets the directory to the bundled resources directory, if it
/// exists (not all platforms or packages have it). The output is
/// owned by the caller.
///
/// This is highly Ghostty-specific and can likely be generalized at
/// some point but we can cross that bridge if we ever need to.
pub fn resourcesDir(alloc: Allocator) !ResourcesDir {
    // Only an explicit override takes priority over this binary's resources.
    // GHOSTTY_RESOURCES_DIR may be inherited from another Ghostty version.
    const override_dir = try resourceEnv(alloc, "GHOSTTY_RESOURCES_DIR_OVERRIDE");
    defer if (override_dir) |dir| alloc.free(dir);
    if (override_dir) |dir| {
        if (dir.len > 0) {
            if (validResourcesDir(dir)) {
                return .{ .app_path = try alloc.dupe(u8, dir) };
            }
            log.warn("ignoring unavailable GHOSTTY_RESOURCES_DIR_OVERRIDE: {s}", .{dir});
        }
    }

    // This is the sentinel value we look for in the path to know
    // we've found the resources directory.
    const sentinels = switch (comptime builtin.target.os.tag) {
        .windows => .{"terminfo/ghostty.terminfo"},
        .macos => .{"terminfo/78/xterm-ghostty"},
        .freebsd => .{ "site-terminfo/g/ghostty", "site-terminfo/x/xterm-ghostty" },
        else => .{ "terminfo/g/ghostty", "terminfo/x/xterm-ghostty" },
    };

    // Get the path to our running binary
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    var exe: []const u8 = exe_buf[0 .. std.process.executablePath(
        global.io(),
        &exe_buf,
    ) catch return inheritedResourcesDir(alloc)];

    // We have an exe path! Climb the tree looking for the terminfo
    // bundle as we expect it.
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    while (std.fs.path.dirname(exe)) |dir| {
        exe = dir;

        // On MacOS, we look for the app bundle path.
        if (comptime builtin.target.os.tag.isDarwin()) {
            inline for (sentinels) |sentinel| {
                if (try maybeDir(
                    &dir_buf,
                    dir,
                    "Contents/Resources",
                    sentinel,
                )) |v| {
                    return .{ .app_path = try std.fs.path.join(alloc, &.{ v, "ghostty" }) };
                }
            }
        }

        // On all platforms (except BSD), we look for a /usr/share style path. This
        // is valid even on Mac since there is nothing that requires
        // Ghostty to be in an app bundle.
        inline for (sentinels) |sentinel| {
            if (try maybeDir(
                &dir_buf,
                dir,
                if (builtin.target.os.tag == .freebsd) "local/share" else "share",
                sentinel,
            )) |v| {
                return .{ .app_path = try std.fs.path.join(alloc, &.{ v, "ghostty" }) };
            }
        }
    }

    return inheritedResourcesDir(alloc);
}

fn resourceEnv(alloc: Allocator, name: []const u8) !?[]u8 {
    return global.environ().getAlloc(alloc, name) catch |err| switch (err) {
        error.InvalidWtf8, error.EnvironmentVariableMissing => null,
        else => return err,
    };
}

fn validResourcesDir(path: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(global.io(), path, .{}) catch return false;
    dir.close(global.io());
    return true;
}

fn inheritedResourcesDir(alloc: Allocator) !ResourcesDir {
    // Retain the existing export as a fallback for non-bundled binaries.
    const dir = (try resourceEnv(alloc, "GHOSTTY_RESOURCES_DIR")) orelse return .{};
    defer alloc.free(dir);
    if (dir.len > 0) {
        if (validResourcesDir(dir)) return .{ .app_path = try alloc.dupe(u8, dir) };
        log.warn("ignoring unavailable GHOSTTY_RESOURCES_DIR: {s}", .{dir});
    }
    return .{};
}

/// Little helper to check if the "base/sub/suffix" directory exists and
/// if so return true. The "suffix" is just used as a way to verify a directory
/// seems roughly right.
///
/// "buf" must be large enough to fit base + sub + suffix. This is generally
/// max_path_bytes so its not a big deal.
pub fn maybeDir(
    buf: []u8,
    base: []const u8,
    sub: []const u8,
    suffix: []const u8,
) !?[]const u8 {
    const path = try std.fmt.bufPrint(buf, "{s}/{s}/{s}", .{ base, sub, suffix });

    if (std.Io.Dir.accessAbsolute(global.io(), path, .{})) {
        const len = path.len - suffix.len - 1;
        return buf[0..len];
    } else |_| {
        // Folder doesn't exist. If a different error happens its okay
        // we just ignore it and move on.
    }

    return null;
}
