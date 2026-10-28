using System;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

// mBridge for PC: a monitor icon in the system tray. A Mac running mBridge finds this PC on the
// network and uses its keyboard and mouse to control it. Built with the C# compiler that ships with Windows.

static class Native
{
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, int data, UIntPtr extra);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint type);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern IntPtr CreateCursor(IntPtr inst, int xHot, int yHot, int w, int h, byte[] andMask, byte[] xorMask);
    [DllImport("user32.dll")] public static extern bool SetSystemCursor(IntPtr cursor, uint id);
    [DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint action, uint param, IntPtr pv, uint winIni);
}

[StructLayout(LayoutKind.Sequential)]
struct POINT { public int X, Y; }

/// Hides the mouse cursor everywhere by swapping every system cursor for a see-through one,
/// and puts the real ones back with Show(). Windows has no simpler way to hide it system-wide.
static class CursorHider
{
    static readonly uint[] ids = { 32512, 32513, 32514, 32515, 32516, 32642, 32643, 32644, 32645, 32646, 32648, 32649, 32650, 32651 };
    static readonly object gate = new object();
    static bool hidden;
    public static int LastX, LastY;   // where the Mac last put the cursor

    public static bool IsHidden { get { lock (gate) { return hidden; } } }

    public static void Hide()
    {
        lock (gate)
        {
            if (hidden) return;
            hidden = true;
            POINT here;
            if (Native.GetCursorPos(out here)) { LastX = here.X; LastY = here.Y; }   // movement from now on is the PC's own mouse
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

    /// True when the PC's own mouse moved the cursor since the Mac last placed it.
    public static bool MovedByUser()
    {
        POINT p;
        if (!Native.GetCursorPos(out p)) return false;
        return Math.Abs(p.X - LastX) > 3 || Math.Abs(p.Y - LastY) > 3;
    }
}

class Input
{
    const uint LeftDown = 0x2, LeftUp = 0x4, RightDown = 0x8, RightUp = 0x10, MiddleDown = 0x20, MiddleUp = 0x40;
    const uint XDown = 0x80, XUp = 0x100, Wheel = 0x800, HWheel = 0x1000, KeyUp = 0x2, Extended = 0x1;

    readonly System.Collections.Generic.HashSet<int> keys = new System.Collections.Generic.HashSet<int>();
    readonly System.Collections.Generic.HashSet<int> buttons = new System.Collections.Generic.HashSet<int>();

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

    // The Mac sends scroll distance in pixels; about 10 pixels is one notch of the wheel.
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

    /// Lets go of everything still held, so a key or button never gets stuck when the Mac leaves.
    public void ReleaseAll()
    {
        foreach (int id in new System.Collections.Generic.List<int>(keys)) Key(id & 0xFF, (id & 0x100) != 0, false);
        foreach (int b in new System.Collections.Generic.List<int>(buttons)) Button(b, false);
    }
}

class App : ApplicationContext
{
    const int BeaconPort = 24801, ListenPort = 24802;

    readonly NotifyIcon tray = new NotifyIcon();
    readonly ToolStripMenuItem status = new ToolStripMenuItem("Waiting for a Mac…");
    readonly Control ui = new Control();   // other threads hand work to the window thread through this
    readonly string keyFile = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "mBridge", "paired.txt");
    readonly Input input = new Input();
    readonly object writeLock = new object();
    TcpClient current;
    NetworkStream currentStream;
    uint clipboardSeq;

    public App()
    {
        IntPtr handle = ui.Handle;             // creates the window on this thread, so BeginInvoke has somewhere to go
        status.Enabled = false;
        ToolStripMenuItem login = new ToolStripMenuItem("Open at Login");
        login.Checked = LoginEnabled();
        login.Click += delegate { SetLogin(!LoginEnabled()); login.Checked = LoginEnabled(); };
        ToolStripMenuItem forget = new ToolStripMenuItem("Forget Paired Mac");
        forget.Click += delegate { try { File.Delete(keyFile); } catch { } SetStatus("Waiting for a Mac…"); };
        ToolStripMenuItem quit = new ToolStripMenuItem("Quit mBridge");
        quit.Click += delegate { input.ReleaseAll(); CursorHider.Show(); tray.Visible = false; Application.Exit(); };

        ContextMenuStrip menu = new ContextMenuStrip();
        menu.Items.Add(status);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(login);
        menu.Items.Add(forget);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(quit);
        tray.ContextMenuStrip = menu;
        tray.Icon = MonitorIcon();
        tray.Text = "mBridge";
        tray.Visible = true;

        clipboardSeq = Native.GetClipboardSequenceNumber();
        System.Windows.Forms.Timer clipboardTimer = new System.Windows.Forms.Timer();
        clipboardTimer.Interval = 300;
        clipboardTimer.Tick += delegate { WatchClipboard(); };
        clipboardTimer.Start();

        CursorHider.Show();   // a crashed run could have left the cursors hidden
        System.Windows.Forms.Timer userMouse = new System.Windows.Forms.Timer();
        userMouse.Interval = 100;
        userMouse.Tick += delegate { if (CursorHider.IsHidden && CursorHider.MovedByUser()) CursorHider.Show(); };
        userMouse.Start();
        AppDomain.CurrentDomain.ProcessExit += delegate { CursorHider.Show(); };

        Thread listen = new Thread(Listen); listen.IsBackground = true; listen.Start();
        Thread beacon = new Thread(Beacon); beacon.IsBackground = true; beacon.Start();
    }

    // MARK: tray

    void SetStatus(string text) { ui.BeginInvoke((MethodInvoker)delegate { status.Text = text; }); }

    static Icon MonitorIcon()
    {
        bool light = true;
        try { light = (int)Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "SystemUsesLightTheme", 1) == 1; } catch { }
        Color ink = light ? Color.Black : Color.White;
        Bitmap bmp = new Bitmap(32, 32);
        using (Graphics g = Graphics.FromImage(bmp))
        using (Pen pen = new Pen(ink, 3))
        using (Brush brush = new SolidBrush(ink))
        {
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            g.DrawRectangle(pen, 3, 5, 25, 17);
            g.FillRectangle(brush, 14, 22, 4, 4);
            g.FillRectangle(brush, 9, 26, 14, 3);
        }
        return Icon.FromHandle(bmp.GetHicon());
    }

    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    static bool LoginEnabled()
    {
        using (RegistryKey k = Registry.CurrentUser.OpenSubKey(RunKey)) { return k != null && k.GetValue("mBridge") != null; }
    }

