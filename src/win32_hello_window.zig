//! Etapa 2 (part 1): a native Win32 window with a working OpenGL (WGL) context.
//!
//! This is the foundation of a future `src/apprt/windows/`: it proves we can
//! create a real top-level window on Windows 11 and drive the GPU through the
//! OpenGL backend that Ghostty already uses on Linux/Windows. It does NOT yet
//! render any terminal content or wire into Ghostty's renderer — it just opens
//! a window and clears it to a slowly pulsing color so you can SEE that:
//!
//!   * a Win32 window opens and pumps the message loop (input plumbing later)
//!   * a legacy WGL OpenGL context is created and made current
//!   * glClear + SwapBuffers present frames (double-buffered)
//!   * the window resizes (glViewport tracks WM_SIZE)
//!
//! Press ESC or close the window to quit.
//!
//! Build (cross-compiled from WSL):
//!   zig build-exe src/win32_hello_window.zig -target x86_64-windows-gnu \
//!     -O ReleaseSafe -lopengl32 -lgdi32 -luser32 -lkernel32 \
//!     -femit-bin=zig-out/win/ghostty-win32-hello.exe
//!
//! NOTE: this is a standalone harness, not part of the app yet. The next step
//! is to lift this into the apprt abstraction and host Ghostty's renderer.

const std = @import("std");
const builtin = @import("builtin");
const w = std.os.windows;

comptime {
    // Allow test builds on any host so the pure-logic tests below can run
    // on the Linux/WSL dev machine; the runnable binary is Windows-only.
    if (builtin.os.tag != .windows and !builtin.is_test)
        @compileError("win32_hello_window only builds for Windows targets");
}

const HGLRC = w.HANDLE;
const WPARAM = usize;
const LPARAM = isize;
const LRESULT = isize;
const LPCWSTR = [*:0]const u16;

// --- window class / style / message constants ---
const CS_VREDRAW: u32 = 0x0001;
const CS_HREDRAW: u32 = 0x0002;
const CS_OWNDC: u32 = 0x0020;
const WS_OVERLAPPEDWINDOW: u32 = 0x00CF0000;
const WS_VISIBLE: u32 = 0x10000000;
const SW_SHOW: i32 = 5;
const CW_USEDEFAULT: i32 = -2147483648;
const PM_REMOVE: u32 = 0x0001;
const WM_DESTROY: u32 = 0x0002;
const WM_SIZE: u32 = 0x0005;
const WM_CLOSE: u32 = 0x0010;
const WM_QUIT: u32 = 0x0012;
const WM_KEYDOWN: u32 = 0x0100;
const VK_ESCAPE: WPARAM = 0x1B;
const IDC_ARROW: LPCWSTR = @ptrFromInt(32512);

// --- pixel format / GL constants ---
const PFD_DOUBLEBUFFER: u32 = 0x00000001;
const PFD_DRAW_TO_WINDOW: u32 = 0x00000004;
const PFD_SUPPORT_OPENGL: u32 = 0x00000020;
const PFD_TYPE_RGBA: u8 = 0;
const PFD_MAIN_PLANE: u8 = 0;
const GL_COLOR_BUFFER_BIT: u32 = 0x00004000;

const POINT = extern struct { x: i32, y: i32 };

const MSG = extern struct {
    hwnd: ?w.HWND,
    message: u32,
    wParam: WPARAM,
    lParam: LPARAM,
    time: u32,
    pt: POINT,
    lPrivate: u32,
};

