const std = @import("std");

pub const BOOL = c_int;
pub const BYTE = u8;
pub const WORD = u16;
pub const DWORD = u32;
pub const UINT = c_uint;
pub const INT = c_int;
pub const LONG = c_long;
pub const COLORREF = DWORD;
pub const UINT_PTR = usize;
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const LRESULT = isize;
pub const ATOM = u16;
pub const WCHAR = u16;
pub const SIZE_T = usize;

pub const HANDLE = *anyopaque;
pub const HWND = ?*anyopaque;
pub const HINSTANCE = ?*anyopaque;
pub const HGLOBAL = ?*anyopaque;
pub const HMENU = ?*anyopaque;
pub const HDC = ?*anyopaque;
pub const HBRUSH = ?*anyopaque;
pub const HFONT = ?*anyopaque;
pub const LPCWSTR = ?[*:0]const WCHAR;

pub const WINAPI: std.builtin.CallingConvention = .winapi;
pub const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(WINAPI) LRESULT;

pub const WM_DESTROY = 0x0002;
pub const WM_CLOSE = 0x0010;
pub const WM_PAINT = 0x000F;
pub const WM_ACTIVATE = 0x0006;
pub const WM_KILLFOCUS = 0x0008;
pub const WM_KEYDOWN = 0x0100;
pub const WM_CHAR = 0x0102;
pub const WM_LBUTTONDOWN = 0x0201;
pub const WM_MOUSEWHEEL = 0x020A;
pub const WM_TIMER = 0x0113;
pub const WM_HOTKEY = 0x0312;
pub const WM_CLIPBOARDUPDATE = 0x031D;
pub const WA_INACTIVE: UINT = 0;
pub const TRANSPARENT = 1;
pub const MF_BYCOMMAND: UINT = 0x00000000;
pub const SC_CLOSE: UINT = 0xF060;
pub const SW_HIDE = 0;
pub const SW_SHOW = 5;
pub const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF0000;
pub const WS_POPUP: DWORD = 0x80000000;
pub const WS_EX_NOACTIVATE: DWORD = 0x08000000;
pub const WS_EX_TOPMOST: DWORD = 0x00000008;
pub const WS_EX_APPWINDOW: DWORD = 0x00040000;
pub const WS_EX_TOOLWINDOW: DWORD = 0x00000080;
pub const CW_USEDEFAULT: INT = @bitCast(@as(u32, 0x80000000));
pub const MOD_WIN: UINT = 0x0008;
pub const MOD_CONTROL: UINT = 0x0002;
pub const MOD_SHIFT: UINT = 0x0004;
pub const MOD_ALT: UINT = 0x0001;
pub const VK_V: UINT = 0x56;
pub const VK_B: UINT = 0x42;
pub const VK_J: UINT = 0x4A;
pub const VK_K: UINT = 0x4B;
pub const VK_UP: UINT = 0x26;
pub const VK_DOWN: UINT = 0x28;
pub const VK_PRIOR: UINT = 0x21; // PageUp
pub const VK_NEXT: UINT = 0x22; // PageDown
pub const VK_RETURN: UINT = 0x0D;
pub const VK_ESCAPE: UINT = 0x1B;
pub const VK_CONTROL: UINT = 0x11;
pub const VK_MENU: UINT = 0x12;
pub const VK_LBUTTON: UINT = 0x01;
pub const VK_DELETE: UINT = 0x2E;
pub const VK_S: UINT = 0x53;
pub const VK_X: UINT = 0x58;
pub const VK_F8: UINT = 0x77;
pub const VK_F24: u16 = 0x87;
pub const WHITE_BRUSH: INT = 0;
pub const GMEM_MOVEABLE: UINT = 0x0002;
pub const GMEM_ZEROINIT: UINT = 0x0040;
pub const KEYEVENTF_KEYUP: DWORD = 0x0002;
pub const INPUT_KEYBOARD: DWORD = 1;

pub fn RGB(r: u8, g: u8, b: u8) COLORREF {
    return @as(COLORREF, r) | (@as(COLORREF, g) << 8) | (@as(COLORREF, b) << 16);
}

pub const CF_BITMAP: UINT = 2;
pub const CF_DIB: UINT = 8;
pub const CF_UNICODETEXT: UINT = 13;
pub const CF_DIBV5: UINT = 17;
pub const DIB_RGB_COLORS: UINT = 0;
pub const SRCCOPY: DWORD = 0x00CC0020;

