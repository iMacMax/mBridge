using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

// mBridge for PC: a monitor icon in the system tray. Use this PC's keyboard and mouse on a Mac or another PC
// on the same network, and the other way round. Built with the C# compiler that ships with Windows.

/// Remembers where each computer sits, and which one to connect to by itself.
class Settings
{
    readonly string file = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "mBridge", "settings.txt");
    readonly Dictionary<string, Arrangement> arrangements = new Dictionary<string, Arrangement>();
    public string LastPeer, ManualHost;

    public Settings()
    {
        try
        {
            foreach (string line in File.ReadAllLines(file))
            {
                int eq = line.IndexOf('=');
                if (eq < 0) continue;
                string name = line.Substring(0, eq), value = line.Substring(eq + 1);
                if (name == "last") LastPeer = value;
                else if (name == "host") ManualHost = value;
                else if (name == "arrangement")
                {
                    string[] f = value.Split('|');
                    if (f.Length < 3) continue;
                    Arrangement a = new Arrangement();
                    a.Side = (Side)Enum.Parse(typeof(Side), f[1]);
                    a.Offset = double.Parse(f[2], CultureInfo.InvariantCulture);
                    a.Lined = f.Length < 4 || f[3] == "1";
                    arrangements[f[0]] = a;
                }
            }
        }
        catch { }
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(file));
            List<string> lines = new List<string>();
            if (LastPeer != null) lines.Add("last=" + LastPeer);
            if (ManualHost != null) lines.Add("host=" + ManualHost);
            foreach (KeyValuePair<string, Arrangement> pair in arrangements)
                lines.Add("arrangement=" + pair.Key + "|" + pair.Value.Side + "|" + pair.Value.Offset.ToString(CultureInfo.InvariantCulture) + "|" + (pair.Value.Lined ? "1" : "0"));
            File.WriteAllLines(file, lines.ToArray());
        }
        catch { }
    }

    /// The layout for a computer; the first time, it sits to the right with the screens centered on each other.
    public Arrangement Get(Peer peer)
    {
        if (peer == null) return new Arrangement();
        Arrangement a;
        if (!arrangements.TryGetValue(peer.Id, out a))
        {
            a = Arrangement.Centered(Side.Right, Controller.Screen.Size, new SizeF(peer.Width, peer.Height));
            arrangements[peer.Id] = a;
        }
        return a;
    }

    public void Set(Peer peer, Arrangement a) { arrangements[peer.Id] = a; Save(); }
}

class App : ApplicationContext
{
    public const int BeaconPort = 24801, ListenPort = 24802;