    static void SetLogin(bool on)
    {
        using (RegistryKey k = Registry.CurrentUser.OpenSubKey(RunKey, true))
        {
            if (on) k.SetValue("mBridge", "\"" + Application.ExecutablePath + "\""); else k.DeleteValue("mBridge", false);
        }
    }

    /// Problems go to %LOCALAPPDATA%\mBridge\log.txt, so they can be looked at later.
    static void Log(string message)
    {
        try
        {
            string dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "mBridge");
            Directory.CreateDirectory(dir);
            File.AppendAllText(Path.Combine(dir, "log.txt"), DateTime.Now.ToString("s") + " " + message + "\r\n");
        }
        catch { }
    }

    // MARK: clipboard

    /// Text copied here is sent to the Mac. Copies marked as secret (password managers) are never sent.
    void WatchClipboard()
    {
        uint seq = Native.GetClipboardSequenceNumber();
        if (seq == clipboardSeq) return;
        clipboardSeq = seq;
        NetworkStream stream = currentStream;
        if (stream == null) return;
        try
        {
            if (!Clipboard.ContainsText() || Clipboard.ContainsData("ExcludeClipboardContentFromMonitorProcessing")) return;
            string text = Clipboard.GetText();
            if (text.Length == 0 || text.Length > 256000) return;
            Send(stream, "c " + Convert.ToBase64String(Encoding.UTF8.GetBytes(text.Replace("\r\n", "\n"))));
            Log("clipboard sent to Mac: " + text.Length + " characters");
        }
        catch (Exception e) { Log("clipboard send: " + e.Message); }
    }

    /// Text copied on the Mac arrives as "c <base64>".
    void SetClipboard(string base64)
    {
        string text;
        try { text = Encoding.UTF8.GetString(Convert.FromBase64String(base64)); } catch (Exception e) { Log("clipboard from Mac unreadable: " + e.Message); return; }
        Log("clipboard from Mac: " + text.Length + " characters");
        if (text.Length == 0) return;
        ui.BeginInvoke((MethodInvoker)delegate
        {
            try
            {
                Clipboard.SetDataObject(text.Replace("\r\n", "\n").Replace("\n", "\r\n"), true, 10, 100);
                clipboardSeq = Native.GetClipboardSequenceNumber();
                Log("clipboard set");
            }
            catch (Exception e) { Log("clipboard: " + e.Message); }
        });
    }

    // MARK: network

    /// Shouts "I'm here" once a second so the Mac can find this PC without any setup.
    void Beacon()
    {
        UdpClient udp = new UdpClient();
        udp.EnableBroadcast = true;
        while (true)
        {
            try
            {
                string text = "mBridge|" + Environment.MachineName + "|" + Environment.MachineName + "|" + Input.Width + "|" + Input.Height + "|" + ListenPort;
                byte[] data = Encoding.UTF8.GetBytes(text);
                udp.Send(data, data.Length, new IPEndPoint(IPAddress.Broadcast, BeaconPort));
                foreach (NetworkInterface nic in NetworkInterface.GetAllNetworkInterfaces())
                {
                    if (nic.OperationalStatus != OperationalStatus.Up) continue;
                    foreach (UnicastIPAddressInformation ua in nic.GetIPProperties().UnicastAddresses)
                    {
                        if (ua.Address.AddressFamily != AddressFamily.InterNetwork || ua.IPv4Mask == null) continue;
                        byte[] a = ua.Address.GetAddressBytes(), m = ua.IPv4Mask.GetAddressBytes(), b = new byte[4];
                        for (int i = 0; i < 4; i++) b[i] = (byte)(a[i] | ~m[i]);
                        udp.Send(data, data.Length, new IPEndPoint(new IPAddress(b), BeaconPort));
                    }
                }
            }
            catch { }
            Thread.Sleep(1000);
        }
    }

    void Listen()
    {
        TcpListener listener = new TcpListener(IPAddress.Any, ListenPort);
        try { listener.Start(); }
        catch { SetStatus("Port " + ListenPort + " is in use"); return; }
        while (true)
        {
            TcpClient client;
            try { client = listener.AcceptTcpClient(); } catch { continue; }
            Thread t = new Thread(delegate () { Serve(client); });
            t.IsBackground = true;
            t.Start();
        }
    }

    void Send(NetworkStream stream, string line)
    {
        byte[] bytes = Encoding.UTF8.GetBytes(line + "\n");
        lock (writeLock) { stream.Write(bytes, 0, bytes.Length); }
    }

    void Serve(TcpClient client)
    {
        System.Threading.Timer heartbeat = null;
        try
        {
            client.NoDelay = true;
            client.ReceiveTimeout = 5000;   // the Mac sends "." every second
            NetworkStream stream = client.GetStream();
            StreamReader reader = new StreamReader(stream, Encoding.UTF8);

            string[] hello = (reader.ReadLine() ?? "").Split(new char[] { ' ' }, 3);
            if (hello.Length < 3 || hello[0] != "hi") return;

            // The first Mac to connect is remembered; any other Mac is turned away until "Forget Paired Mac".
            string saved = null;
            try { saved = File.ReadAllText(keyFile).Trim(); } catch { }
            if (saved == null || saved.Length == 0)
            {
                Directory.CreateDirectory(Path.GetDirectoryName(keyFile));
                File.WriteAllText(keyFile, hello[1]);
            }
            else if (saved != hello[1])
            {
                Send(stream, "deny");
                SetStatus("Turned away " + hello[2] + " (not paired)");
                return;
            }

            TcpClient previous = current;
            current = client;
            currentStream = stream;
            if (previous != null) { try { previous.Close(); } catch { } }

            Send(stream, "ok " + Input.Width + " " + Input.Height);
            SetStatus("Connected to " + hello[2]);
            heartbeat = new System.Threading.Timer(delegate { try { Send(stream, "."); } catch { } }, null, 1000, 1000);

            string line;
            while ((line = reader.ReadLine()) != null)
            {
                if (line == ".") continue;
                if (line.StartsWith("c ")) SetClipboard(line.Substring(2));
                else if (line == "hide") CursorHider.Hide();
                else if (line == "show") CursorHider.Show();
                else { try { input.Apply(line); } catch { } }
            }
        }
        catch { }
        finally
        {
            if (heartbeat != null) heartbeat.Dispose();
            input.ReleaseAll();
            if (current == client) CursorHider.Show();
            if (current == client) { current = null; currentStream = null; SetStatus("Waiting for a Mac…"); }
            try { client.Close(); } catch { }
        }
    }
}

static class Program
{
    [STAThread]
    static void Main()
    {
        bool first;
        using (Mutex one = new Mutex(true, "mBridgePC", out first))
        {
            if (!first) return;
            Native.SetProcessDPIAware();   // real pixels, so the cursor lands where the Mac says
            Application.EnableVisualStyles();
            Application.Run(new App());
        }
    }
}