pub const WNDCLASSEXW = extern struct {
    cbSize: UINT = @sizeOf(WNDCLASSEXW),
    style: UINT = 0,
    lpfnWndProc: WNDPROC,
    cbClsExtra: INT = 0,
    cbWndExtra: INT = 0,
    hInstance: HINSTANCE = null,
    hIcon: ?*anyopaque = null,
    hCursor: ?*anyopaque = null,
    hbrBackground: ?*anyopaque = null,
    lpszMenuName: LPCWSTR = null,
    lpszClassName: LPCWSTR = null,
    hIconSm: ?*anyopaque = null,
};

pub const RECT = extern struct {
    left: LONG = 0,
    top: LONG = 0,
    right: LONG = 0,
    bottom: LONG = 0,
};

pub const BITMAPINFOHEADER = extern struct {
    biSize: DWORD,
    biWidth: LONG,
    biHeight: LONG,
    biPlanes: WORD,
    biBitCount: WORD,
    biCompression: DWORD,
    biSizeImage: DWORD,
    biXPelsPerMeter: LONG,
    biYPelsPerMeter: LONG,
    biClrUsed: DWORD,
    biClrImportant: DWORD,
};

pub const RGBQUAD = extern struct {
    rgbBlue: BYTE,
    rgbGreen: BYTE,
    rgbRed: BYTE,
    rgbReserved: BYTE,
};

pub const BITMAPINFO = extern struct {
    bmiHeader: BITMAPINFOHEADER,
    bmiColors: [1]RGBQUAD,
};

pub const PAINTSTRUCT = extern struct {
    hdc: HDC = null,
    fErase: BOOL = 0,
    rcPaint: RECT = .{},
    fRestore: BOOL = 0,
    fIncUpdate: BOOL = 0,
    rgbReserved: [32]u8 = [_]u8{0} ** 32,
};

pub const POINT = extern struct {
    x: LONG = 0,
    y: LONG = 0,
};

pub const MSG = extern struct {
    hwnd: HWND = null,
    message: UINT = 0,
    wParam: WPARAM = 0,
    lParam: LPARAM = 0,
    time: DWORD = 0,
    pt: POINT = .{},
};

pub const KEYBDINPUT = extern struct {
    wVk: u16 = 0,
    wScan: u16 = 0,
    dwFlags: DWORD = 0,
    time: DWORD = 0,
    dwExtraInfo: usize = 0,
};

pub const MOUSEINPUT = extern struct {
    dx: LONG = 0,
    dy: LONG = 0,
    mouseData: DWORD = 0,
    dwFlags: DWORD = 0,
    time: DWORD = 0,
    dwExtraInfo: usize = 0,
};

pub const HARDWAREINPUT = extern struct {
    uMsg: DWORD = 0,
    wParamL: u16 = 0,
    wParamH: u16 = 0,
};

pub const INPUT_UNION = extern union {
    mi: MOUSEINPUT,
    ki: KEYBDINPUT,
    hi: HARDWAREINPUT,
};

pub const INPUT = extern struct {
    type: DWORD = 0,
    u: INPUT_UNION = .{ .ki = .{} },
};

pub extern "kernel32" fn GetModuleHandleW(lpModuleName: LPCWSTR) callconv(WINAPI) HINSTANCE;
pub extern "kernel32" fn GlobalLock(hMem: HGLOBAL) callconv(WINAPI) ?*anyopaque;
pub extern "kernel32" fn GlobalUnlock(hMem: HGLOBAL) callconv(WINAPI) BOOL;
pub extern "kernel32" fn GlobalSize(hMem: HGLOBAL) callconv(WINAPI) SIZE_T;
pub extern "kernel32" fn GlobalAlloc(uFlags: UINT, dwBytes: SIZE_T) callconv(WINAPI) HGLOBAL;
pub extern "kernel32" fn GetLastError() callconv(WINAPI) DWORD;

pub extern "user32" fn LoadCursorW(hInstance: HINSTANCE, lpCursorName: usize) callconv(WINAPI) ?*anyopaque;
pub const IDC_ARROW: usize = 32512;