    readonly NotifyIcon tray = new NotifyIcon();
    readonly ContextMenuStrip menu = new ContextMenuStrip();
    readonly Control ui = new Control();   // other threads hand work to the window thread through this
    readonly string dataDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "mBridge");
    readonly string keyFile;
    readonly Input input = new Input();
    readonly Settings settings = new Settings();
    readonly Controller controller;
    readonly Dictionary<string, Peer> peers = new Dictionary<string, Peer>();
    readonly Icon idleIcon = MonitorIcon(false), activeIcon = MonitorIcon(true);
    readonly Dictionary<string, Bitmap> platformIcons = new Dictionary<string, Bitmap>();
    readonly object writeLock = new object();
    readonly string myKey;
    string statusText = "Looking for a computer…";
    bool paused;                // the user chose Disconnect: don't reconnect on our own

    // the computer controlling this PC, if any
    TcpClient current;
    NetworkStream currentStream;
    string controllerName;
    uint clipboardSeq;

    public string Key { get { return myKey; } }
    public Settings Arrangements { get { return settings; } }

    public App()
    {
        IntPtr handle = ui.Handle;             // creates the window on this thread, so BeginInvoke has somewhere to go
        keyFile = Path.Combine(dataDir, "paired.txt");
        myKey = LoadOwnKey();
        controller = new Controller(this);

        menu.Opening += delegate { BuildMenu(); };
        tray.ContextMenuStrip = menu;
        tray.Icon = idleIcon;
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
        userMouse.Tick += delegate { if (!controller.Remote && CursorHider.IsHidden && CursorHider.MovedByUser()) CursorHider.Show(); };
        userMouse.Start();
        AppDomain.CurrentDomain.ProcessExit += delegate { CursorHider.Show(); };

        System.Windows.Forms.Timer auto = new System.Windows.Forms.Timer();
        auto.Interval = 2000;
        auto.Tick += delegate { AutoConnect(); };
        auto.Start();

        Thread listen = new Thread(Listen); listen.IsBackground = true; listen.Start();
        Thread beacon = new Thread(Beacon); beacon.IsBackground = true; beacon.Start();
        Thread discover = new Thread(Discover); discover.IsBackground = true; discover.Start();
    }

    // MARK: window thread

    public void UiPost(MethodInvoker action) { ui.BeginInvoke(action); }

    public void SetStatus(string text)
    {
        statusText = text;
        UiPost(delegate { tray.Text = text.Length > 63 ? text.Substring(0, 63) : text; });
    }

    /// The icon is solid while the keyboard and mouse are on the other computer.
    public void OnControllerChanged()
    {
        tray.Icon = controller.Remote ? activeIcon : idleIcon;
    }

    // MARK: menu

    List<Peer> FreshPeers()
    {
        List<Peer> list = new List<Peer>();
        lock (peers)
        {
            foreach (Peer p in peers.Values)
                if ((DateTime.Now - p.Seen).TotalSeconds < 5) list.Add(p);
        }
        list.Sort(delegate(Peer a, Peer b) { return string.Compare(a.Name, b.Name, StringComparison.OrdinalIgnoreCase); });
        return list;
    }

    /// Rebuilt every time the menu opens, so it always shows the current state.
    void BuildMenu()
    {
        menu.Items.Clear();
        ToolStripMenuItem status = new ToolStripMenuItem(statusText);
        status.Enabled = false;
        menu.Items.Add(status);
        menu.Items.Add(new ToolStripSeparator());

        // Computers: click one to control it, click it again to let go.
        List<Peer> list = FreshPeers();
        foreach (Peer found in list)
        {
            Peer peer = found;
            ToolStripMenuItem item = new ToolStripMenuItem(peer.Name);
            item.Image = PlatformIcon(peer.Platform);
            item.Checked = controller.Connected && controller.Target != null && controller.Target.Id == peer.Id;
            item.Click += delegate { Choose(peer); };
            menu.Items.Add(item);
        }
        if (list.Count == 0)
        {
            ToolStripMenuItem none = new ToolStripMenuItem("No other computers found");
            none.Enabled = false;
            menu.Items.Add(none);
        }
        ToolStripMenuItem address = new ToolStripMenuItem("Enter Address…");
        address.Click += delegate { EnterAddress(); };
        menu.Items.Add(address);

        if (controllerName != null)
        {
            menu.Items.Add(new ToolStripSeparator());
            ToolStripMenuItem stop = new ToolStripMenuItem("Stop Being Controlled by " + controllerName);
            stop.Click += delegate { DropController(); };
            menu.Items.Add(stop);
        }

        if (controller.Connected && controller.Target != null)
        {
            menu.Items.Add(new ToolStripSeparator());
            Peer target = controller.Target;
            ToolStripMenuItem position = new ToolStripMenuItem("Position   " + target.Name + " is " + settings.Get(target).Side.ToString().ToLower());
            foreach (Side side in new Side[] { Side.Left, Side.Right, Side.Above, Side.Below })
            {
                Side chosen = side;
                ToolStripMenuItem entry = new ToolStripMenuItem(side.ToString());
                entry.Checked = settings.Get(target).Side == side;
                entry.Click += delegate { settings.Set(target, Arrangement.Centered(chosen, Controller.Screen.Size, controller.OtherSize)); };
                position.DropDownItems.Add(entry);
            }
            menu.Items.Add(position);

            ToolStripMenuItem toggle = new ToolStripMenuItem(controller.Remote ? "Back to This PC   Ctrl+Alt+Win+Esc" : "Switch to " + target.Name);
            toggle.Click += delegate { controller.Toggle(); };
            menu.Items.Add(toggle);
        }

        menu.Items.Add(new ToolStripSeparator());
        ToolStripMenuItem forget = new ToolStripMenuItem("Forget Paired Computer");
        forget.Click += delegate { try { File.Delete(keyFile); } catch { } };
        menu.Items.Add(forget);
        ToolStripMenuItem login = new ToolStripMenuItem("Open at Login");
        login.Checked = LoginEnabled();
        login.Click += delegate { SetLogin(!LoginEnabled()); };
        menu.Items.Add(login);
        menu.Items.Add(new ToolStripSeparator());
        ToolStripMenuItem quit = new ToolStripMenuItem("Quit mBridge");
        quit.Click += delegate { controller.Disconnect(); input.ReleaseAll(); CursorHider.Show(); tray.Visible = false; Application.Exit(); };
        menu.Items.Add(quit);
    }

    void Choose(Peer peer)
    {
        if (controller.Connected && controller.Target != null && controller.Target.Id == peer.Id)
        {
            paused = true;
            controller.Disconnect();
            return;
        }
        paused = false;
        settings.LastPeer = peer.Id;
        settings.Save();
        if (controller.Connected) controller.Disconnect();
        DropController();   // one role at a time: stop being controlled while we control
        controller.Connect(peer);
    }

    void EnterAddress()
    {
        string host = Ask("Computer address", "Only needed if the other computer isn't found by itself. It's its IP address, like 192.168.1.20.", settings.ManualHost ?? "");
        if (string.IsNullOrEmpty(host)) return;
        settings.ManualHost = host;
        settings.Save();
        Peer peer = new Peer();
        peer.Id = "manual:" + host;
        peer.Name = host;
        peer.Host = host;
        peer.Port = ListenPort;
        peer.Width = 1920;
        peer.Height = 1080;
        peer.Platform = "win";
        peer.Seen = DateTime.Now;
        paused = false;
        if (controller.Connected) controller.Disconnect();
        DropController();
        controller.Connect(peer);
    }

    static string Ask(string title, string text, string initial)
    {
        Form form = new Form();
        form.Text = title;
        form.FormBorderStyle = FormBorderStyle.FixedDialog;
        form.StartPosition = FormStartPosition.CenterScreen;
        form.MaximizeBox = false;
        form.MinimizeBox = false;
        form.TopMost = true;
        form.ClientSize = new Size(320, 120);
        Label label = new Label();
        label.Text = text;
        label.SetBounds(10, 10, 300, 40);
        TextBox box = new TextBox();
        box.Text = initial;
        box.SetBounds(10, 58, 300, 22);
        Button ok = new Button();
        ok.Text = "Connect";
        ok.DialogResult = DialogResult.OK;
        ok.SetBounds(150, 88, 75, 24);
        Button cancel = new Button();
        cancel.Text = "Cancel";
        cancel.DialogResult = DialogResult.Cancel;
        cancel.SetBounds(235, 88, 75, 24);
        form.AcceptButton = ok;
        form.CancelButton = cancel;
        form.Controls.AddRange(new Control[] { label, box, ok, cancel });
        return form.ShowDialog() == DialogResult.OK ? box.Text.Trim() : null;
    }

    /// Reconnects to the computer picked last, once it shows up.
    void AutoConnect()
    {
        if (paused || controller.Connected || controller.Connecting || current != null) return;
        foreach (Peer p in FreshPeers())
        {
            if (p.Id == settings.LastPeer) { controller.Connect(p); return; }
        }
    }

    /// The small logo next to a computer: an Apple for a Mac, four panes for Windows.
    Bitmap PlatformIcon(string platform)
    {
        Bitmap bmp;
        if (platformIcons.TryGetValue(platform, out bmp)) return bmp;
        bmp = new Bitmap(16, 16);
        using (Graphics g = Graphics.FromImage(bmp))
        using (Brush ink = new SolidBrush(Color.FromArgb(70, 70, 70)))
        {
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            if (platform == "mac")
            {
                g.FillEllipse(ink, 2, 5, 7, 10);
                g.FillEllipse(ink, 7, 5, 7, 10);
                g.FillEllipse(ink, 8, 0, 5, 3);                       // the leaf
                g.CompositingMode = System.Drawing.Drawing2D.CompositingMode.SourceCopy;
                g.FillEllipse(Brushes.Transparent, 11, 6, 6, 6);      // the bite
            }
            else
            {
                g.FillRectangle(ink, 1, 2, 6, 6);
                g.FillRectangle(ink, 9, 1, 6, 7);
                g.FillRectangle(ink, 1, 9, 6, 6);
                g.FillRectangle(ink, 9, 9, 6, 6);
            }
        }
        platformIcons[platform] = bmp;
        return bmp;
    }

    static Icon MonitorIcon(bool active)
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
            if (active) g.FillRectangle(brush, 3, 5, 25, 17); else g.DrawRectangle(pen, 3, 5, 25, 17);
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
    public static void Log(string message)
    {
        try
        {
            string dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "mBridge");
            Directory.CreateDirectory(dir);
            File.AppendAllText(Path.Combine(dir, "log.txt"), DateTime.Now.ToString("s") + " " + message + "\r\n");
        }
        catch { }
    }

    /// This PC's own secret, shown to computers it controls so they can remember it.
    string LoadOwnKey()
    {
        string path = Path.Combine(dataDir, "mykey.txt");
        try { string saved = File.ReadAllText(path).Trim(); if (saved.Length > 0) return saved; } catch { }
        byte[] bytes = new byte[16];
        using (RandomNumberGenerator rng = RandomNumberGenerator.Create()) { rng.GetBytes(bytes); }
        StringBuilder hex = new StringBuilder();
        foreach (byte b in bytes) hex.Append(b.ToString("x2"));
        try { Directory.CreateDirectory(dataDir); File.WriteAllText(path, hex.ToString()); } catch { }
        return hex.ToString();
    }

    // MARK: clipboard

    /// Text copied here is sent to the other computer, whichever way you are connected.
    /// Copies marked as secret (password managers) are never sent.
    void WatchClipboard()
    {
        uint seq = Native.GetClipboardSequenceNumber();
        if (seq == clipboardSeq) return;
        clipboardSeq = seq;
        NetworkStream stream = currentStream;
        if (stream == null && !controller.Connected) return;
        try
        {
            if (!Clipboard.ContainsText() || Clipboard.ContainsData("ExcludeClipboardContentFromMonitorProcessing")) return;
            string text = Clipboard.GetText();
            if (text.Length == 0 || text.Length > 256000) return;
            string line = "c " + Convert.ToBase64String(Encoding.UTF8.GetBytes(text.Replace("\r\n", "\n")));
            controller.Send(line);
            if (stream != null) Send(stream, line);
            Log("clipboard sent: " + text.Length + " characters");
        }
        catch (Exception e) { Log("clipboard send: " + e.Message); }
    }

    /// Text copied on the other computer arrives as "c <base64>".
    public void SetClipboard(string base64)
    {
        string text;
        try { text = Encoding.UTF8.GetString(Convert.FromBase64String(base64)); } catch (Exception e) { Log("clipboard unreadable: " + e.Message); return; }
        Log("clipboard received: " + text.Length + " characters");
        if (text.Length == 0) return;
        UiPost(delegate
        {
            try
            {
                Clipboard.SetDataObject(text.Replace("\r\n", "\n").Replace("\n", "\r\n"), true, 10, 100);
                clipboardSeq = Native.GetClipboardSequenceNumber();
            }
            catch (Exception e) { Log("clipboard: " + e.Message); }
        });
    }

    // MARK: network

    /// Shouts "I'm here" once a second so other computers can find this PC without any setup.
    void Beacon()
    {
        UdpClient udp = new UdpClient();
        udp.EnableBroadcast = true;
        while (true)
        {
            try
            {
                string name = Environment.MachineName.Replace("|", "/");
                string text = "mBridge|" + Environment.MachineName + "|" + name + "|" + Input.Width + "|" + Input.Height + "|" + ListenPort + "|win";
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

    /// Listens for other computers' "I'm here": "mBridge|id|name|width|height|port|platform".
    void Discover()
    {
        UdpClient udp;
        try
        {
            udp = new UdpClient();
            udp.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
            udp.Client.Bind(new IPEndPoint(IPAddress.Any, BeaconPort));
        }
        catch (Exception e) { Log("discovery: " + e.Message); return; }

        while (true)
        {
            try
            {
                IPEndPoint from = new IPEndPoint(IPAddress.Any, 0);
                string[] f = Encoding.UTF8.GetString(udp.Receive(ref from)).Split('|');
                if (f.Length < 6 || f[0] != "mBridge" || f[1] == Environment.MachineName) continue;
                Peer p = new Peer();
                p.Id = f[1];
                p.Name = f[2];
                p.Host = from.Address.ToString();
                p.Width = int.Parse(f[3], CultureInfo.InvariantCulture);
                p.Height = int.Parse(f[4], CultureInfo.InvariantCulture);
                p.Port = int.Parse(f[5], CultureInfo.InvariantCulture);
                p.Platform = f.Length > 6 ? f[6].Trim() : "win";
                p.Seen = DateTime.Now;
                lock (peers) { peers[p.Id] = p; }
            }
            catch (Exception) { Thread.Sleep(200); }
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

    /// Lets go of the computer that is controlling this PC.
    void DropController()
    {
        TcpClient c = current;
        if (c != null) { try { c.Close(); } catch { } }
    }

    /// Another computer controls this PC: its keyboard and mouse arrive here as lines.
    void Serve(TcpClient client)
    {
        System.Threading.Timer heartbeat = null;
        try
        {
            client.NoDelay = true;
            client.ReceiveTimeout = 5000;   // the controlling computer sends "." every second
            NetworkStream stream = client.GetStream();
            StreamReader reader = new StreamReader(stream, Encoding.UTF8);

            string[] hello = (reader.ReadLine() ?? "").Split(new char[] { ' ' }, 3);
            if (hello.Length < 3 || hello[0] != "hi") return;

            // The first computer to connect is remembered; any other is turned away until "Forget Paired Computer".
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

            // one role at a time: stop controlling while we are controlled
            UiPost(delegate { paused = true; controller.Disconnect(); });
            TcpClient previous = current;
            current = client;
            currentStream = stream;
            controllerName = hello[2];
            if (previous != null) { try { previous.Close(); } catch { } }

            Send(stream, "ok " + Input.Width + " " + Input.Height + " win");
            SetStatus("Controlled by " + hello[2]);
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
            if (current == client)
            {
                CursorHider.Show();
                current = null;
                currentStream = null;
                controllerName = null;
                SetStatus("Looking for a computer…");
            }
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
            Native.SetProcessDPIAware();   // real pixels, so the cursor lands where the other computer says
            Application.EnableVisualStyles();
            Application.Run(new App());
        }
    }
}
