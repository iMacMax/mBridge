using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

// Using this PC's keyboard and mouse on another computer (a Mac or another PC). Push the cursor off the
// edge of the screen where the other computer sits and it carries on over there.

class Peer
{
    public string Id, Name, Host, Platform;
    public int Port, Width, Height;
    public DateTime Seen;
}

enum Side { Left, Right, Above, Below }

/// Where the other computer sits next to this one, like two monitors.
class Arrangement
{
    public Side Side = Side.Right;
    public double Offset;   // how far the other screen is shifted along the shared edge, from this screen's top or left
    public bool Lined = true;   // centered: lined up by proportion, so the cursor crosses at the same relative position

    public static Arrangement Centered(Side side, SizeF me, SizeF other)
    {
        Arrangement a = new Arrangement();
        a.Side = side;
        a.Lined = true;
        bool horizontal = side == Side.Left || side == Side.Right;
        a.Offset = horizontal ? (me.Height - other.Height) / 2 : (me.Width - other.Width) / 2;
        return a;
    }

    public RectangleF OtherRect(RectangleF me, SizeF other)
    {
        float off = (float)Offset;
        switch (Side)
        {
            case Side.Right: return new RectangleF(me.Right, me.Top + off, other.Width, other.Height);
            case Side.Left: return new RectangleF(me.Left - other.Width, me.Top + off, other.Width, other.Height);
            case Side.Below: return new RectangleF(me.Left + off, me.Bottom, other.Width, other.Height);
            default: return new RectangleF(me.Left + off, me.Top - other.Height, other.Width, other.Height);
        }
    }

    /// The cursor is pushing against the edge that touches the other computer: where it appears there.
    public bool Entry(Point p, int dx, int dy, RectangleF me, SizeF other, out PointF entry)
    {
        RectangleF r = OtherRect(me, other);
        bool lined = Lined;
        float fy = (p.Y - me.Top) / me.Height, fx = (p.X - me.Left) / me.Width;   // how far along the edge, 0...1
        entry = PointF.Empty;
        switch (Side)
        {
            case Side.Right:
                if (p.X < me.Right - 1 || dx <= 0 || (!lined && (p.Y < r.Top || p.Y >= r.Bottom))) return false;
                entry = new PointF(0, lined ? fy * other.Height : p.Y - r.Top);
                return true;
            case Side.Left:
                if (p.X > me.Left + 1 || dx >= 0 || (!lined && (p.Y < r.Top || p.Y >= r.Bottom))) return false;
                entry = new PointF(other.Width - 1, lined ? fy * other.Height : p.Y - r.Top);
                return true;
            case Side.Below:
                if (p.Y < me.Bottom - 1 || dy <= 0 || (!lined && (p.X < r.Left || p.X >= r.Right))) return false;
                entry = new PointF(lined ? fx * other.Width : p.X - r.Left, 0);
                return true;
            default:
                if (p.Y > me.Top + 1 || dy >= 0 || (!lined && (p.X < r.Left || p.X >= r.Right))) return false;
                entry = new PointF(lined ? fx * other.Width : p.X - r.Left, other.Height - 1);
                return true;
        }
    }

    /// The virtual cursor went past the other computer's edge that touches this one: where it appears here.
    /// Always leaves, even if the heights don't line up, so you can never get trapped over there.
    public bool Exit(PointF v, RectangleF me, SizeF other, out Point back)
    {
        RectangleF r = OtherRect(me, other);
        bool lined = Lined;
        float alongY = lined ? me.Top + v.Y / other.Height * me.Height : v.Y + r.Top;
        float alongX = lined ? me.Left + v.X / other.Width * me.Width : v.X + r.Left;
        back = Point.Empty;
        switch (Side)
        {
            case Side.Right:
                if (v.X >= 0) return false;
                back = new Point((int)me.Right - 3, Clamp(alongY, me.Top + 3, me.Bottom - 3));
                return true;
            case Side.Left:
                if (v.X <= other.Width - 1) return false;
                back = new Point((int)me.Left + 3, Clamp(alongY, me.Top + 3, me.Bottom - 3));
                return true;
            case Side.Below:
                if (v.Y >= 0) return false;
                back = new Point(Clamp(alongX, me.Left + 3, me.Right - 3), (int)me.Bottom - 3);
                return true;
            default:
                if (v.Y <= other.Height - 1) return false;
                back = new Point(Clamp(alongX, me.Left + 3, me.Right - 3), (int)me.Top + 3);
                return true;
        }
    }