pub extern "user32" fn RegisterClassExW(lpwcx: *const WNDCLASSEXW) callconv(WINAPI) ATOM;
pub extern "user32" fn CreateWindowExW(
    dwExStyle: DWORD,
    lpClassName: LPCWSTR,
    lpWindowName: LPCWSTR,
    dwStyle: DWORD,
    x: INT,
    y: INT,
    nWidth: INT,
    nHeight: INT,
    hWndParent: HWND,
    hMenu: HMENU,
    hInstance: HINSTANCE,
    lpParam: ?*anyopaque,
) callconv(WINAPI) HWND;
pub extern "user32" fn DefWindowProcW(hWnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(WINAPI) LRESULT;
pub extern "user32" fn GetMessageW(lpMsg: *MSG, hWnd: HWND, wMsgFilterMin: UINT, wMsgFilterMax: UINT) callconv(WINAPI) BOOL;
pub extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(WINAPI) BOOL;
pub extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(WINAPI) LRESULT;
pub extern "user32" fn PostQuitMessage(nExitCode: INT) callconv(WINAPI) void;
pub extern "user32" fn RegisterHotKey(hWnd: HWND, id: INT, fsModifiers: UINT, vk: UINT) callconv(WINAPI) BOOL;
pub extern "user32" fn UnregisterHotKey(hWnd: HWND, id: INT) callconv(WINAPI) BOOL;
pub extern "user32" fn AddClipboardFormatListener(hwnd: HWND) callconv(WINAPI) BOOL;
pub extern "user32" fn RemoveClipboardFormatListener(hwnd: HWND) callconv(WINAPI) BOOL;
pub extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: INT) callconv(WINAPI) BOOL;
pub extern "user32" fn GetSystemMenu(hWnd: HWND, bRevert: BOOL) callconv(WINAPI) HMENU;
pub extern "user32" fn DeleteMenu(hMenu: HMENU, uPosition: UINT, uFlags: UINT) callconv(WINAPI) BOOL;
pub extern "user32" fn DrawMenuBar(hWnd: HWND) callconv(WINAPI) BOOL;
pub extern "user32" fn SetForegroundWindow(hWnd: HWND) callconv(WINAPI) BOOL;
pub extern "user32" fn SetFocus(hWnd: HWND) callconv(WINAPI) HWND;
pub extern "user32" fn BringWindowToTop(hWnd: HWND) callconv(WINAPI) BOOL;
pub extern "user32" fn AttachThreadInput(idAttach: DWORD, idAttachTo: DWORD, fAttach: BOOL) callconv(WINAPI) BOOL;
pub extern "user32" fn GetWindowThreadProcessId(hWnd: HWND, lpdwProcessId: ?*DWORD) callconv(WINAPI) DWORD;
pub extern "kernel32" fn GetCurrentThreadId() callconv(WINAPI) DWORD;
pub extern "user32" fn GetForegroundWindow() callconv(WINAPI) HWND;
pub extern "user32" fn GetCursorPos(lpPoint: *POINT) callconv(WINAPI) BOOL;
pub extern "user32" fn GetWindowRect(hWnd: HWND, lpRect: *RECT) callconv(WINAPI) BOOL;
pub extern "user32" fn GetAsyncKeyState(vKey: INT) callconv(WINAPI) i16;
pub extern "user32" fn SetTimer(hWnd: HWND, nIDEvent: UINT_PTR, uElapse: UINT, lpTimerFunc: ?*const anyopaque) callconv(WINAPI) UINT_PTR;
pub extern "user32" fn KillTimer(hWnd: HWND, uIDEvent: UINT_PTR) callconv(WINAPI) BOOL;
pub extern "user32" fn IsWindowVisible(hWnd: HWND) callconv(WINAPI) BOOL;
pub extern "user32" fn InvalidateRect(hWnd: HWND, lpRect: ?*const RECT, bErase: BOOL) callconv(WINAPI) BOOL;
pub extern "user32" fn BeginPaint(hWnd: HWND, lpPaint: *PAINTSTRUCT) callconv(WINAPI) HDC;
pub extern "user32" fn EndPaint(hWnd: HWND, lpPaint: *const PAINTSTRUCT) callconv(WINAPI) BOOL;
pub extern "user32" fn GetClientRect(hWnd: HWND, lpRect: *RECT) callconv(WINAPI) BOOL;
pub extern "user32" fn FillRect(hDC: HDC, lprc: *const RECT, hbr: HBRUSH) callconv(WINAPI) INT;
pub extern "user32" fn OpenClipboard(hWndNewOwner: HWND) callconv(WINAPI) BOOL;
pub extern "user32" fn CloseClipboard() callconv(WINAPI) BOOL;
pub extern "user32" fn EmptyClipboard() callconv(WINAPI) BOOL;
pub extern "user32" fn IsClipboardFormatAvailable(format: UINT) callconv(WINAPI) BOOL;
pub extern "user32" fn GetClipboardData(uFormat: UINT) callconv(WINAPI) HGLOBAL;
pub extern "user32" fn SetClipboardData(uFormat: UINT, hMem: HGLOBAL) callconv(WINAPI) HGLOBAL;
pub extern "user32" fn SendInput(cInputs: UINT, pInputs: [*]INPUT, cbSize: INT) callconv(WINAPI) UINT;
pub extern "gdi32" fn GetStockObject(i: INT) callconv(WINAPI) ?*anyopaque;
pub extern "gdi32" fn SelectObject(hdc: HDC, h: ?*anyopaque) callconv(WINAPI) ?*anyopaque;
pub extern "gdi32" fn CreateFontW(
    cHeight: INT,
    cWidth: INT,
    cEscapement: INT,
    cOrientation: INT,
    cWeight: INT,
    bItalic: DWORD,
    bUnderline: DWORD,
    bStrikeOut: DWORD,
    iCharSet: DWORD,
    iOutPrecision: DWORD,
    iClipPrecision: DWORD,
    iQuality: DWORD,
    iPitchAndFamily: DWORD,
    pszFaceName: LPCWSTR,
) callconv(WINAPI) HFONT;
pub extern "gdi32" fn StretchDIBits(
    hdc: HDC,
    xDest: INT,
    yDest: INT,
    DestWidth: INT,
    DestHeight: INT,
    xSrc: INT,
    ySrc: INT,
    SrcWidth: INT,
    SrcHeight: INT,
    lpBits: ?*const anyopaque,
    lpbmi: *const BITMAPINFO,
    iUsage: UINT,
    rop: DWORD,
) callconv(WINAPI) INT;
pub extern "gdi32" fn SetBkMode(hdc: HDC, mode: INT) callconv(WINAPI) INT;
pub extern "gdi32" fn SetTextColor(hdc: HDC, color: COLORREF) callconv(WINAPI) COLORREF;
pub extern "gdi32" fn TextOutW(hdc: HDC, x: INT, y: INT, lpString: [*]const WCHAR, c: INT) callconv(WINAPI) BOOL;
pub extern "gdi32" fn CreateSolidBrush(color: COLORREF) callconv(WINAPI) HBRUSH;
pub extern "gdi32" fn DeleteObject(ho: ?*anyopaque) callconv(WINAPI) BOOL;
pub extern "dwmapi" fn DwmSetWindowAttribute(hwnd: HWND, dwAttribute: DWORD, pvAttribute: *const anyopaque, cbAttribute: DWORD) callconv(WINAPI) i32;

