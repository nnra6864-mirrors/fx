//! Local diagnostic collection used by `/trace`.
//!
//! This is intentionally separate from `debug_trace.zig`: trace is an opt-in,
//! low-level event log, while diagnostics are small in-memory summaries that
//! make the user-initiated trace report useful without requiring tracing.

const network_metrics = @import("network_metrics.zig");
const tool_call_metrics = @import("tool_call_metrics.zig");
const render_metrics = @import("render_metrics.zig");

pub const NetworkCall = network_metrics.NetworkCall;
pub const NetworkCallKind = network_metrics.NetworkCallKind;
pub const ToolCallMetric = tool_call_metrics.ToolCallMetric;
pub const ToolCallRecord = tool_call_metrics.ToolCallRecord;
pub const ToolCallOutcome = tool_call_metrics.ToolCallOutcome;
pub const network_ring_capacity = network_metrics.ring_capacity;
pub const tool_call_ring_capacity = tool_call_metrics.ring_capacity;
pub const RenderEvent = render_metrics.Event;
pub const render_ring_capacity = render_metrics.ring_capacity;

pub fn recordRenderEvent(kind: render_metrics.Kind, comptime fmt: []const u8, args: anytype) void {
    render_metrics.record(kind, fmt, args);
}

pub fn snapshotRenderEvents(out: []RenderEvent) usize {
    return render_metrics.snapshot(out);
}

pub fn recordNetworkCall(call: NetworkCall) void {
    network_metrics.record(call);
}

pub fn snapshotNetworkCalls(out: []NetworkCall) usize {
    return network_metrics.snapshot(out);
}

pub fn recordToolCall(call: ToolCallMetric) void {
    tool_call_metrics.record(call);
}

pub fn recordToolCallResult(input: ToolCallRecord) void {
    tool_call_metrics.recordResult(input);
}

pub fn snapshotToolCalls(out: []ToolCallMetric) usize {
    return tool_call_metrics.snapshot(out);
}

pub fn resetSession() void {
    network_metrics.reset();
    tool_call_metrics.reset();
    render_metrics.reset();
}

pub fn resetForTest() void {
    resetSession();
}
