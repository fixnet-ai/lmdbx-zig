const std = @import("std");

pub fn build(b: *std.Build) void {
    var target = b.standardTargetOptions(.{});

    const enable_mdbx_debug = b.option(bool, "mdbx-debug", "Compile libmdbx with MDBX_DEBUG=2 (verbose runtime asserts and logs)") orelse false;

    // For Linux GNU targets, always target glibc 2.31 for broad compatibility
    if (target.result.os.tag == .linux and target.result.abi == .gnu) {
        target = b.resolveTargetQuery(.{
            .cpu_arch = target.result.cpu.arch,
            .os_tag = .linux,
            .abi = .gnu,
            .os_version_min = .{ .semver = std.SemanticVersion{ .major = 2, .minor = 31, .patch = 0 } },
            .glibc_version = std.SemanticVersion{ .major = 2, .minor = 31, .patch = 0 },
        });
    }

    const mdbx = b.addModule("lmdbx", .{ .root_source_file = b.path("src/lib.zig") });

    // Add CPU features polyfill
    const cpuf_dep = b.dependency("cpu_features", .{});
    mdbx.addIncludePath(cpuf_dep.path("cpu_model"));

    // Android (Bionic) 交叉编译：zig 0.16.0 不内置 Bionic，C 源（mdbx.c → inttypes.h、
    // cpu_model/aarch64.c → aarch64/lse_atomics/android.inc → string.h）缺系统头会编译失败。
    // sysroot 来源优先级：
    //   1) b.sysroot（上游 -Dsysroot 经依赖链传播，zigfoundation 消费者已实证）
    //   2) ANDROID_NDK_HOME 环境变量（与 zigprebuild/build.zig findNdkSysroot 同模式，
    //      使本仓可独立 `zig build -Dtarget=*-linux-android`）
    if (target.result.os.tag == .linux and target.result.abi == .android) {
        const sysroot = b.sysroot orelse findNdkSysroot(b);
        if (sysroot) |s| {
            // 系统头必须 -isystem（排在 zig 内置头之后），mdbx.c 的
            // #include_next <inttypes.h> 才能落到 NDK 的同名头。
            mdbx.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ s, "usr", "include" }) });
            mdbx.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{
                s, "usr", "include", b.fmt("{s}-linux-android", .{@tagName(target.result.cpu.arch)}),
            }) });
        } else {
            std.log.warn("android target: NDK sysroot not found (set ANDROID_NDK_HOME or -Dsysroot); mdbx C sources will fail to compile", .{});
        }
    }

    if (target.result.cpu.arch == .x86_64 or target.result.cpu.arch == .aarch64) {
        mdbx.addCSourceFile(.{ .file = switch (target.result.cpu.arch) {
            .x86_64 => cpuf_dep.path("cpu_model/x86.c"),
            .aarch64 => cpuf_dep.path("cpu_model/aarch64.c"),
            else => unreachable,
        }, .flags = &.{} });
    }

    // libMDBX
    const mdbx_dep = b.dependency("mdbx", .{});
    mdbx.addIncludePath(mdbx_dep.path("."));

    // Add headers needed to compile
    mdbx.addIncludePath(b.path("src/headers"));

    // mdbx.c is amalgated source code
    mdbx.addCSourceFile(.{
        .file = mdbx_dep.path("mdbx.c"),
        .flags = &[_][]const u8{
            "-std=gnu11",
            "-O2",
            "-g",
            "-ffunction-sections",
            "-fvisibility=hidden",
            "-pthread",
            "-Wno-error=attributes",
            "-fno-semantic-interposition",
            "-Wno-unused-command-line-argument",
            "-Wno-tautological-compare",
            "-Wno-date-time",
            "-ULIBMDBX_EXPORTS",

            // Debug features
            // MDBX_DEBUG=-1 makes LOG_ENABLED() compile to (0), removing all
            // runtime log call sites entirely (incl. NOTICE chatter on stderr).
            if (enable_mdbx_debug) "-DMDBX_DEBUG=2" else "-DMDBX_DEBUG=-1",
            if (enable_mdbx_debug) "-DMDBX_BUILD_FLAGS=\"UNDEBUG\"" else "-DMDBX_BUILD_FLAGS=\"DNDEBUG=1\"",

            // Fix for LLVM 19+ requiring evex512 for AVX-512 512-bit intrinsics (Zig 0.13+)
            // See: https://github.com/ziglang/zig/issues/20414
            if (target.result.cpu.arch == .x86_64) "-includemdbx_avx512_fix.h" else "",

            // Cross compilation to windows breaks without "errno.h"
            if (target.result.os.tag == .windows) "-includeerrno.h" else "",

            // We don't link with MSVC CRT
            if (target.result.os.tag == .windows) "-DMDBX_WITHOUT_MSVC_CRT=1" else "",

            // FreeBSD: mdbx-internals.h sets _XOPEN_SOURCE=0 which disables
            // __XSI_VISIBLE → S_IFMT/S_IFBLK/S_IFREG/_SC_PAGE_SIZE hidden.
            // Predefine _XOPEN_SOURCE=600 so mdbx skips its redefinition.
            // ENODATA is Linux-specific errno not defined on BSD.
            if (target.result.os.tag == .freebsd) "-D_XOPEN_SOURCE=600" else "",
            if (target.result.os.tag == .freebsd) "-D__BSD_VISIBLE" else "",
            if (target.result.os.tag == .freebsd) "-DENODATA=61" else "",

            // Link libraries
            switch (target.result.os.tag) {
                .windows => "-lm -lntdll -lwinmm -luser32 -lkernel32 -ladvapi32 -lole32",
                .macos, .openbsd => "-lm",
                else => "-lm -lrt",
            },
        },
    });

    mdbx.pic = true; // Enforce PIC
    mdbx.sanitize_c = .off; // Address sanitization breaks libMDBX
}

/// 从 ANDROID_NDK_HOME 定位 NDK sysroot（$NDK/toolchains/llvm/prebuilt/<host>/sysroot）。
/// 返回 null 表示未设置 ANDROID_NDK_HOME 或找不到 prebuilt 目录。
fn findNdkSysroot(b: *std.Build) ?[]const u8 {
    const ndk_home = b.graph.environ_map.get("ANDROID_NDK_HOME") orelse return null;
    const prebuilt = b.pathJoin(&.{ ndk_home, "toolchains", "llvm", "prebuilt" });
    var dir = std.Io.Dir.openDirAbsolute(b.graph.io, prebuilt, .{ .iterate = true }) catch return null;
    defer dir.close(b.graph.io);
    var it = dir.iterate();
    while (it.next(b.graph.io) catch return null) |entry| {
        if (entry.kind == .directory) {
            return b.pathJoin(&.{ prebuilt, entry.name, "sysroot" });
        }
    }
    return null;
}