    static int Clamp(float v, float lo, float hi) { return (int)Math.Min(Math.Max(v, lo), hi); }
}

/// Sends lines on a background thread, in order, so a slow network can never freeze this PC's mouse.
/// Cursor positions are coalesced: only the newest one is sent.
class Outbox
{
    readonly BlockingCollection<string> queue = new BlockingCollection<string>();
    readonly Stream stream;
    readonly Action failed;
    readonly object moveLock = new object();
    string move;
    volatile bool stopped;

    public Outbox(Stream stream, Action failed)
    {
        this.stream = stream;
        this.failed = failed;
        Thread t = new Thread(Run);
        t.IsBackground = true;
        t.Start();
    }

    public void Send(string line) { if (!stopped) queue.Add(line); }

    public void Move(int x, int y)
    {
        lock (moveLock) { move = "p " + x.ToString(CultureInfo.InvariantCulture) + " " + y.ToString(CultureInfo.InvariantCulture); }
    }

    public void Stop() { stopped = true; }

    void Run()
    {
        try
        {
            while (!stopped)
            {
                string item;
                if (queue.TryTake(out item, 4)) { FlushMove(); Write(item); }
                else FlushMove();
            }
        }
        catch { stopped = true; if (failed != null) failed(); }
    }

    void FlushMove()
    {
        string line;
        lock (moveLock) { line = move; move = null; }
        if (line != null) Write(line);
    }

    void Write(string line)
    {
        byte[] bytes = Encoding.UTF8.GetBytes(line + "\n");
        stream.Write(bytes, 0, bytes.Length);
    }
}

/// A hidden window that receives raw mouse movement, which still reports pushing against a screen edge.
class RawWindow : NativeWindow
{
    readonly Controller owner;

    public RawWindow(Controller owner)
    {
        this.owner = owner;
        CreateHandle(new CreateParams());
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == 0x00FF) owner.OnRawInput(m.LParam);   // WM_INPUT
        base.WndProc(ref m);
    }
}

class Controller
{
    readonly App app;
    TcpClient client;
    Outbox outbox;
    System.Threading.Timer heartbeat;
    bool connecting;

    // while the keyboard and mouse are on the other computer
    public volatile bool Remote;
    PointF otherPos;                  // where the cursor is on the other computer (its pixels)
    Point returnPoint;                // where the cursor goes back to here
    Point parked;                     // the cursor is held mid-screen while it is away
    DateTime ignoreUntil = DateTime.MinValue;
    DateTime lastSwitch = DateTime.MinValue;

    // hooks that see (and can swallow) every key and mouse event
    Native.HookProc mouseProc, keyProc;
    IntPtr mouseHook = IntPtr.Zero, keyHook = IntPtr.Zero;
    RawWindow rawWindow;

    public Peer Target;               // the computer being controlled
    public bool Connected { get { return client != null; } }
    public bool Connecting { get { return connecting; } }
    public SizeF OtherSize { get { return Target == null ? new SizeF(1920, 1080) : new SizeF(Target.Width, Target.Height); } }
    public static RectangleF Screen { get { return new RectangleF(0, 0, Input.Width, Input.Height); } }

    public Controller(App app) { this.app = app; }

    // MARK: connecting

    public void Connect(Peer peer)
    {
        if (connecting || Connected) return;
        connecting = true;
        app.SetStatus("Connecting to " + peer.Name + "…");
        Thread t = new Thread(delegate() { ConnectWorker(peer); });
        t.IsBackground = true;
        t.Start();
    }

