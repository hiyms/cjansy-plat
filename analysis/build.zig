// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

const std = @import("std");

/// 构建 `analysis` 语义分析与查询数据库库模块及其单元测试。
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const common_dep = b.dependency("common", .{
        .target = target,
        .optimize = optimize,
    });

    const frontend_dep = b.dependency("frontend", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("analysis", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "common", .module = common_dep.module("common") },
            .{ .name = "frontend", .module = frontend_dep.module("frontend") },
        },
    });

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    const check_obj = b.addObject(.{
        .name = "analysis_check",
        .root_module = mod,
    });
    const check_step = b.step("check", "Compile-check analysis module (supports wasm32-freestanding)");
    check_step.dependOn(&check_obj.step);
}
