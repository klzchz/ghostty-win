//! Headless ConPTY proof-of-engine harness for Ghostty on Windows.
//!
//! This program is NOT part of the Ghostty app. It exists to empirically
//! prove that Ghostty's existing Windows engine works end-to-end on a real
//! Windows machine, BEFORE we invest in the GUI (apprt) layer.
//!
//! What it reuses from the real Ghostty source tree (no copies):
//!   * `src/pty.zig`  -> the actual `WindowsPty` (CreatePseudoConsole /
//!                       ResizePseudoConsole / named-pipe plumbing).
//!   * `src/os/windows.zig` -> the actual Win32 externs (CreateProcessW,
//!                       InitializeProcThreadAttributeList, etc.).
//!
//! The process-spawn logic mirrors `Command.startWindows` (the ConPTY
//! branch). We inline it here instead of importing `Command.zig` directly
//! because `Command.zig` pulls in `apprt`/`config`/`global`, which would drag
//! half of Ghostty into this tiny tool. The spawn here is a faithful 1:1 copy
//! of that branch.
//!
//! Run it ON REAL WINDOWS (not WSL): ConPTY is a Windows-kernel feature.
//!
//!   .\ghostty-conpty-harness.exe              # launches pwsh.exe
//!   .\ghostty-conpty-harness.exe powershell.exe
//!   .\ghostty-conpty-harness.exe cmd.exe
//!   .\ghostty-conpty-harness.exe wsl.exe      # opens your Ubuntu/WSL shell
//!   .\ghostty-conpty-harness.exe "wsl.exe -d Ubuntu"
//!
//! Type normally; the child shell runs inside Ghostty's ConPTY. Type `exit`
//! (or Ctrl-D in bash) to quit.

const std = @import("std");
const builtin = @import("builtin");
const w = std.os.windows;

// The REAL Ghostty code under test:
const Pty = @import("pty.zig").Pty;
const winsize = @import("pty.zig").winsize;
const gw = @import("os/windows.zig");

comptime {
    if (builtin.os.tag != .windows)
        @compileError("conpty_harness only builds for Windows targets");
}

// --- Generic Win32 bits we need that aren't re-exported by os/windows.zig ---
const STD_INPUT_HANDLE: w.DWORD = 0xFFFFFFF6; // (DWORD)-10
const STD_OUTPUT_HANDLE: w.DWORD = 0xFFFFFFF5; // (DWORD)-11

const ENABLE_PROCESSED_INPUT: w.DWORD = 0x0001;
const ENABLE_LINE_INPUT: w.DWORD = 0x0002;
const ENABLE_ECHO_INPUT: w.DWORD = 0x0004;
const ENABLE_VIRTUAL_TERMINAL_INPUT: w.DWORD = 0x0200;
const ENABLE_PROCESSED_OUTPUT: w.DWORD = 0x0001;
const ENABLE_VIRTUAL_TERMINAL_PROCESSING: w.DWORD = 0x0004;

extern "kernel32" fn GetStdHandle(nStdHandle: w.DWORD) callconv(.winapi) w.HANDLE;
extern "kernel32" fn GetConsoleMode(hConsoleHandle: w.HANDLE, lpMode: *w.DWORD) callconv(.winapi) w.BOOL;
extern "kernel32" fn SetConsoleMode(hConsoleHandle: w.HANDLE, dwMode: w.DWORD) callconv(.winapi) w.BOOL;
extern "kernel32" fn ReadFile(hFile: w.HANDLE, lpBuffer: [*]u8, n: w.DWORD, read: *w.DWORD, ov: ?*anyopaque) callconv(.winapi) w.BOOL;
extern "kernel32" fn WriteFile(hFile: w.HANDLE, lpBuffer: [*]const u8, n: w.DWORD, written: *w.DWORD, ov: ?*anyopaque) callconv(.winapi) w.BOOL;
extern "kernel32" fn WaitForSingleObject(h: w.HANDLE, ms: w.DWORD) callconv(.winapi) w.DWORD;

fn writeAll(h: w.HANDLE, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        var written: w.DWORD = 0;
        if (WriteFile(h, bytes.ptr + off, @intCast(bytes.len - off), &written, null) == 0) return;
        if (written == 0) return;
        off += written;
    }
}

/// pty output -> our stdout. Runs until the ConPTY pipe breaks (child exit).
fn pumpOutput(out_pipe: w.HANDLE, our_stdout: w.HANDLE) void {
    var buf: [4096]u8 = undefined;
    while (true) {
        var n: w.DWORD = 0;
        if (ReadFile(out_pipe, &buf, buf.len, &n, null) == 0) return;
        if (n == 0) return;
        writeAll(our_stdout, buf[0..n]);
    }
}

/// our stdin -> pty input. Runs until stdin closes.
fn pumpInput(our_stdin: w.HANDLE, in_pipe: w.HANDLE) void {
    var buf: [4096]u8 = undefined;
    while (true) {
        var n: w.DWORD = 0;
        if (ReadFile(our_stdin, &buf, buf.len, &n, null) == 0) return;
        if (n == 0) return;
        writeAll(in_pipe, buf[0..n]);
    }
}

