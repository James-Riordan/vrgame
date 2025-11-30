const std = @import("std");

fn linkVulkanLoader(
    exe: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    b: *std.Build,
) void {
    const os_tag = target.result.os.tag;

    switch (os_tag) {
        .windows => {
            const sdk = std.process.getEnvVarOwned(b.allocator, "VULKAN_SDK") catch null;
            if (sdk) |sdk_path| {
                defer b.allocator.free(sdk_path);

                const lib_dir = std.fs.path.join(b.allocator, &.{ sdk_path, "Lib" }) catch null;
                if (lib_dir) |ld| {
                    defer b.allocator.free(ld);
                    exe.addLibraryPath(.{ .cwd_relative = ld });
                }
            }
            exe.linkSystemLibrary("vulkan-1");
        },
        .linux => {
            exe.linkSystemLibrary("vulkan");
        },
        .macos => {
            exe.linkSystemLibrary("vulkan");
        },
        else => {},
    }
}

/// Ensure we have a workspace-local ./registry/vk.xml (download once if missing).
fn ensureVkRegistry(b: *std.Build) std.Build.LazyPath {
    const xml_rel = "registry/vk.xml";
    const registry_dir = "registry";
    const cwd = std.fs.cwd();

    if (cwd.openFile(xml_rel, .{})) |file| {
        file.close();
        return b.path(xml_rel);
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => {
            std.debug.print("error: failed to open {s}: {s}\n", .{
                xml_rel,
                @errorName(err),
            });
            @panic("cannot access registry/vk.xml");
        },
    }

    cwd.makeDir(registry_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            std.debug.print("error: failed to create directory '{s}': {s}\n", .{
                registry_dir,
                @errorName(err),
            });
            @panic("cannot create registry directory");
        },
    };

    var argv = [_][]const u8{
        "curl",
        "-L",
        "https://raw.githubusercontent.com/KhronosGroup/Vulkan-Docs/main/xml/vk.xml",
        "-o",
        xml_rel,
    };

    var child = std.process.Child.init(&argv, b.allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = child.spawnAndWait() catch |err| {
        std.debug.print("error: failed to spawn curl for vk.xml: {s}\n", .{@errorName(err)});
        @panic("curl not available or failed to start");
    };

    switch (term) {
        .Exited => |code| if (code != 0) {
            std.debug.print("error: curl (vk.xml) exited with code {d}\n", .{code});
            @panic("failed to download vk.xml");
        },
        else => {
            std.debug.print("error: curl (vk.xml) terminated abnormally: {any}\n", .{term});
            @panic("failed to download vk.xml");
        },
    }

    if (cwd.openFile(xml_rel, .{})) |file2| {
        file2.close();
    } else |err| {
        std.debug.print("error: vk.xml download seems to have succeeded, but cannot reopen {s}: {s}\n", .{
            xml_rel,
            @errorName(err),
        });
        @panic("vk.xml missing after download");
    }

    return b.path(xml_rel);
}

/// Ensure we have a workspace-local ./registry/xr.xml compatible with openxr-zig.
fn ensureXrRegistry(b: *std.Build) std.Build.LazyPath {
    const cwd = std.fs.cwd();
    const registry_dir = "registry";
    const xml_rel = "registry/xr.xml";

    if (std.process.getEnvVarOwned(b.allocator, "VRGAME_XR_XML")) |env_path| {
        defer b.allocator.free(env_path);

        const is_abs = std.fs.path.isAbsolute(env_path);
        const open_result = if (is_abs)
            std.fs.openFileAbsolute(env_path, .{})
        else
            cwd.openFile(env_path, .{});

        if (open_result) |file| {
            file.close();
            std.log.info("Using xr.xml from VRGAME_XR_XML={s}", .{env_path});
            return b.path(env_path);
        } else |err| {
            std.log.warn("VRGAME_XR_XML={s} but failed to open: {s}", .{ env_path, @errorName(err) });
        }
    } else |_| {}

    if (cwd.openFile(xml_rel, .{})) |file| {
        file.close();
        std.log.info("Using existing xr.xml at {s}", .{xml_rel});
        return b.path(xml_rel);
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => {
            std.debug.print("error: failed to open {s}: {s}\n", .{
                xml_rel,
                @errorName(err),
            });
            @panic("cannot access registry/xr.xml");
        },
    }

    cwd.makeDir(registry_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            std.debug.print("error: failed to create directory '{s}': {s}\n", .{
                registry_dir,
                @errorName(err),
            });
            @panic("cannot create registry directory");
        },
    };

    var argv = [_][]const u8{
        "curl",
        "-L",
        "https://raw.githubusercontent.com/zigadel/openxr-zig/ef4d73159ea71eaf496a83dd108e719e54831b8d/examples/xr.xml",
        "-o",
        xml_rel,
    };

    std.log.info("Downloading xr.xml into {s}", .{xml_rel});

    var child = std.process.Child.init(&argv, b.allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = child.spawnAndWait() catch |err| {
        std.debug.print("error: failed to spawn curl for xr.xml: {s}\n", .{@errorName(err)});
        @panic("curl not available or failed to start");
    };

    switch (term) {
        .Exited => |code| if (code != 0) {
            std.debug.print(
                "error: curl (xr.xml) exited with code {d}\n" ++
                    "hint: if this is a TLS / schannel issue on Windows, you can:\n" ++
                    "  - Manually fetch:\n" ++
                    "      https://raw.githubusercontent.com/zigadel/openxr-zig/ef4d73159ea71eaf496a83dd108e719e54831b8d/examples/xr.xml\n" ++
                    "    and save it as ./registry/xr.xml\n",
                .{code},
            );
            @panic("failed to download xr.xml");
        },
        else => {
            std.debug.print("error: curl (xr.xml) terminated abnormally: {any}\n", .{term});
            @panic("failed to download xr.xml");
        },
    }

    if (cwd.openFile(xml_rel, .{})) |file2| {
        file2.close();
    } else |err| {
        std.debug.print("error: xr.xml download seems to have succeeded, but cannot reopen {s}: {s}\n", .{
            xml_rel,
            @errorName(err),
        });
        @panic("xr.xml missing after download");
    }

    std.log.info("Successfully downloaded xr.xml into {s}", .{xml_rel});
    return b.path(xml_rel);
}

