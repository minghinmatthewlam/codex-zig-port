const std = @import("std");

const modules = .{
    @import("agents_md.zig"),
    @import("api.zig"),
    @import("auth.zig"),
    @import("cli_utils.zig"),
    @import("config.zig"),
    @import("exec.zig"),
    @import("features_cmd.zig"),
    @import("git_diff.zig"),
    @import("login.zig"),
    @import("mcp_cmd.zig"),
    @import("mcp_runtime.zig"),
    @import("main.zig"),
    @import("review.zig"),
    @import("sandbox.zig"),
    @import("sandbox_cmd.zig"),
    @import("session.zig"),
    @import("session_store.zig"),
    @import("tools.zig"),
    @import("tui.zig"),
    @import("workdir.zig"),
};

test {
    inline for (modules) |module| {
        std.testing.refAllDecls(module);
    }
}
