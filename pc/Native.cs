using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.Runtime.InteropServices;

// Windows system calls, the hidden cursor, and replaying another computer's keyboard and mouse here.

static class Native
{
    public delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, int data, UIntPtr extra);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint type);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vk);
    [DllImport("user32.dll")] public static extern IntPtr CreateCursor(IntPtr inst, int xHot, int yHot, int w, int h, byte[] andMask, byte[] xorMask);
    [DllImport("user32.dll")] public static extern bool SetSystemCursor(IntPtr cursor, uint id);
    [DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint action, uint param, IntPtr pv, uint winIni);
    [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr SetWindowsHookEx(int id, HookProc proc, IntPtr module, uint thread);
    [DllImport("user32.dll")] public static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")] public static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool RegisterRawInputDevices(RAWINPUTDEVICE[] devices, uint count, uint size);
    [DllImport("user32.dll")] public static extern uint GetRawInputData(IntPtr raw, uint command, IntPtr data, ref uint size, uint headerSize);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr GetModuleHandle(string name);
}

[StructLayout(LayoutKind.Sequential)]
struct POINT { public int X, Y; }

[StructLayout(LayoutKind.Sequential)]
struct MSLLHOOKSTRUCT { public POINT pt; public uint mouseData, flags, time; public IntPtr extra; }

[StructLayout(LayoutKind.Sequential)]
struct KBDLLHOOKSTRUCT { public uint vkCode, scanCode, flags, time; public IntPtr extra; }

[StructLayout(LayoutKind.Sequential)]
struct RAWINPUTDEVICE { public ushort usagePage, usage; public uint flags; public IntPtr target; }

/// Hides the mouse cursor everywhere by swapping every system cursor for a see-through one,
/// and puts the real ones back with Show(). Windows has no simpler way to hide it system-wide.
static class CursorHider
{
    static readonly uint[] ids = { 32512, 32513, 32514, 32515, 32516, 32642, 32643, 32644, 32645, 32646, 32648, 32649, 32650, 32651 };
    static readonly object gate = new object();
    static bool hidden;
    public static int LastX, LastY;   // where the other computer last put the cursor

    public static bool IsHidden { get { lock (gate) { return hidden; } } }

    public static void Hide()
    {
        lock (gate)
        {
            if (hidden) return;
            hidden = true;
            POINT here;
            if (Native.GetCursorPos(out here)) { LastX = here.X; LastY = here.Y; }   // movement from now on is this PC's own mouse
            byte[] andMask = new byte[128], xorMask = new byte[128];
            for (int i = 0; i < andMask.Length; i++) andMask[i] = 0xFF;
            foreach (uint id in ids) Native.SetSystemCursor(Native.CreateCursor(IntPtr.Zero, 0, 0, 32, 32, andMask, xorMask), id);
        }
    }

    public static void Show()
    {
        lock (gate)
        {
            hidden = false;
            Native.SystemParametersInfo(0x57, 0, IntPtr.Zero, 0);   // SPI_SETCURSORS: reload the user's cursors
        }
    }

    /// True when this PC's own mouse moved the cursor since the other computer last placed it.
    public static bool MovedByUser()
    {
        POINT p;
        if (!Native.GetCursorPos(out p)) return false;
        return Math.Abs(p.X - LastX) > 3 || Math.Abs(p.Y - LastY) > 3;
    }
}

/// Replays another computer's keyboard and mouse on this PC.
class Input
{
    const uint LeftDown = 0x2, LeftUp = 0x4, RightDown = 0x8, RightUp = 0x10, MiddleDown = 0x20, MiddleUp = 0x40;
    const uint XDown = 0x80, XUp = 0x100, Wheel = 0x800, HWheel = 0x1000, KeyUp = 0x2, Extended = 0x1;

    readonly HashSet<int> keys = new HashSet<int>();
    readonly HashSet<int> buttons = new HashSet<int>();

    public static int Width { get { return Native.GetSystemMetrics(0); } }
    public static int Height { get { return Native.GetSystemMetrics(1); } }

    public void Apply(string line)
    {
        string[] f = line.Split(' ');
        switch (f[0])
        {
            case "p": MoveCursor(Int(f[1]), Int(f[2])); break;
            case "b": Button(Int(f[1]), Int(f[2]) == 1); break;
            case "w": Scroll(Int(f[1]), Int(f[2])); break;
            case "k": Key(Int(f[1]), Int(f[2]) == 1, Int(f[3]) == 1); break;
            case "r": ReleaseAll(); break;
        }
    }

    static void MoveCursor(int x, int y)
    {
        CursorHider.LastX = x;
        CursorHider.LastY = y;
        Native.SetCursorPos(x, y);
    }

    static int Int(string s) { return int.Parse(s, CultureInfo.InvariantCulture); }

    void Button(int number, bool down)
    {
        if (down) buttons.Add(number); else buttons.Remove(number);
        switch (number)
        {
            case 0: Native.mouse_event(down ? LeftDown : LeftUp, 0, 0, 0, UIntPtr.Zero); break;
            case 1: Native.mouse_event(down ? RightDown : RightUp, 0, 0, 0, UIntPtr.Zero); break;
            case 2: Native.mouse_event(down ? MiddleDown : MiddleUp, 0, 0, 0, UIntPtr.Zero); break;
            case 3: Native.mouse_event(down ? XDown : XUp, 0, 0, 1, UIntPtr.Zero); break;   // back
            case 4: Native.mouse_event(down ? XDown : XUp, 0, 0, 2, UIntPtr.Zero); break;   // forward
        }
    }

    // Scroll distance arrives in pixels; about 10 pixels is one notch of the wheel.
    void Scroll(int dx, int dy)
    {
        if (dy != 0) Native.mouse_event(Wheel, 0, 0, dy * 12, UIntPtr.Zero);
        if (dx != 0) Native.mouse_event(HWheel, 0, 0, -dx * 12, UIntPtr.Zero);
    }

    void Key(int vk, bool extended, bool down)
    {
        int id = vk | (extended ? 0x100 : 0);
        if (down) keys.Add(id); else keys.Remove(id);
        uint flags = (extended ? Extended : 0) | (down ? 0 : KeyUp);
        Native.keybd_event((byte)vk, (byte)Native.MapVirtualKey((uint)vk, 0), flags, UIntPtr.Zero);
    }

    /// Lets go of everything still held, so a key or button never gets stuck when the other computer leaves.
    public void ReleaseAll()
    {
        foreach (int id in new List<int>(keys)) Key(id & 0xFF, (id & 0x100) != 0, false);
        foreach (int b in new List<int>(buttons)) Button(b, false);
    }
}