    void ConnectWorker(Peer peer)
    {
        TcpClient c = new TcpClient();
        try
        {
            IAsyncResult ar = c.BeginConnect(peer.Host, peer.Port, null, null);
            if (!ar.AsyncWaitHandle.WaitOne(3000, false)) throw new IOException("timed out");
            c.EndConnect(ar);
            c.NoDelay = true;
            c.ReceiveTimeout = 3000;
            NetworkStream stream = c.GetStream();
            StreamReader reader = new StreamReader(stream, Encoding.UTF8);

            byte[] hello = Encoding.UTF8.GetBytes("hi " + app.Key + " " + Environment.MachineName + "\nplat win\n");
            stream.Write(hello, 0, hello.Length);
            string reply = reader.ReadLine() ?? "";
            if (reply == "deny")
            {
                c.Close();
                app.UiPost(delegate { connecting = false; app.SetStatus(peer.Name + " is paired with another computer"); });
                return;
            }
            string[] f = reply.Split(' ');
            if (f.Length < 3 || f[0] != "ok") throw new IOException("unexpected reply");
            int w = int.Parse(f[1], CultureInfo.InvariantCulture), h = int.Parse(f[2], CultureInfo.InvariantCulture);
            c.ReceiveTimeout = 5000;   // the other computer sends a "." every second
            app.UiPost(delegate { Attach(c, stream, reader, peer, w, h); });
        }
        catch (Exception e)
        {
            App.Log("connect: " + e.Message);
            try { c.Close(); } catch { }
            app.UiPost(delegate { connecting = false; app.SetStatus("Can't reach " + peer.Name); });
        }
    }

    /// On the window thread: the connection is up.
    void Attach(TcpClient c, NetworkStream stream, StreamReader reader, Peer peer, int width, int height)
    {
        connecting = false;
        peer.Width = width;
        peer.Height = height;
        Target = peer;
        client = c;
        outbox = new Outbox(stream, delegate { app.UiPost(delegate { if (client == c) Closed("Connection lost"); }); });
        Outbox box = outbox;
        heartbeat = new System.Threading.Timer(delegate { box.Send("."); }, null, 1000, 1000);
        outbox.Send("hide");   // the other computer's cursor stays out of sight until you cross over

        Thread t = new Thread(delegate() { ReadLoop(c, reader); });
        t.IsBackground = true;
        t.Start();

        StartCapture();
        app.SetStatus("Connected to " + peer.Name);
        app.OnControllerChanged();
    }

    /// Lines from the computer being controlled: only clipboard text (and its heartbeat).
    void ReadLoop(TcpClient c, StreamReader reader)
    {
        try
        {
            string line;
            while ((line = reader.ReadLine()) != null)
            {
                if (line.StartsWith("c ")) app.SetClipboard(line.Substring(2));
            }
        }
        catch { }
        app.UiPost(delegate { if (client == c) Closed("Connection lost"); });
    }

    public void Send(string line) { Outbox box = outbox; if (box != null) box.Send(line); }

    /// Lets go of the other computer.
    public void Disconnect() { Closed("Disconnected"); }

    void Closed(string status)
    {
        if (client == null) return;
        if (Remote) LeaveRemote(returnPoint);
        StopCapture();
        TcpClient c = client;
        client = null;
        if (heartbeat != null) { heartbeat.Dispose(); heartbeat = null; }
        if (outbox != null) { outbox.Stop(); outbox = null; }
        try { c.Close(); } catch { }
        Target = null;
        app.SetStatus(status);
        app.OnControllerChanged();
    }

    // MARK: capturing

    void StartCapture()
    {
        mouseProc = new Native.HookProc(MouseProc);
        keyProc = new Native.HookProc(KeyProc);
        IntPtr module = Native.GetModuleHandle(Process.GetCurrentProcess().MainModule.ModuleName);
        mouseHook = Native.SetWindowsHookEx(14, mouseProc, module, 0);   // WH_MOUSE_LL
        keyHook = Native.SetWindowsHookEx(13, keyProc, module, 0);       // WH_KEYBOARD_LL
        if (mouseHook == IntPtr.Zero || keyHook == IntPtr.Zero) App.Log("hooks failed: " + Marshal.GetLastWin32Error());

        rawWindow = new RawWindow(this);
        RAWINPUTDEVICE[] devices = new RAWINPUTDEVICE[1];
        devices[0].usagePage = 1;     // generic desktop
        devices[0].usage = 2;         // mouse
        devices[0].flags = 0x100;     // RIDEV_INPUTSINK: also when another window has focus
        devices[0].target = rawWindow.Handle;
        if (!Native.RegisterRawInputDevices(devices, 1, (uint)Marshal.SizeOf(typeof(RAWINPUTDEVICE)))) App.Log("raw input failed");
    }

