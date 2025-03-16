const std = @import("std");
const builtin = @import("builtin");
const Build = std.Build;
const OptimizeMode = std.builtin.OptimizeMode;

pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const optimize = b.standardOptimizeOption(.{});

    const emsdk = b.dependency("emsdk", .{});

    if (!target.result.cpu.arch.isWasm()) {
        const exe = b.addExecutable(.{
            .name = "toolbox_tests",
            .root_source_file = b.path(
                "src/main.zig",
            ),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = true,
        });
        exe.linkLibC();
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step("run", "Run the app");
        run_step.dependOn(&run_cmd.step);
    } else {
        // for WASM, need to build the Zig code as static library, since linking happens via emcc
        const wasm_target = b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .cpu_model = .{ .explicit = &std.Target.wasm.cpu.mvp },
            .cpu_features_add = std.Target.wasm.featureSet(&.{
                .atomics,
                .bulk_memory,
            }),
            .os_tag = .emscripten,
        });
        const wasm_exe = b.addStaticLibrary(.{
            .name = "toolbox_tests",
            .root_source_file = b.path("src/main.zig"),
            .target = wasm_target,
            .optimize = optimize,
        });
        wasm_exe.linkLibC();

        wasm_exe.root_module.single_threaded = false;
        wasm_exe.shared_memory = true;

        // create a special emcc linker run step
        const link_step = try emLinkStep(b, .{
            .lib_main = wasm_exe,
            .target = target,
            .optimize = optimize,
            .emsdk = emsdk,
            .use_emmalloc = true,
            .use_filesystem = false,
            .shell_file_path = null, //b.path("src/sokol/web/shell.html"),
            .extra_args = &.{ "-sSTACK_SIZE=512KB", "-sASSERTIONS" },
        });
        // ...and a special run step to run the build result via emrun
        const run_cmd = emRunStep(
            b,
            .{ .name = "toolbox_tests", .emsdk = emsdk },
        );
        run_cmd.step.dependOn(&link_step.step);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        const run_step = b.step("run", "Run the app");
        run_step.dependOn(&run_cmd.step);
    }
    //clean step
    {
        const clean_step = b.step("clean", "Clean all artifacts");
        const rm_zig_cache = b.addRemoveDirTree(b.path("zig-cache"));
        clean_step.dependOn(&rm_zig_cache.step);
        const rm_dot_zig_cache = b.addRemoveDirTree(b.path(".zig-cache"));
        clean_step.dependOn(&rm_dot_zig_cache.step);
        const rm_zig_out = b.addRemoveDirTree(b.path("zig-out"));
        clean_step.dependOn(&rm_zig_out.step);
    }
}

// for wasm32-emscripten, need to run the Emscripten linker from the Emscripten SDK
// NOTE: ideally this would go into a separate emsdk-zig package
pub const EmLinkOptions = struct {
    target: Build.ResolvedTarget,
    optimize: OptimizeMode,
    lib_main: *Build.Step.Compile, // the actual Zig code must be compiled to a static link library
    emsdk: *Build.Dependency,
    release_use_closure: bool = true,
    release_use_lto: bool = true,
    use_emmalloc: bool = false,
    use_filesystem: bool = true,
    shell_file_path: ?Build.LazyPath,
    extra_args: []const []const u8 = &.{},
};
pub fn emLinkStep(b: *Build, options: EmLinkOptions) !*Build.Step.InstallDir {
    const emcc_path = emSdkLazyPath(b, options.emsdk, &.{ "upstream", "emscripten", "emcc" }).getPath(b);
    const emcc = b.addSystemCommand(&.{emcc_path});
    emcc.setName("emcc"); // hide emcc path
    if (options.optimize == .Debug) {
        emcc.addArgs(&.{ "-O0", "-gsource-map", "-sSAFE_HEAP=0", "-sSTACK_OVERFLOW_CHECK=1", "-sUSE_OFFSET_CONVERTER=1" });
    } else {
        emcc.addArg("-sASSERTIONS=0");
        if (options.optimize == .ReleaseSmall) {
            emcc.addArg("-Oz");
        } else {
            emcc.addArg("-O3");
        }
        if (options.release_use_lto) {
            emcc.addArg("-flto");
        }
        if (options.release_use_closure) {
            emcc.addArgs(&.{ "--closure", "1" });
        }
    }
    emcc.addArgs(&.{
        "-pthread",
        "-sASYNCIFY",
        "-sPTHREAD_POOL_SIZE=16",
        "-sINITIAL_MEMORY=2147483648",
        //"-sALLOW_MEMORY_GROWTH",
        "-sUSE_OFFSET_CONVERTER",
        "-lwebsocket.js",
        "-sPROXY_POSIX_SOCKETS",
        "-sASSERTIONS",
        // "-sFORCE_FILESYSTEM",
        //"-sPROXY_TO_PTHREAD",
    });
    if (!options.use_filesystem) {
        emcc.addArg("-sNO_FILESYSTEM=1");
    }
    if (options.use_emmalloc) {
        emcc.addArg("-sMALLOC='emmalloc'");
    }
    if (options.shell_file_path) |shell_file_path| {
        emcc.addPrefixedFileArg("--shell-file=", shell_file_path);
    }
    for (options.extra_args) |arg| {
        emcc.addArg(arg);
    }

    // add the main lib, and then scan for library dependencies and add those too
    emcc.addArtifactArg(options.lib_main);

    // for (options.lib_main.getCompileDependencies(false)) |item| {
    //     if (item.kind == .lib) {
    //         emcc.addArtifactArg(item);
    //     }
    // }
    emcc.addArg("-o");
    const out_file = emcc.addOutputFileArg(b.fmt("{s}.html", .{options.lib_main.name}));

    // the emcc linker creates 3 output files (.html, .wasm and .js)
    const install = b.addInstallDirectory(.{
        .source_dir = out_file.dirname(),
        .install_dir = .prefix,
        .install_subdir = "web",
    });
    install.step.dependOn(&emcc.step);

    // get the emcc step to run on 'zig build'
    b.getInstallStep().dependOn(&install.step);
    return install;
}

// build a run step which uses the emsdk emrun command to run a build target in the browser
// NOTE: ideally this would go into a separate emsdk-zig package
pub const EmRunOptions = struct {
    name: []const u8,
    emsdk: *Build.Dependency,
};
pub fn emRunStep(b: *Build, options: EmRunOptions) *Build.Step.Run {
    const emrun_path = b.findProgram(&.{"emrun"}, &.{}) catch emSdkLazyPath(b, options.emsdk, &.{ "upstream", "emscripten", "emrun" }).getPath(b);
    const emrun = b.addSystemCommand(&.{ emrun_path, b.fmt("{s}/web/{s}.html", .{ b.install_path, options.name }) });
    return emrun;
}

// helper function to build a LazyPath from the emsdk root and provided path components
fn emSdkLazyPath(b: *Build, emsdk: *Build.Dependency, subPaths: []const []const u8) Build.LazyPath {
    return emsdk.path(b.pathJoin(subPaths));
}
