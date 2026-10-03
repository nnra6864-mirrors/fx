//! First-party lifecycle hook providers.
//!
//! Notification hooks live in `notifications` and keep sound policy outside
//! the Core hook harness. Terminal host status lives in
//! `builtins/terminal_status`.

pub const notifications = @import("hooks/notifications.zig");
