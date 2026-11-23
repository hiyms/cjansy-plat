// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

const std = @import("std");

/// 构建 `frontend` 库模块、单元测试，以及在启用可执行子命令选项时构建 `cjfrontend` 可执行文件。
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exec_lexer = b.option(bool, "exec_lexer", "Build cjfrontend executable with lexer subcommand") orelse false;
    const exec_parser = b.option(bool, "exec_parser", "Build cjfrontend executable with parser subcommand") orelse false;
    const build_exe = exec_lexer or exec_parser;

    const common_dep = b.dependency("common", .{
        .target = target,
        .optimize = optimize,
    });

    const buffer_dep = b.dependency("buffer", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("frontend", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "common", .module = common_dep.module("common") },
            .{ .name = "buffer", .module = buffer_dep.module("buffer") },
        },
    });

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    if (build_exe) {
        if (b.lazyDependency("clap", .{
            .target = target,
            .optimize = optimize,
        })) |clap_dep| {
            const exe_options = b.addOptions();
            exe_options.addOption(bool, "exec_lexer", exec_lexer);
            exe_options.addOption(bool, "exec_parser", exec_parser);

            const exe = b.addExecutable(.{
                .name = "cjfrontend",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/main.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "common", .module = common_dep.module("common") },
                        .{ .name = "frontend", .module = mod },
                        .{ .name = "clap", .module = clap_dep.module("clap") },
                        .{ .name = "build_options", .module = exe_options.createModule() },
                    },
                }),
            });
            b.installArtifact(exe);

            const run_step = b.step("run", "Run cjfrontend");
            const run_cmd = b.addRunArtifact(exe);
            run_step.dependOn(&run_cmd.step);
            run_cmd.step.dependOn(b.getInstallStep());
            run_cmd.addPassthruArgs();

            const exe_tests = b.addTest(.{
                .root_module = exe.root_module,
            });
            const run_exe_tests = b.addRunArtifact(exe_tests);
            test_step.dependOn(&run_exe_tests.step);
        }
    }
}