    void StopCapture()
    {
        if (mouseHook != IntPtr.Zero) { Native.UnhookWindowsHookEx(mouseHook); mouseHook = IntPtr.Zero; }
        if (keyHook != IntPtr.Zero) { Native.UnhookWindowsHookEx(keyHook); keyHook = IntPtr.Zero; }
        if (rawWindow != null) { rawWindow.DestroyHandle(); rawWindow = null; }
    }

    /// Raw mouse movement while the keyboard and mouse are still here: watch for pushing against the edge.
    public void OnRawInput(IntPtr lParam)
    {
        if (Remote || !Connected || (DateTime.Now - lastSwitch).TotalMilliseconds < 250) return;
        if ((Native.GetAsyncKeyState(0x01) & 0x8000) != 0 || (Native.GetAsyncKeyState(0x02) & 0x8000) != 0) return;   // dragging

        uint header = (uint)Marshal.SizeOf(typeof(RawHeader));
        uint size = 0;
        Native.GetRawInputData(lParam, 0x10000003, IntPtr.Zero, ref size, header);   // RID_INPUT
        if (size == 0 || size > 1024) return;
        IntPtr buffer = Marshal.AllocHGlobal((int)size);
        try
        {
            if (Native.GetRawInputData(lParam, 0x10000003, buffer, ref size, header) != size) return;
            if (Marshal.ReadInt32(buffer, 0) != 0) return;                               // not a mouse
            if ((Marshal.ReadInt16(buffer, (int)header) & 1) != 0) return;               // absolute (tablet, remote desktop)
            int dx = Marshal.ReadInt32(buffer, (int)header + 12);
            int dy = Marshal.ReadInt32(buffer, (int)header + 16);
            POINT p;
            if (!Native.GetCursorPos(out p)) return;
            PointF entry;
            if (app.Arrangements.Get(Target).Entry(new Point(p.X, p.Y), dx, dy, Screen, OtherSize, out entry))
                EnterRemote(entry, new Point(p.X, p.Y));
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    [StructLayout(LayoutKind.Sequential)]
    struct RawHeader { public uint type, size; public IntPtr device, wParam; }

    // MARK: switching

    /// Menu item: jump to the other computer (or back) without touching the edge.
    public void Toggle()
    {
        if (Remote) { LeaveRemote(returnPoint); return; }
        if (!Connected) return;
        POINT p;
        Native.GetCursorPos(out p);
        SizeF other = OtherSize;
        EnterRemote(new PointF(other.Width / 2, other.Height / 2), new Point(p.X, p.Y));
    }

    void EnterRemote(PointF entry, Point from)
    {
        RectangleF me = Screen;
        returnPoint = new Point((int)Math.Min(Math.Max(from.X, me.Left + 3), me.Right - 3), (int)Math.Min(Math.Max(from.Y, me.Top + 3), me.Bottom - 3));
        otherPos = entry;
        parked = new Point((int)(me.Width / 2), (int)(me.Height / 2));
        Remote = true;
        lastSwitch = DateTime.Now;
        ignoreUntil = DateTime.Now.AddMilliseconds(100);
        Send("show");
        Send("p " + ((int)entry.X).ToString(CultureInfo.InvariantCulture) + " " + ((int)entry.Y).ToString(CultureInfo.InvariantCulture));
        CursorHider.Hide();
        Native.SetCursorPos(parked.X, parked.Y);   // held mid-screen while away, so there is room to move in every direction
        app.OnControllerChanged();
    }

    void LeaveRemote(Point back)
    {
        if (!Remote) return;
        Remote = false;
        lastSwitch = DateTime.Now;
        Send("r");
        Send("hide");
        Native.SetCursorPos(back.X, back.Y);
        CursorHider.Show();
        app.OnControllerChanged();
    }

    /// Always works: Ctrl+Alt+Win+Esc brings the keyboard and mouse back to this PC.
    public void Panic() { if (Remote) LeaveRemote(returnPoint); }

    // MARK: hooks

    IntPtr MouseProc(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0 && Remote)
        {
            MSLLHOOKSTRUCT m = (MSLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(MSLLHOOKSTRUCT));
            if ((m.flags & 0x1) == 0)   // not injected: a real mouse
            {
                switch (wParam.ToInt32())
                {
                    case 0x0200: Move(m); break;                                    // WM_MOUSEMOVE
                    case 0x0201: Button(0, true); break;                            // left
                    case 0x0202: Button(0, false); break;
                    case 0x0204: Button(1, true); break;                            // right
                    case 0x0205: Button(1, false); break;
                    case 0x0207: Button(2, true); break;                            // middle
                    case 0x0208: Button(2, false); break;
                    case 0x020B: Button(2 + (int)((m.mouseData >> 16) & 0xFFFF), true); break;    // side buttons: 3 back, 4 forward
                    case 0x020C: Button(2 + (int)((m.mouseData >> 16) & 0xFFFF), false); break;
                    case 0x020A: Wheel(0, (short)(m.mouseData >> 16)); break;       // vertical wheel
                    case 0x020E: Wheel((short)(m.mouseData >> 16), 0); break;       // horizontal wheel
                }
                return (IntPtr)1;   // swallowed: it went to the other computer
            }
        }
        return Native.CallNextHookEx(IntPtr.Zero, code, wParam, lParam);
    }

    void Move(MSLLHOOKSTRUCT m)
    {
        if (DateTime.Now < ignoreUntil) return;
        int dx = m.pt.X - parked.X, dy = m.pt.Y - parked.Y;
        if (dx == 0 && dy == 0) return;
        Native.SetCursorPos(parked.X, parked.Y);

        SizeF other = OtherSize;
        PointF next = new PointF(otherPos.X + dx, otherPos.Y + dy);
        Point back;
        if (app.Arrangements.Get(Target).Exit(next, Screen, other, out back)) { LeaveRemote(back); return; }
        next.X = Math.Min(Math.Max(next.X, 0), other.Width - 1);
        next.Y = Math.Min(Math.Max(next.Y, 0), other.Height - 1);
        otherPos = next;
        Outbox box = outbox;
        if (box != null) box.Move((int)next.X, (int)next.Y);
    }

    void Button(int number, bool down)
    {
        Send("b " + number.ToString(CultureInfo.InvariantCulture) + " " + (down ? "1" : "0"));
    }

    // One notch of the wheel is 120; the wire carries pixels, about 10 per notch. Right on the wheel is left on the wire.
    void Wheel(int horizontal, int vertical)
    {
        int dx = -horizontal / 12, dy = vertical / 12;
        if (dx != 0 || dy != 0) Send("w " + dx.ToString(CultureInfo.InvariantCulture) + " " + dy.ToString(CultureInfo.InvariantCulture));
    }

    IntPtr KeyProc(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0 && Remote)
        {
            KBDLLHOOKSTRUCT k = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(KBDLLHOOKSTRUCT));
            if ((k.flags & 0x10) == 0)   // not injected: a real keyboard
            {
                int message = wParam.ToInt32();
                bool down = message == 0x0100 || message == 0x0104;   // WM_KEYDOWN, WM_SYSKEYDOWN
                bool ctrl = (Native.GetAsyncKeyState(0x11) & 0x8000) != 0, alt = (Native.GetAsyncKeyState(0x12) & 0x8000) != 0;
                bool win = (Native.GetAsyncKeyState(0x5B) & 0x8000) != 0 || (Native.GetAsyncKeyState(0x5C) & 0x8000) != 0;
                if (down && k.vkCode == 0x1B && ctrl && alt && win) { LeaveRemote(returnPoint); return (IntPtr)1; }
                if (k.vkCode != 0xE7)   // not an input-method placeholder
                {
                    Send("k " + k.vkCode.ToString(CultureInfo.InvariantCulture) + " " + ((k.flags & 0x1) != 0 ? "1" : "0") + " " + (down ? "1" : "0"));
                }
                return (IntPtr)1;
            }
        }
        return Native.CallNextHookEx(IntPtr.Zero, code, wParam, lParam);
    }
}
