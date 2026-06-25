using Microsoft.Win32;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Net;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Windows.Forms;
using Windows.Media.Control;
using Windows.Storage.Streams;

namespace NowPlaying;

// reads Windows media sessions and serves the OBS overlay + control panel,
// pushing live updates to the browser over a websocket.
internal static class Program
{
    private static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull
    };

    private static readonly string WebRoot = Path.Combine(AppContext.BaseDirectory, "wwwroot");
    private static readonly ConcurrentDictionary<Guid, Client> Clients = new();
    private static readonly object StateLock = new();
    private static readonly object ThumbLock = new();
    private static readonly Dictionary<string, (string sig, string? thumb)> ThumbCache = new();

    private static GlobalSystemMediaTransportControlsSessionManager? _mgr;
    private static StatePayload? _lastState;
    private static string _lastSignature = "";
    private static DateTimeOffset _lastSend = DateTimeOffset.MinValue;

    // null = follow whatever Windows calls "current", otherwise an app id to lock onto
    private static volatile string? _latchedId;
    private static volatile bool _showApp;

    private static volatile string _layout = "classic";
    private static volatile bool _hidePaused;
    private static volatile string _accent = "";

    private static readonly object SettingsLock = new();
    private static readonly string SettingsPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "nowplaying", "settings.json");

    private static int _port = 8787;

    [STAThread]
    private static void Main(string[] args)
    {
        _port = ParsePort(args, 8787);
        bool open = !args.Contains("--no-open");
        Application.EnableVisualStyles();

        var cts = new CancellationTokenSource();
        HttpListener? listener = null;
        string? error = null;

        // all the WinRT + server startup happens off the UI thread
        try { listener = Task.Run(() => StartAsync(cts.Token)).GetAwaiter().GetResult(); }
        catch (Exception e) { error = e.Message; }

        if (listener is null)
        {
            MessageBox.Show(
                (error ?? "Startup failed.") +
                "\n\nThis needs to run on Windows 10/11 (not inside WSL), and the port has to be free.",
                "Yet Another Now Playing Widget", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        using var tray = new NotifyIcon
        {
            Icon = AppIcon(),
            Text = "Yet Another Now Playing Widget",
            Visible = true,
        };
        var menu = new ContextMenuStrip();
        menu.Items.Add("Open control panel", null, (_, _) => OpenUrl($"http://localhost:{_port}/control"));
        menu.Items.Add("Copy overlay URL", null, (_, _) => { try { Clipboard.SetText($"http://localhost:{_port}/overlay"); } catch { } });
        menu.Items.Add(new ToolStripSeparator());
        var startupItem = new ToolStripMenuItem("Launch at login") { CheckOnClick = true };
        startupItem.Click += (_, _) => ApplyStartup(startupItem.Checked);
        menu.Items.Add(startupItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Quit", null, (_, _) =>
        {
            tray.Visible = false;
            cts.Cancel();
            try { listener.Stop(); } catch { }
            Application.ExitThread();
        });
        menu.Opening += (_, _) => startupItem.Checked = StartupEnabled();
        tray.ContextMenuStrip = menu;
        tray.DoubleClick += (_, _) => OpenUrl($"http://localhost:{_port}/control");

        if (open)
            OpenUrl($"http://localhost:{_port}/control");
        else
            tray.ShowBalloonTip(4000, "Yet Another Now Playing Widget",
                "Running in the tray. Double-click to open the control panel.", ToolTipIcon.Info);

        Application.Run();

        cts.Cancel();
        try { listener.Stop(); } catch { }
    }

    // starts GSMTC + the local web server; returns the listener once it's up
    private static async Task<HttpListener> StartAsync(CancellationToken ct)
    {
        _mgr = await GlobalSystemMediaTransportControlsSessionManager.RequestAsync();
        LoadSettings();

        var listener = new HttpListener();
        listener.Prefixes.Add($"http://localhost:{_port}/");
        listener.Start();

        _ = AcceptLoop(listener, ct);
        _ = PollLoop(ct);
        await RefreshAsync(force: true);
        return listener;
    }

    private static async Task PollLoop(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try { await RefreshAsync(force: false); }
            catch (Exception e) { Console.Error.WriteLine("poll error: " + e.Message); }
            try { await Task.Delay(1000, ct); }
            catch (OperationCanceledException) { break; }
        }
    }

    private static async Task RefreshAsync(bool force)
    {
        if (_mgr is null) return;

        var state = await BuildStateAsync(_mgr);
        string sig = Signature(state);
        bool changed = sig != _lastSignature;
        bool heartbeat = (DateTimeOffset.UtcNow - _lastSend).TotalSeconds >= 4;

        lock (StateLock)
        {
            _lastState = state;
            _lastSignature = sig;
        }

        if (changed || heartbeat || force)
        {
            state.Ts = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            Broadcast(Serialize(state));
            _lastSend = DateTimeOffset.UtcNow;
        }
    }

    private static async Task<StatePayload> BuildStateAsync(GlobalSystemMediaTransportControlsSessionManager mgr)
    {
        var payload = new StatePayload();

        GlobalSystemMediaTransportControlsSession? current = null;
        try { current = mgr.GetCurrentSession(); } catch { }
        payload.CurrentId = current?.SourceAppUserModelId;

        IReadOnlyList<GlobalSystemMediaTransportControlsSession> sessions;
        try { sessions = mgr.GetSessions(); }
        catch { sessions = Array.Empty<GlobalSystemMediaTransportControlsSession>(); }

        foreach (var s in sessions)
        {
            var dto = new SessionDto();
            try { dto.Id = s.SourceAppUserModelId ?? ""; } catch { }
            if (string.IsNullOrEmpty(dto.Id)) continue;
            dto.App = Pretty(dto.Id);

            try { dto.Status = s.GetPlaybackInfo()?.PlaybackStatus.ToString() ?? "Unknown"; } catch { }
            dto.IsCurrent = dto.Id == payload.CurrentId;

            try
            {
                var mp = await s.TryGetMediaPropertiesAsync();
                if (mp is not null)
                {
                    dto.Title = NullIfEmpty(mp.Title);
                    dto.Artist = NullIfEmpty(mp.Artist);
                    dto.Album = NullIfEmpty(mp.AlbumTitle);
                    dto.Thumbnail = await GetThumbCachedAsync(dto.Id, dto.Title, dto.Artist, mp.Thumbnail);
                }
            }
            catch { }

            try
            {
                var tl = s.GetTimelineProperties();
                dto.Position = tl.Position.TotalSeconds;
                dto.Duration = tl.EndTime.TotalSeconds;
            }
            catch { }

            payload.Sessions.Add(dto);
        }

        payload.LatchedId = _latchedId;
        payload.ShowApp = _showApp;
        payload.HidePaused = _hidePaused;
        payload.Layout = _layout;
        payload.LaunchOnStartup = StartupEnabled();
        payload.Accent = _accent.Length == 0 ? null : _accent;
        payload.Active = SelectActive(payload.Sessions, payload.CurrentId, _latchedId);
        payload.LatchedName = LatchName(payload.Sessions, _latchedId);
        return payload;
    }

    private static SessionDto? SelectActive(List<SessionDto> sessions, string? currentId, string? latchedId)
    {
        // when latched, return null if that app is gone so the overlay waits for it
        // instead of grabbing whatever took over
        if (!string.IsNullOrEmpty(latchedId))
            return sessions.FirstOrDefault(s => s.Id == latchedId);

        return sessions.FirstOrDefault(s => s.Id == currentId)
               ?? sessions.FirstOrDefault(s => s.Status == "Playing")
               ?? sessions.FirstOrDefault();
    }

    private static string? LatchName(List<SessionDto> sessions, string? latchedId)
        => string.IsNullOrEmpty(latchedId) ? null
           : (sessions.FirstOrDefault(s => s.Id == latchedId)?.App ?? Pretty(latchedId));

    private static async Task<string?> GetThumbCachedAsync(string id, string? title, string? artist, IRandomAccessStreamReference? r)
    {
        string sig = (title ?? "") + "" + (artist ?? "");
        lock (ThumbLock)
        {
            if (ThumbCache.TryGetValue(id, out var v) && v.sig == sig)
                return v.thumb; // same track, reuse it instead of decoding again
        }

        string? thumb = null;
        try { thumb = await ReadThumbAsync(r); } catch { }

        lock (ThumbLock) { ThumbCache[id] = (sig, thumb); }
        return thumb;
    }

    private static async Task<string?> ReadThumbAsync(IRandomAccessStreamReference? r)
    {
        if (r is null) return null;
        using var stream = await r.OpenReadAsync();
        uint size = (uint)stream.Size;
        if (size == 0) return null;

        using var reader = new DataReader(stream);
        await reader.LoadAsync(size);
        var bytes = new byte[size];
        reader.ReadBytes(bytes);

        string mime = string.IsNullOrEmpty(stream.ContentType) ? MimeOf(bytes) : stream.ContentType;
        return $"data:{mime};base64,{Convert.ToBase64String(bytes)}";
    }

    private static async Task AcceptLoop(HttpListener l, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            HttpListenerContext ctx;
            try { ctx = await l.GetContextAsync(); }
            catch { break; }
            _ = HandleRequest(ctx);
        }
    }

    private static async Task HandleRequest(HttpListenerContext ctx)
    {
        try
        {
            string path = ctx.Request.Url?.AbsolutePath ?? "/";

            if (path == "/ws")
            {
                if (!ctx.Request.IsWebSocketRequest) { ctx.Response.StatusCode = 400; ctx.Response.Close(); return; }
                var wsc = await ctx.AcceptWebSocketAsync(null);
                await HandleSocket(wsc.WebSocket);
                return;
            }

            string file = path switch
            {
                "/" => "control.html",
                "/control" => "control.html",
                "/overlay" => "overlay.html",
                _ => path.TrimStart('/')
            };

            string full = Path.GetFullPath(Path.Combine(WebRoot, file));
            if (!full.StartsWith(WebRoot, StringComparison.OrdinalIgnoreCase) || !File.Exists(full))
            {
                ctx.Response.StatusCode = 404;
                ctx.Response.Close();
                return;
            }

            byte[] bytes = await File.ReadAllBytesAsync(full);
            ctx.Response.ContentType = ContentType(full);
            ctx.Response.ContentLength64 = bytes.Length;
            ctx.Response.Headers["Cache-Control"] = "no-store";
            await ctx.Response.OutputStream.WriteAsync(bytes);
            ctx.Response.Close();
        }
        catch
        {
            try { ctx.Response.Abort(); } catch { }
        }
    }

    private static async Task HandleSocket(WebSocket ws)
    {
        var key = Guid.NewGuid();
        var client = new Client(ws);
        Clients[key] = client;
        try
        {
            StatePayload? snap;
            lock (StateLock) { snap = _lastState; }
            if (snap is not null)
            {
                snap.Ts = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
                await client.SendAsync(Serialize(snap));
            }

            var buf = new byte[16 * 1024];
            while (ws.State == WebSocketState.Open)
            {
                var res = await ws.ReceiveAsync(new ArraySegment<byte>(buf), CancellationToken.None);
                if (res.MessageType == WebSocketMessageType.Close) break;
                if (res.Count > 0) HandleClientMessage(Encoding.UTF8.GetString(buf, 0, res.Count));
            }
        }
        catch { }
        finally
        {
            Clients.TryRemove(key, out _);
            try { if (ws.State == WebSocketState.Open) await ws.CloseAsync(WebSocketCloseStatus.NormalClosure, "", CancellationToken.None); }
            catch { }
            ws.Dispose();
        }
    }

    private static void HandleClientMessage(string msg)
    {
        try
        {
            using var doc = JsonDocument.Parse(msg);
            var root = doc.RootElement;
            string? type = root.TryGetProperty("type", out var t) ? t.GetString() : null;
            if (type == "latch")
            {
                string? id = root.TryGetProperty("id", out var i) && i.ValueKind == JsonValueKind.String ? i.GetString() : null;
                ApplyLatch(id);
            }
            else if (type == "showApp")
            {
                ApplyShowApp(root.TryGetProperty("value", out var vv) && vv.ValueKind == JsonValueKind.True);
            }
            else if (type == "hidePaused")
            {
                ApplyHidePaused(root.TryGetProperty("value", out var vv) && vv.ValueKind == JsonValueKind.True);
            }
            else if (type == "setLayout")
            {
                string name = root.TryGetProperty("value", out var vv) && vv.ValueKind == JsonValueKind.String ? (vv.GetString() ?? "classic") : "classic";
                ApplyLayout(name);
            }
            else if (type == "launchOnStartup")
            {
                ApplyStartup(root.TryGetProperty("value", out var vv) && vv.ValueKind == JsonValueKind.True);
            }
            else if (type == "setAccent")
            {
                ApplyAccent(root.TryGetProperty("value", out var vv) && vv.ValueKind == JsonValueKind.String ? vv.GetString() : "");
            }
        }
        catch { }
    }

    // latching is instant: recompute "active" from the last snapshot and push, no WinRT round-trip
    private static void ApplyLatch(string? id)
    {
        _latchedId = string.IsNullOrEmpty(id) ? null : id;
        StatePayload? snap;
        lock (StateLock) { snap = _lastState; }
        if (snap is null) return;

        snap.LatchedId = _latchedId;
        snap.Active = SelectActive(snap.Sessions, snap.CurrentId, _latchedId);
        snap.LatchedName = LatchName(snap.Sessions, _latchedId);
        _lastSignature = Signature(snap);
        snap.Ts = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        Broadcast(Serialize(snap));
        _lastSend = DateTimeOffset.UtcNow;

        SaveSettings();
        Console.WriteLine(_latchedId is null
            ? "Latch: following current (auto)"
            : $"Latch: locked onto {Pretty(_latchedId)}");
    }

    private static void RebroadcastSnapshot(Action<StatePayload> mutate)
    {
        SaveSettings();
        StatePayload? snap;
        lock (StateLock) { snap = _lastState; }
        if (snap is null) return;

        mutate(snap);
        _lastSignature = Signature(snap);
        snap.Ts = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        Broadcast(Serialize(snap));
        _lastSend = DateTimeOffset.UtcNow;
    }

    private static void ApplyShowApp(bool value)
    {
        _showApp = value;
        RebroadcastSnapshot(s => s.ShowApp = value);
        Console.WriteLine($"Overlay source label: {(value ? "shown" : "hidden")}");
    }

    private static void ApplyHidePaused(bool value)
    {
        _hidePaused = value;
        RebroadcastSnapshot(s => s.HidePaused = value);
        Console.WriteLine($"Hide when paused: {(value ? "on" : "off")}");
    }

    private static void ApplyLayout(string name)
    {
        _layout = string.IsNullOrWhiteSpace(name) ? "classic" : name;
        RebroadcastSnapshot(s => s.Layout = _layout);
        Console.WriteLine($"Layout: {_layout}");
    }

    private static void ApplyStartup(bool value)
    {
        SetStartup(value);
        RebroadcastSnapshot(s => s.LaunchOnStartup = value);
    }

    private static void ApplyAccent(string? hex)
    {
        _accent = NormalizeHex(hex);
        RebroadcastSnapshot(s => s.Accent = _accent.Length == 0 ? null : _accent);
        Console.WriteLine($"Accent: {(_accent.Length == 0 ? "default" : _accent)}");
    }

    // accepts "#rrggbb", "rrggbb", or "rgb"; returns "#rrggbb" or "" for default/invalid
    private static string NormalizeHex(string? hex)
    {
        if (string.IsNullOrWhiteSpace(hex)) return "";
        string h = hex.Trim().TrimStart('#');
        if (h.Length == 3) h = $"{h[0]}{h[0]}{h[1]}{h[1]}{h[2]}{h[2]}";
        if (h.Length != 6) return "";
        foreach (char c in h) if (!Uri.IsHexDigit(c)) return "";
        return "#" + h.ToLowerInvariant();
    }

    private static void LoadSettings()
    {
        try
        {
            if (!File.Exists(SettingsPath)) return;
            var s = JsonSerializer.Deserialize<Settings>(File.ReadAllText(SettingsPath), Json);
            if (s is null) return;
            _latchedId = string.IsNullOrEmpty(s.LatchedId) ? null : s.LatchedId;
            _showApp = s.ShowApp;
            _hidePaused = s.HidePaused;
            _layout = string.IsNullOrWhiteSpace(s.Layout) ? "classic" : s.Layout;
            _accent = NormalizeHex(s.Accent);
            if (_latchedId is not null) Console.WriteLine($"Restored latch: {Pretty(_latchedId)} (waiting for it if not running yet)");
        }
        catch { }
    }

    private static void SaveSettings()
    {
        try
        {
            lock (SettingsLock)
            {
                Directory.CreateDirectory(Path.GetDirectoryName(SettingsPath)!);
                File.WriteAllText(SettingsPath, JsonSerializer.Serialize(
                    new Settings { LatchedId = _latchedId, ShowApp = _showApp, HidePaused = _hidePaused, Layout = _layout, Accent = _accent.Length == 0 ? null : _accent }, Json));
            }
        }
        catch { }
    }

    private static void Broadcast(string json)
    {
        foreach (var kv in Clients)
        {
            var key = kv.Key;
            _ = kv.Value.SendAsync(json).ContinueWith(t =>
            {
                if (t.IsFaulted) Clients.TryRemove(key, out _);
            }, TaskScheduler.Default);
        }
    }

    private static string Serialize(StatePayload p) => JsonSerializer.Serialize(p, Json);

    // change-detection key. skips position/ts since those tick every second (client interpolates)
    private static string Signature(StatePayload p)
    {
        var sb = new StringBuilder();
        sb.Append(p.CurrentId).Append('|').Append(p.LatchedId).Append('|').Append(p.LatchedName)
          .Append('|').Append(p.Active?.Id).Append('|').Append(p.ShowApp ? '1' : '0')
          .Append('|').Append(p.HidePaused ? '1' : '0').Append('|').Append(p.Layout)
          .Append('|').Append(p.LaunchOnStartup ? '1' : '0').Append('|').Append(p.Accent).Append("||");
        foreach (var s in p.Sessions)
        {
            sb.Append(s.Id).Append('~').Append(s.Title).Append('~').Append(s.Artist).Append('~')
              .Append(s.Album).Append('~').Append(s.Status).Append('~').Append(s.IsCurrent ? '1' : '0')
              .Append('~').Append(s.Thumbnail is null ? '0' : '1').Append('~').Append((int)s.Duration).Append(';');
        }
        return sb.ToString();
    }

    private static string? NullIfEmpty(string? s) => string.IsNullOrWhiteSpace(s) ? null : s;

    private static string Pretty(string aumid)
    {
        if (string.IsNullOrEmpty(aumid)) return "Unknown";

        var known = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["spotify.exe"] = "Spotify",
            ["chrome"] = "Google Chrome",
            ["msedge"] = "Microsoft Edge",
            ["firefox"] = "Firefox",
            ["brave"] = "Brave",
            ["vlc.exe"] = "VLC",
            ["foobar2000.exe"] = "foobar2000",
            ["AppleInc.AppleMusicWin"] = "Apple Music",
            ["308046B0AF4A39CB"] = "Firefox",
        };
        if (known.TryGetValue(aumid, out var n)) return n;

        string s = aumid;
        int bang = s.IndexOf('!');
        if (bang >= 0) s = s[..bang];           // drop "!AppId"
        int slash = s.LastIndexOf('\\');
        if (slash >= 0) s = s[(slash + 1)..];   // drop a path
        if (s.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) s = s[..^4];
        int us = s.IndexOf('_');
        if (us > 0) s = s[..us];                // drop "_packagehash"

        if (s.Contains("Edge", StringComparison.OrdinalIgnoreCase)) return "Microsoft Edge";
        if (s.Contains("Spotify", StringComparison.OrdinalIgnoreCase)) return "Spotify";
        if (s.Contains("Chrome", StringComparison.OrdinalIgnoreCase)) return "Google Chrome";
        if (s.Contains("Firefox", StringComparison.OrdinalIgnoreCase)) return "Firefox";

        // AUMIDs look like "Vendor.Product.HASH", so keep the last human-looking token and
        // skip the long all-caps/hex hash chunks (e.g. "Helium.H5ZU..." -> "Helium")
        var tokens = s.Split('.', StringSplitOptions.RemoveEmptyEntries);
        string? best = null;
        foreach (var tk in tokens) if (!IsHashLike(tk)) best = tk;
        s = best ?? (tokens.Length > 0 ? tokens[0] : aumid);

        return s.Length > 0 ? char.ToUpper(s[0]) + s[1..] : aumid;
    }

    private static bool IsHashLike(string t) =>
        t.Length >= 12 && t.All(c => char.IsDigit(c) || (char.IsLetter(c) && char.IsUpper(c)));

    private static string MimeOf(byte[] b) =>
        b.Length >= 3 && b[0] == 0xFF && b[1] == 0xD8 ? "image/jpeg" :
        b.Length >= 8 && b[0] == 0x89 && b[1] == 0x50 ? "image/png" :
        b.Length >= 2 && b[0] == 0x42 && b[1] == 0x4D ? "image/bmp" :
        b.Length >= 4 && b[0] == 0x52 && b[1] == 0x49 ? "image/webp" :
        "image/png";

    private static string ContentType(string path) => Path.GetExtension(path).ToLowerInvariant() switch
    {
        ".html" => "text/html; charset=utf-8",
        ".js" => "text/javascript; charset=utf-8",
        ".css" => "text/css; charset=utf-8",
        ".json" => "application/json; charset=utf-8",
        ".svg" => "image/svg+xml",
        ".png" => "image/png",
        ".ico" => "image/x-icon",
        _ => "application/octet-stream"
    };

    private static int ParsePort(string[] args, int def)
    {
        for (int i = 0; i < args.Length - 1; i++)
            if (args[i] == "--port" && int.TryParse(args[i + 1], out int p))
                return p;
        return def;
    }

    private static void OpenUrl(string url)
    {
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
        catch { }
    }

    // a little green music note, drawn at runtime so there's no .ico to ship
    private static Icon AppIcon()
    {
        try
        {
            using var bmp = new Bitmap(32, 32);
            using (var g = Graphics.FromImage(bmp))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
                using var font = new Font("Segoe UI Symbol", 24f, FontStyle.Bold, GraphicsUnit.Pixel);
                using var brush = new SolidBrush(Color.FromArgb(0x1d, 0xb9, 0x54));
                var fmt = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
                g.DrawString("♪", font, brush, new RectangleF(0, 0, 32, 32), fmt);
            }
            return Icon.FromHandle(bmp.GetHicon());
        }
        catch { return SystemIcons.Application; }
    }

    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string RunValueName = "YetAnotherNowPlayingWidget";

    private static bool StartupEnabled()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath);
            return key?.GetValue(RunValueName) is string;
        }
        catch { return false; }
    }

    private static void SetStartup(bool enabled)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKeyPath);
            if (key is null) return;
            if (enabled)
            {
                string? exe = Environment.ProcessPath;
                if (string.IsNullOrEmpty(exe)) return;
                key.SetValue(RunValueName, $"\"{exe}\" --no-open" + (_port != 8787 ? $" --port {_port}" : ""));
            }
            else key.DeleteValue(RunValueName, false);
        }
        catch { }
    }

    private sealed class Client
    {
        private readonly WebSocket _ws;
        private readonly SemaphoreSlim _lock = new(1, 1);
        public Client(WebSocket ws) => _ws = ws;

        public async Task SendAsync(string s)
        {
            if (_ws.State != WebSocketState.Open) return;
            byte[] bytes = Encoding.UTF8.GetBytes(s);
            await _lock.WaitAsync();
            try { await _ws.SendAsync(bytes, WebSocketMessageType.Text, true, CancellationToken.None); }
            finally { _lock.Release(); }
        }
    }

    private sealed class SessionDto
    {
        public string Id { get; set; } = "";
        public string App { get; set; } = "";
        public string? Title { get; set; }
        public string? Artist { get; set; }
        public string? Album { get; set; }
        public string Status { get; set; } = "Unknown";
        public bool IsCurrent { get; set; }
        public string? Thumbnail { get; set; }
        public double Position { get; set; }
        public double Duration { get; set; }
    }

    private sealed class StatePayload
    {
        public string Type { get; set; } = "state";
        public List<SessionDto> Sessions { get; set; } = new();
        public string? CurrentId { get; set; }
        public string? LatchedId { get; set; }
        public string? LatchedName { get; set; }
        public bool ShowApp { get; set; }
        public bool HidePaused { get; set; }
        public string Layout { get; set; } = "classic";
        public bool LaunchOnStartup { get; set; }
        public string? Accent { get; set; }
        public SessionDto? Active { get; set; }
        public long Ts { get; set; }
    }

    private sealed class Settings
    {
        public string? LatchedId { get; set; }
        public bool ShowApp { get; set; }
        public bool HidePaused { get; set; }
        public string Layout { get; set; } = "classic";
        public string? Accent { get; set; }
    }
}
