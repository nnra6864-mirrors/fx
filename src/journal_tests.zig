// Opt-in red suite: zig build test-journal. Do not import into main.zig while
// these acceptance tests intentionally describe unimplemented journal behavior.
test {
    _ = @import("core/agent/runtime/tests/journal_crash_flow.zig");
    _ = @import("acp/server.zig");
    _ = @import("acp/prompt.zig");
}