pub fn main() !void {
    const alloc = std.heap.page_allocator;

    const stdout = GetStdHandle(STD_OUTPUT_HANDLE);
    const stdin = GetStdHandle(STD_INPUT_HANDLE);

    // Build the command line from argv (default: pwsh.exe).
    var args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    const cmd: []const u8 = if (args.len > 1)
        try std.mem.join(alloc, " ", args[1..])
    else
        "pwsh.exe";

    {
        var b: [256]u8 = undefined;
        const banner = std.fmt.bufPrint(
            &b,
            "\r\n=== Ghostty ConPTY harness ===\r\n" ++
                "launching: {s}\r\n" ++
                "(this proves src/pty.zig WindowsPty end-to-end; type `exit` to quit)\r\n\r\n",
            .{cmd},
        ) catch "\r\n=== Ghostty ConPTY harness ===\r\n";
        writeAll(stdout, banner);
    }

    // 1) Open a real Ghostty ConPTY.
    var pty = try Pty.open(.{ .ws_row = 25, .ws_col = 80 });
    defer pty.deinit();

    // 2) Prove ResizePseudoConsole works on a live HPCON (before the child
    //    starts so we don't corrupt the VT stream). Live-on-window-resize is
    //    a TODO for the future Windows apprt.
    try pty.setSize(.{ .ws_row = 30, .ws_col = 120 });
    writeAll(stdout, "[harness] ResizePseudoConsole 80x25 -> 120x30: OK\r\n\r\n");

    // 3) Put our own console into pass-through mode so keystrokes and colors
    //    flow correctly (this is what a terminal does).
    var saved_out: w.DWORD = 0;
    var saved_in: w.DWORD = 0;
    const have_out_mode = GetConsoleMode(stdout, &saved_out) != 0;
    const have_in_mode = GetConsoleMode(stdin, &saved_in) != 0;
    if (have_out_mode)
        _ = SetConsoleMode(stdout, saved_out | ENABLE_PROCESSED_OUTPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
    if (have_in_mode)
        _ = SetConsoleMode(stdin, (saved_in & ~(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT)) | ENABLE_VIRTUAL_TERMINAL_INPUT);
    defer {
        if (have_out_mode) _ = SetConsoleMode(stdout, saved_out);
        if (have_in_mode) _ = SetConsoleMode(stdin, saved_in);
    }

    // 4) Spawn the child attached to the pseudo console.
    //    (1:1 with Command.startWindows ConPTY branch.)
    const hProcess = try spawnUnderConPty(alloc, cmd, pty.pseudo_console);

    // 5) Pump I/O on background threads.
    const t_out = try std.Thread.spawn(.{}, pumpOutput, .{ pty.out_pipe, stdout });
    const t_in = try std.Thread.spawn(.{}, pumpInput, .{ stdin, pty.in_pipe });
    t_in.detach();
    _ = t_out;

    // 6) Wait for the child to exit.
    _ = WaitForSingleObject(hProcess, w.INFINITE);

    // restore console modes via defer, then report.
    writeAll(stdout, "\r\n[harness] child exited. ConPTY proven end-to-end. \xE2\x9C\x93\r\n");
}

/// Faithful copy of Command.startWindows() ConPTY branch: attach the new
/// process to the pseudo console via PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE.
fn spawnUnderConPty(
    alloc: std.mem.Allocator,
    cmd: []const u8,
    pseudo_console: gw.exp.HPCON,
) !w.HANDLE {
    const cmd_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, cmd);

    var attr_size: w.SIZE_T = undefined;
    _ = gw.exp.kernel32.InitializeProcThreadAttributeList(null, 1, 0, &attr_size);
    const attr_buf = try alloc.alloc(u8, attr_size);
    if (gw.exp.kernel32.InitializeProcThreadAttributeList(attr_buf.ptr, 1, 0, &attr_size) == 0)
        return gw.unexpectedError(gw.kernel32.GetLastError());
    if (gw.exp.kernel32.UpdateProcThreadAttribute(
        attr_buf.ptr,
        0,
        gw.exp.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
        pseudo_console,
        @sizeOf(gw.exp.HPCON),
        null,
        null,
    ) == 0) return gw.unexpectedError(gw.kernel32.GetLastError());

    var si: gw.exp.STARTUPINFOEX = .{
        .StartupInfo = .{
            .cb = @sizeOf(gw.exp.STARTUPINFOEX),
            .hStdError = null,
            .hStdOutput = null,
            .hStdInput = null,
            .dwFlags = w.STARTF_USESTDHANDLES,
            .lpReserved = null,
            .lpDesktop = null,
            .lpTitle = null,
            .dwX = 0,
            .dwY = 0,
            .dwXSize = 0,
            .dwYSize = 0,
            .dwXCountChars = 0,
            .dwYCountChars = 0,
            .dwFillAttribute = 0,
            .wShowWindow = 0,
            .cbReserved2 = 0,
            .lpReserved2 = null,
        },
        .lpAttributeList = attr_buf.ptr,
    };

    const flags: w.DWORD = gw.exp.CREATE_UNICODE_ENVIRONMENT | gw.exp.EXTENDED_STARTUPINFO_PRESENT;

    var pi: w.PROCESS_INFORMATION = undefined;
    if (gw.exp.kernel32.CreateProcessW(
        null,
        cmd_w.ptr,
        null,
        null,
        w.TRUE,
        flags,
        null,
        null,
        @ptrCast(&si.StartupInfo),
        &pi,
    ) == 0) return gw.unexpectedError(gw.kernel32.GetLastError());

    return pi.hProcess;
}
