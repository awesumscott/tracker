// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Scott Lowe
//! `tracker` — the in-repo issue-tracker library (Wave 1: core model + store).
//!
//! An agent-first task tracker where tasks are nodes and two edge kinds wire
//! them: `needs` (a prerequisite DAG) and `in` (arc membership). The headline
//! query is `next` — the prereqs-met ready frontier. Storage is an append-only
//! JSONL event log folded into memory. See docs/design.md.
//!
//! No CLI in this wave (Wave 2 wires `trk`). This root re-exports the modules and
//! pulls their unit tests into one `zig build test` aggregate.

const std = @import("std");

pub const ulid = @import("ulid.zig");
pub const model = @import("model.zig");
pub const json_codec = @import("json_codec.zig");
pub const store = @import("store.zig");

// Flat re-exports for ergonomic consumers.
pub const Ulid = ulid.Ulid;
pub const Task = model.Task;
pub const State = model.State;
pub const Event = model.Event;
pub const Op = model.Op;
pub const DocRef = model.DocRef;
pub const Store = store.Store;

test {
    // Pull every module's tests into the aggregate (`@import` of a file makes
    // its `test` blocks part of this root's test set).
    _ = ulid;
    _ = model;
    _ = json_codec;
    _ = store;
    _ = @import("store_test.zig");
}