pub const HHOOK = ?*anyopaque;
pub const WH_KEYBOARD_LL: INT = 13;
pub const HC_ACTION: INT = 0;
pub const WM_KEYDOWN_LL: UINT = 0x0100;
pub const WM_KEYUP_LL: UINT = 0x0101;
pub const WM_SYSKEYDOWN: UINT = 0x0104;
pub const WM_SYSKEYUP: UINT = 0x0105;
pub const WM_APP: UINT = 0x8000;
pub const VK_LWIN: UINT = 0x5B;
pub const VK_RWIN: UINT = 0x5C;
pub const LLKHF_INJECTED: DWORD = 0x00000010;

pub const KBDLLHOOKSTRUCT = extern struct {
    vkCode: DWORD,
    scanCode: DWORD,
    flags: DWORD,
    time: DWORD,
    dwExtraInfo: usize,
};

pub const HOOKPROC = *const fn (INT, WPARAM, LPARAM) callconv(WINAPI) LRESULT;
pub extern "user32" fn SetWindowsHookExW(idHook: INT, lpfn: HOOKPROC, hmod: HINSTANCE, dwThreadId: DWORD) callconv(WINAPI) HHOOK;
pub extern "user32" fn CallNextHookEx(hhk: HHOOK, nCode: INT, wParam: WPARAM, lParam: LPARAM) callconv(WINAPI) LRESULT;
pub extern "user32" fn UnhookWindowsHookEx(hhk: HHOOK) callconv(WINAPI) BOOL;
pub extern "user32" fn PostMessageW(hWnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(WINAPI) BOOL;

pub const DWMWA_USE_IMMERSIVE_DARK_MODE: DWORD = 20;
pub const DWMWA_WINDOW_CORNER_PREFERENCE: DWORD = 33;
pub const DWMWA_CAPTION_COLOR: DWORD = 35;
pub const DWMWA_TEXT_COLOR: DWORD = 36;
pub const DWMWCP_ROUND: DWORD = 2;