/// Helper: add a zig test for a module and wrap it in a run step.
fn addTestRun(b: *std.Build, root_mod: *std.Build.Module) *std.Build.Step.Run {
    const t = b.addTest(.{ .root_module = root_mod });
    return b.addRunArtifact(t);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vk_registry = ensureVkRegistry(b);
    const xr_registry = ensureXrRegistry(b);

    // ─────────────────────────────────────────────────────────────────────
    // Dependencies
    // ─────────────────────────────────────────────────────────────────────

    const glfw_dep = b.dependency("glfw_zig", .{
        .target = target,
        .optimize = optimize,
    });
    const glfw_mod = glfw_dep.module("glfw");
    const glfw_lib = glfw_dep.artifact("glfw-zig");

    const vk_dep = b.dependency("vulkan", .{
        .target = target,
        .optimize = optimize,
        .registry = vk_registry,
    });
    const vk_mod = vk_dep.module("vulkan-zig");

    const xr_dep = b.dependency("openxr", .{
        .target = target,
        .optimize = optimize,
    });
    const xr_gen_exe = xr_dep.artifact("openxr-zig-generator");

    const xr_gen_cmd = b.addRunArtifact(xr_gen_exe);
    xr_gen_cmd.addFileArg(xr_registry);
    const xr_zig = xr_gen_cmd.addOutputFileArg("xr.zig");

    const xr_mod = b.createModule(.{
        .root_source_file = xr_zig,
        .target = target,
        .optimize = optimize,
    });

    // ─────────────────────────────────────────────────────────────────────
    // Internal modules (ZTable-style wiring)
    // ─────────────────────────────────────────────────────────────────────

    const vertex_mod = b.createModule(.{
        .root_source_file = b.path("src/graphics/vertex.zig"),
        .target = target,
        .optimize = optimize,
    });
    vertex_mod.addImport("vulkan", vk_mod);

    const graphics_context_mod = b.createModule(.{
        .root_source_file = b.path("src/graphics/graphics_context.zig"),
        .target = target,
        .optimize = optimize,
    });
    graphics_context_mod.addImport("glfw", glfw_mod);
    graphics_context_mod.addImport("vulkan", vk_mod);
    graphics_context_mod.addImport("openxr", xr_mod);
    graphics_context_mod.addImport("vertex", vertex_mod);

    const swapchain_mod = b.createModule(.{
        .root_source_file = b.path("src/graphics/swapchain.zig"),
        .target = target,
        .optimize = optimize,
    });
    swapchain_mod.addImport("vulkan", vk_mod);
    swapchain_mod.addImport("graphics_context", graphics_context_mod);
    swapchain_mod.addImport("vertex", vertex_mod);

    // ✅ THIS is the important fix: point to src/game/frame_time.zig.
    const frame_time_mod = b.createModule(.{
        .root_source_file = b.path("src/game/frame_time.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Facade module (src/root.zig), exported as "vrgame".
    const vrgame_root = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    vrgame_root.addImport("graphics_context", graphics_context_mod);
    vrgame_root.addImport("swapchain", swapchain_mod);
    vrgame_root.addImport("vertex", vertex_mod);
    vrgame_root.addImport("frame_time", frame_time_mod);

    // Root module for executable (src/main.zig).
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("glfw", glfw_mod);
    exe_mod.addImport("vulkan", vk_mod);
    exe_mod.addImport("openxr", xr_mod);
    exe_mod.addImport("graphics_context", graphics_context_mod);
    exe_mod.addImport("swapchain", swapchain_mod);
    exe_mod.addImport("vertex", vertex_mod);
    exe_mod.addImport("frame_time", frame_time_mod);
    exe_mod.addImport("vrgame", vrgame_root);

    // ─────────────────────────────────────────────────────────────────────
    // Shader compilation (glslc → SPIR-V → @embedFile)
    // ─────────────────────────────────────────────────────────────────────

    const compile_vert_shader = b.addSystemCommand(&.{"glslc"});
    compile_vert_shader.addFileArg(b.path("shaders/triangle.vert"));
    compile_vert_shader.addArgs(&.{ "--target-env=vulkan1.1", "-o" });
    const triangle_vert_spv = compile_vert_shader.addOutputFileArg("triangle_vert.spv");
    exe_mod.addAnonymousImport("triangle_vert", .{
        .root_source_file = triangle_vert_spv,
    });

    const compile_frag_shader = b.addSystemCommand(&.{"glslc"});
    compile_frag_shader.addFileArg(b.path("shaders/triangle.frag"));
    compile_frag_shader.addArgs(&.{ "--target-env=vulkan1.1", "-o" });
    const triangle_frag_spv = compile_frag_shader.addOutputFileArg("triangle_frag.spv");
    exe_mod.addAnonymousImport("triangle_frag", .{
        .root_source_file = triangle_frag_spv,
    });

    // ─────────────────────────────────────────────────────────────────────
    // Executable + run step
    // ─────────────────────────────────────────────────────────────────────

    const exe = b.addExecutable(.{
        .name = "vrgame",
        .root_module = exe_mod,
    });

    exe.step.dependOn(&xr_gen_cmd.step);
    exe.linkLibrary(glfw_lib);
    linkVulkanLoader(exe, target, b);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the Vulkan + OpenXR triangle demo");
    run_step.dependOn(&run_cmd.step);

    // ─────────────────────────────────────────────────────────────────────
    // Tests – per-module (no test_all_unit.zig)
    // ─────────────────────────────────────────────────────────────────────

    const unit_step = b.step("test-unit", "Run unit tests (vrgame modules)");
    const integration_step = b.step("test-integration", "Run integration tests");
    const e2e_step = b.step("test-e2e", "Run end-to-end tests");

    const run_main_tests = addTestRun(b, exe_mod);
    const run_graphics_context_tests = addTestRun(b, graphics_context_mod);
    const run_swapchain_tests = addTestRun(b, swapchain_mod);
    const run_vertex_tests = addTestRun(b, vertex_mod);
    const run_frame_time_tests = addTestRun(b, frame_time_mod);

    unit_step.dependOn(&run_main_tests.step);
    unit_step.dependOn(&run_graphics_context_tests.step);
    unit_step.dependOn(&run_swapchain_tests.step);
    unit_step.dependOn(&run_vertex_tests.step);
    unit_step.dependOn(&run_frame_time_tests.step);

    // Optional integration aggregator: tests/test_all_integration.zig
    const have_integration = blk: {
        _ = std.fs.cwd().statFile("tests/test_all_integration.zig") catch break :blk false;
        break :blk true;
    };
    if (have_integration) {
        const integration_mod = b.createModule(.{
            .root_source_file = b.path("tests/test_all_integration.zig"),
            .target = target,
            .optimize = optimize,
        });
        integration_mod.addImport("glfw", glfw_mod);
        integration_mod.addImport("vulkan", vk_mod);
        integration_mod.addImport("openxr", xr_mod);
        integration_mod.addImport("graphics_context", graphics_context_mod);
        integration_mod.addImport("swapchain", swapchain_mod);
        integration_mod.addImport("vertex", vertex_mod);
        integration_mod.addImport("frame_time", frame_time_mod);
        integration_mod.addImport("vrgame", vrgame_root);

        const integration_tests = b.addTest(.{ .root_module = integration_mod });
        const run_integration = b.addRunArtifact(integration_tests);
        integration_step.dependOn(&run_integration.step);
    }

    // Optional e2e aggregator: tests/test_all_e2e.zig
    const have_e2e = blk: {
        _ = std.fs.cwd().statFile("tests/test_all_e2e.zig") catch break :blk false;
        break :blk true;
    };
    if (have_e2e) {
        const e2e_mod = b.createModule(.{
            .root_source_file = b.path("tests/test_all_e2e.zig"),
            .target = target,
            .optimize = optimize,
        });
        e2e_mod.addImport("glfw", glfw_mod);
        e2e_mod.addImport("vulkan", vk_mod);
        e2e_mod.addImport("openxr", xr_mod);
        e2e_mod.addImport("graphics_context", graphics_context_mod);
        e2e_mod.addImport("swapchain", swapchain_mod);
        e2e_mod.addImport("vertex", vertex_mod);
        e2e_mod.addImport("frame_time", frame_time_mod);
        e2e_mod.addImport("vrgame", vrgame_root);

        const e2e_tests = b.addTest(.{ .root_module = e2e_mod });
        const run_e2e = b.addRunArtifact(e2e_tests);
        e2e_step.dependOn(&run_e2e.step);
    }

    const test_all_step = b.step(
        "test-all",
        "Build vrgame and run unit + integration + e2e tests",
    );
    test_all_step.dependOn(b.getInstallStep());
    test_all_step.dependOn(unit_step);
    test_all_step.dependOn(integration_step);
    test_all_step.dependOn(e2e_step);

    const test_step = b.step("test", "Alias for test-all");
    test_step.dependOn(test_all_step);

    b.default_step = test_all_step;
}