const WNDCLASSEXW = extern struct {
    cbSize: u32,
    style: u32,
    lpfnWndProc: *const fn (w.HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT,
    cbClsExtra: i32,
    cbWndExtra: i32,
    hInstance: w.HINSTANCE,
    hIcon: ?w.HANDLE,
    hCursor: ?w.HANDLE,
    hbrBackground: ?w.HANDLE,
    lpszMenuName: ?LPCWSTR,
    lpszClassName: LPCWSTR,
    hIconSm: ?w.HANDLE,
};

const PIXELFORMATDESCRIPTOR = extern struct {
    nSize: u16,
    nVersion: u16,
    dwFlags: u32,
    iPixelType: u8,
    cColorBits: u8,
    cRedBits: u8,
    cRedShift: u8,
    cGreenBits: u8,
    cGreenShift: u8,
    cBlueBits: u8,
    cBlueShift: u8,
    cAlphaBits: u8,
    cAlphaShift: u8,
    cAccumBits: u8,
    cAccumRedBits: u8,
    cAccumGreenBits: u8,
    cAccumBlueBits: u8,
    cAccumAlphaBits: u8,
    cDepthBits: u8,
    cStencilBits: u8,
    cAuxBuffers: u8,
    iLayerType: u8,
    bReserved: u8,
    dwLayerMask: u32,
    dwVisibleMask: u32,
    dwDamageMask: u32,
};

extern "kernel32" fn GetModuleHandleW(?LPCWSTR) callconv(.winapi) w.HINSTANCE;
extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.winapi) u16;
extern "user32" fn CreateWindowExW(dwExStyle: u32, lpClassName: LPCWSTR, lpWindowName: LPCWSTR, dwStyle: u32, X: i32, Y: i32, nWidth: i32, nHeight: i32, hWndParent: ?w.HWND, hMenu: ?w.HANDLE, hInstance: w.HINSTANCE, lpParam: ?*anyopaque) callconv(.winapi) ?w.HWND;
extern "user32" fn DefWindowProcW(w.HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn ShowWindow(w.HWND, i32) callconv(.winapi) w.BOOL;
extern "user32" fn UpdateWindow(w.HWND) callconv(.winapi) w.BOOL;
extern "user32" fn PeekMessageW(*MSG, ?w.HWND, u32, u32, u32) callconv(.winapi) w.BOOL;
extern "user32" fn TranslateMessage(*const MSG) callconv(.winapi) w.BOOL;
extern "user32" fn DispatchMessageW(*const MSG) callconv(.winapi) LRESULT;
extern "user32" fn PostQuitMessage(i32) callconv(.winapi) void;
extern "user32" fn GetDC(?w.HWND) callconv(.winapi) ?w.HDC;
extern "user32" fn DestroyWindow(w.HWND) callconv(.winapi) w.BOOL;
extern "user32" fn LoadCursorW(?w.HINSTANCE, LPCWSTR) callconv(.winapi) ?w.HANDLE;
extern "gdi32" fn ChoosePixelFormat(w.HDC, *const PIXELFORMATDESCRIPTOR) callconv(.winapi) i32;
extern "gdi32" fn SetPixelFormat(w.HDC, i32, *const PIXELFORMATDESCRIPTOR) callconv(.winapi) w.BOOL;
extern "gdi32" fn SwapBuffers(w.HDC) callconv(.winapi) w.BOOL;
extern "opengl32" fn wglCreateContext(w.HDC) callconv(.winapi) ?HGLRC;
extern "opengl32" fn wglMakeCurrent(w.HDC, ?HGLRC) callconv(.winapi) w.BOOL;
extern "opengl32" fn wglDeleteContext(HGLRC) callconv(.winapi) w.BOOL;
extern "opengl32" fn glClearColor(r: f32, g: f32, b: f32, a: f32) callconv(.winapi) void;
extern "opengl32" fn glClear(mask: u32) callconv(.winapi) void;
extern "opengl32" fn glViewport(x: i32, y: i32, width: i32, height: i32) callconv(.winapi) void;

/// Extract the low 16 bits of an LPARAM (e.g. WM_SIZE width).
fn loWord(l: LPARAM) i32 {
    return @intCast(l & 0xFFFF);
}

/// Extract the high 16 bits of an LPARAM (e.g. WM_SIZE height).
fn hiWord(l: LPARAM) i32 {
    return @intCast((l >> 16) & 0xFFFF);
}

/// Compute a smoothly pulsing RGB clear color for time `t`. Each channel is
/// a phase-shifted sine mapped into [0, 1].
fn pulseColor(t: f32) [3]f32 {
    return .{
        0.5 + 0.5 * std.math.sin(t),
        0.5 + 0.5 * std.math.sin(t + 2.094),
        0.5 + 0.5 * std.math.sin(t + 4.188),
    };
}

fn wndProc(hwnd: w.HWND, msg: u32, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT {
    switch (msg) {
        WM_SIZE => {
            // low word = width, high word = height
            glViewport(0, 0, loWord(lParam), hiWord(lParam));
            return 0;
        },
        WM_KEYDOWN => {
            if (wParam == VK_ESCAPE) _ = DestroyWindow(hwnd);
            return 0;
        },
        WM_CLOSE => {
            _ = DestroyWindow(hwnd);
            return 0;
        },
        WM_DESTROY => {
            PostQuitMessage(0);
            return 0;
        },
        else => return DefWindowProcW(hwnd, msg, wParam, lParam),
    }
}

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyWinHello");
const title = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty Windows — Etapa 2: Win32 + OpenGL");

pub fn main() !void {
    const hInstance = GetModuleHandleW(null);

    var wc = std.mem.zeroes(WNDCLASSEXW);
    wc.cbSize = @sizeOf(WNDCLASSEXW);
    wc.style = CS_OWNDC | CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = &wndProc;
    wc.hInstance = hInstance;
    wc.hCursor = LoadCursorW(null, IDC_ARROW);
    wc.lpszClassName = class_name;
    if (RegisterClassExW(&wc) == 0) return error.RegisterClassFailed;

    const hwnd = CreateWindowExW(
        0,
        class_name,
        title,
        WS_OVERLAPPEDWINDOW | WS_VISIBLE,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        960,
        600,
        null,
        null,
        hInstance,
        null,
    ) orelse return error.CreateWindowFailed;

    const hdc = GetDC(hwnd) orelse return error.GetDCFailed;

    // Choose and set a double-buffered RGBA pixel format.
    var pfd = std.mem.zeroes(PIXELFORMATDESCRIPTOR);
    pfd.nSize = @sizeOf(PIXELFORMATDESCRIPTOR);
    pfd.nVersion = 1;
    pfd.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER;
    pfd.iPixelType = PFD_TYPE_RGBA;
    pfd.cColorBits = 32;
    pfd.cDepthBits = 24;
    pfd.iLayerType = PFD_MAIN_PLANE;

    const pf = ChoosePixelFormat(hdc, &pfd);
    if (pf == 0) return error.ChoosePixelFormatFailed;
    if (SetPixelFormat(hdc, pf, &pfd) == 0) return error.SetPixelFormatFailed;

    const glrc = wglCreateContext(hdc) orelse return error.CreateGLContextFailed;
    defer _ = wglDeleteContext(glrc);
    if (wglMakeCurrent(hdc, glrc) == 0) return error.MakeCurrentFailed;
    defer _ = wglMakeCurrent(hdc, null);

    _ = ShowWindow(hwnd, SW_SHOW);
    _ = UpdateWindow(hwnd);

    // Render loop: pump messages, draw a pulsing clear color, present.
    var running = true;
    var t: f32 = 0;
    while (running) {
        var msg: MSG = undefined;
        while (PeekMessageW(&msg, null, 0, 0, PM_REMOVE) != 0) {
            if (msg.message == WM_QUIT) {
                running = false;
                break;
            }
            _ = TranslateMessage(&msg);
            _ = DispatchMessageW(&msg);
        }
        if (!running) break;

        t += 0.02;
        const c = pulseColor(t);
        glClearColor(c[0], c[1], c[2], 1.0);
        glClear(GL_COLOR_BUFFER_BIT);
        _ = SwapBuffers(hdc);

        std.Thread.sleep(16 * std.time.ns_per_ms);
    }
}

test "loWord/hiWord extract width and height from a WM_SIZE lParam" {
    const testing = std.testing;
    // WM_SIZE packs height in the high word and width in the low word.
    const lparam: LPARAM = (@as(LPARAM, 480) << 16) | 640;
    try testing.expectEqual(@as(i32, 640), loWord(lparam));
    try testing.expectEqual(@as(i32, 480), hiWord(lparam));
}

test "loWord/hiWord handle the maximum 16-bit values" {
    const testing = std.testing;
    const lparam: LPARAM = (@as(LPARAM, 0xFFFF) << 16) | 0xFFFF;
    try testing.expectEqual(@as(i32, 0xFFFF), loWord(lparam));
    try testing.expectEqual(@as(i32, 0xFFFF), hiWord(lparam));
}

test "pulseColor channels stay within [0, 1]" {
    const testing = std.testing;
    var t: f32 = 0;
    while (t < 12.0) : (t += 0.13) {
        for (pulseColor(t)) |ch| {
            try testing.expect(ch >= 0.0);
            try testing.expect(ch <= 1.0);
        }
    }
}
