#Requires -Version 5.1
<#
    Win11 Customizer - Desktop-Kacheln
    Läuft unsichtbar im Hintergrund und zeigt deine Kacheln auf dem Desktop.
    Einstellungen: %APPDATA%\Win11Customizer\tiles.json (wird vom Customizer geschrieben)
    - Linksklick: öffnen   - Ziehen: verschieben (rastet ein)   - Rechtsklick: Menü
#>
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$AppDir  = Join-Path $env:APPDATA 'Win11Customizer'
$CfgFile = Join-Path $AppDir 'tiles.json'
$LogFile = Join-Path $AppDir 'tiles-error.log'
function Write-Log([string]$m) {
    try { Add-Content -Path $LogFile -Value ("[{0}] {1}" -f (Get-Date -Format 's'), $m) -Encoding UTF8 } catch {}
}

# Nur eine Instanz
$created = $false
$mutex = [System.Threading.Mutex]::new($true, 'Local\Win11CustomizerTiles', [ref]$created)
if (-not $created) { $mutex.Dispose(); return }

if (-not ('W11T.Native' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace W11T {
    public static class Native {
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindow(string c, string w);
        [DllImport("user32.dll", EntryPoint = "SetWindowLongPtr")] static extern IntPtr SetWindowLongPtr64(IntPtr h, int i, IntPtr v);
        [DllImport("user32.dll", EntryPoint = "SetWindowLong")] static extern int SetWindowLong32(IntPtr h, int i, int v);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtr")] static extern IntPtr GetWindowLongPtr64(IntPtr h, int i);
        [DllImport("user32.dll", EntryPoint = "GetWindowLong")] static extern int GetWindowLong32(IntPtr h, int i);
        [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
        [DllImport("kernel32.dll")] static extern bool GetSystemTimes(out long idle, out long kernel, out long user);
        [DllImport("kernel32.dll")] public static extern ulong GetTickCount64();
        [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);

        [StructLayout(LayoutKind.Sequential)]
        public class MEMSTAT { public uint dwLength = 64; public uint load; public ulong total, avail, tp, ap, tv, av, ae; }
        [DllImport("kernel32.dll")] static extern bool GlobalMemoryStatusEx([In, Out] MEMSTAT m);

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct SHFILEINFO {
            public IntPtr hIcon; public int iIcon; public uint dwAttributes;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szDisplayName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)] public string szTypeName;
        }
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SHGetFileInfo(string p, uint attr, ref SHFILEINFO sfi, uint cb, uint flags);
        [DllImport("shell32.dll", EntryPoint = "SHGetImageList")] static extern int SHGetImageList(int i, ref Guid riid, out IntPtr ppv);
        [DllImport("comctl32.dll")] static extern IntPtr ImageList_GetIcon(IntPtr himl, int i, int flags);

        static IntPtr SetLong(IntPtr h, int i, IntPtr v) { return IntPtr.Size == 8 ? SetWindowLongPtr64(h, i, v) : new IntPtr(SetWindowLong32(h, i, v.ToInt32())); }
        static IntPtr GetLong(IntPtr h, int i) { return IntPtr.Size == 8 ? GetWindowLongPtr64(h, i) : new IntPtr(GetWindowLong32(h, i)); }

        public static IntPtr Progman() { return FindWindow("Progman", null); }
        public static void PinToDesktop(IntPtr h) {
            long ex = GetLong(h, -20).ToInt64();
            ex = (ex | 0x80L) & ~0x40000L;          // ToolWindow (kein Alt-Tab), kein AppWindow
            SetLong(h, -20, new IntPtr(ex));
            IntPtr pm = Progman();
            if (pm != IntPtr.Zero) SetLong(h, -8, pm); // Besitzer = Desktop -> bleibt bei Win+D sichtbar
            SendToBottom(h);
        }
        public static void SendToBottom(IntPtr h) { SetWindowPos(h, new IntPtr(1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010); }

        static long li, lk, lu;
        public static double Cpu() {
            long i, k, u;
            if (!GetSystemTimes(out i, out k, out u)) return 0;
            long di = i - li, dk = k - lk, du = u - lu;
            li = i; lk = k; lu = u;
            long tot = dk + du;
            if (tot <= 0) return 0;
            return Math.Max(0, Math.Min(100, (tot - di) * 100.0 / tot));
        }
        public static double[] Ram() {
            MEMSTAT m = new MEMSTAT();
            GlobalMemoryStatusEx(m);
            return new double[] { m.load, m.total / 1073741824.0, (m.total - m.avail) / 1073741824.0 };
        }
        public static IntPtr GetIcon(string path) {
            SHFILEINFO s = new SHFILEINFO();
            try {
                IntPtr r = SHGetFileInfo(path, 0, ref s, (uint)Marshal.SizeOf(s), 0x4000);   // SYSICONINDEX
                if (r != IntPtr.Zero) {
                    Guid iid = new Guid("46EB5926-582E-4017-9FDF-E8998DAA0950");
                    IntPtr himl;
                    if (SHGetImageList(2, ref iid, out himl) == 0 && himl != IntPtr.Zero) {      // 48x48
                        IntPtr h = ImageList_GetIcon(himl, s.iIcon, 1);
                        if (h != IntPtr.Zero) return h;
                    }
                }
            } catch { }
            s = new SHFILEINFO();
            SHGetFileInfo(path, 0, ref s, (uint)Marshal.SizeOf(s), 0x100);                    // 32x32 Fallback
            return s.hIcon;
        }
    }
}
'@
}

if (-not ('W11T.Sensors' -as [type])) {
Add-Type -ReferencedAssemblies 'System.Core' -TypeDefinition @'
using System;
using System.IO;
using System.IO.MemoryMappedFiles;
using System.Text;
using System.Collections.Generic;
using System.Text.RegularExpressions;
using System.Diagnostics;
using System.Globalization;
using System.Threading;
using System.Net.NetworkInformation;
using System.Net.Sockets;
namespace W11T {
    public class HwReading { public string Sensor = ""; public string Label = ""; public int Type; public string Unit = ""; public double Value; }

    public class HwSummary {
        public bool HwOk; public string HwError = ""; public bool GpuFromNvSmi;
        public double CpuTemp = double.NaN, CpuPower = double.NaN, CpuClock = double.NaN;
        public string GpuName = "";
        public double GpuTemp = double.NaN, GpuHotSpot = double.NaN, GpuLoad = double.NaN, GpuVramMb = double.NaN, GpuVramTotalMb = double.NaN,
                      GpuVramPct = double.NaN, GpuPower = double.NaN, GpuFanRpm = double.NaN, GpuFanPct = double.NaN, GpuClock = double.NaN;
        public string BoardName = "";
        public double BoardTemp = double.NaN;
        public List<HwReading> BoardTemps = new List<HwReading>();
        public List<HwReading> Fans = new List<HwReading>();
    }

    public static class NvSmi {
        public static double[] Last;          // temp, load, memUsed, memTotal, power, fanPct, clock
        public static string Name = "";
        static Timer timer; static int busy; static string exe;
        public static bool Start() {
            if (timer != null) return true;
            string[] cand = {
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "nvidia-smi.exe"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), @"NVIDIA Corporation\NVSMI\nvidia-smi.exe") };
            foreach (var c in cand) { if (File.Exists(c)) { exe = c; break; } }
            if (exe == null) return false;
            timer = new Timer(Poll, null, 0, 2000);
            return true;
        }
        static void Poll(object o) {
            if (Interlocked.Exchange(ref busy, 1) == 1) return;
            try {
                var psi = new ProcessStartInfo(exe, "--query-gpu=name,temperature.gpu,utilization.gpu,memory.used,memory.total,power.draw,fan.speed,clocks.gr --format=csv,noheader,nounits");
                psi.UseShellExecute = false; psi.RedirectStandardOutput = true; psi.CreateNoWindow = true;
                using (var p = Process.Start(psi)) {
                    string line = p.StandardOutput.ReadLine();
                    p.WaitForExit(3000);
                    if (!string.IsNullOrEmpty(line)) {
                        var parts = line.Split(',');
                        if (parts.Length >= 8) {
                            Name = parts[0].Trim();
                            var v = new double[7];
                            for (int i = 1; i < 8; i++) {
                                double d;
                                v[i - 1] = double.TryParse(parts[i].Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out d) ? d : double.NaN;
                            }
                            Last = v;
                        }
                    }
                }
            } catch { }
            finally { busy = 0; }
        }
    }

    public static class Net {
        static long lastRx = -1, lastTx = -1; static DateTime lastT = DateTime.MinValue;
        public static double Down, Up; public static string Adapter = "", Ip = "";
        static string[] skip = { "virtual", "hyper-v", "vmware", "virtualbox", "loopback", "bluetooth", "tap-", "wan miniport", "teredo", "isatap", "npcap" };
        public static void Poll() {
            long rx = 0, tx = 0; string bestName = "", bestIp = "";
            try {
                foreach (var ni in NetworkInterface.GetAllNetworkInterfaces()) {
                    if (ni.OperationalStatus != OperationalStatus.Up) continue;
                    if (ni.NetworkInterfaceType == NetworkInterfaceType.Loopback || ni.NetworkInterfaceType == NetworkInterfaceType.Tunnel) continue;
                    string d = (ni.Description + " " + ni.Name).ToLowerInvariant();
                    bool bad = false; foreach (var k in skip) { if (d.Contains(k)) { bad = true; break; } }
                    if (bad) continue;
                    var st = ni.GetIPStatistics();
                    rx += st.BytesReceived; tx += st.BytesSent;
                    var props = ni.GetIPProperties();
                    if (bestName == "" && props.GatewayAddresses.Count > 0) {
                        bestName = ni.Name;
                        foreach (var a in props.UnicastAddresses) { if (a.Address.AddressFamily == AddressFamily.InterNetwork) { bestIp = a.Address.ToString(); break; } }
                    }
                }
            } catch { }
            var now = DateTime.UtcNow;
            if (lastRx >= 0) {
                double sec = (now - lastT).TotalSeconds;
                if (sec > 0.2) { Down = Math.Max(0, (rx - lastRx) / sec); Up = Math.Max(0, (tx - lastTx) / sec); }
            }
            lastRx = rx; lastTx = tx; lastT = now;
            Adapter = bestName; Ip = bestIp;
        }
    }

    public static class Sensors {
        public static HwReading[] ReadHwInfo(out string error) {
            error = "";
            try {
                using (var mmf = MemoryMappedFile.OpenExisting("Global\\HWiNFO_SENS_SM2", MemoryMappedFileRights.Read))
                using (var acc = mmf.CreateViewAccessor(0, 0, MemoryMappedFileAccess.Read)) {
                    uint sig = acc.ReadUInt32(0);
                    if (sig != 0x53695748) { error = "HWiNFO Shared Memory ist aus"; return null; }
                    long offS = acc.ReadUInt32(20), sizeS = acc.ReadUInt32(24), numS = acc.ReadUInt32(28);
                    long offR = acc.ReadUInt32(32), sizeR = acc.ReadUInt32(36), numR = acc.ReadUInt32(40);
                    var names = new string[numS];
                    for (long i = 0; i < numS; i++) names[i] = Str(acc, offS + i * sizeS + 8, 128);
                    var list = new HwReading[numR];
                    for (long i = 0; i < numR; i++) {
                        long b = offR + i * sizeR;
                        var r = new HwReading();
                        r.Type = (int)acc.ReadUInt32(b);
                        uint si = acc.ReadUInt32(b + 4);
                        r.Sensor = si < numS ? names[si] : "";
                        r.Label = Str(acc, b + 12, 128);
                        r.Unit = Str(acc, b + 268, 16);
                        r.Value = acc.ReadDouble(b + 284);
                        list[i] = r;
                    }
                    return list;
                }
            } catch (FileNotFoundException) { error = "HWiNFO läuft nicht (oder Shared Memory aus)"; return null; }
            catch (Exception e) { error = e.Message; return null; }
        }
        static string Str(MemoryMappedViewAccessor a, long pos, int len) {
            byte[] buf = new byte[len];
            a.ReadArray(pos, buf, 0, len);
            int n = Array.IndexOf(buf, (byte)0); if (n < 0) n = len;
            return Encoding.Default.GetString(buf, 0, n).Trim();
        }
        static double Avg(List<double> l) { if (l.Count == 0) return double.NaN; double s = 0; foreach (var v in l) s += v; return s / l.Count; }
        static string Between(string s) {
            int a = s.IndexOf("]: "); if (a < 0) return s;
            string r = s.Substring(a + 3); int b = r.IndexOf(':'); if (b > 0) r = r.Substring(0, b);
            return r.Trim();
        }

        public static HwSummary Summarize(bool useNvSmi) {
            var s = new HwSummary();
            string err;
            var rs = ReadHwInfo(out err);
            if (rs != null) {
                s.HwOk = true;
                var pT = new List<double>(); var cT = new List<double>(); var pC = new List<double>(); var cC = new List<double>();
                double tctl = double.NaN, pkg = double.NaN;
                string board = null;
                foreach (var r in rs) {
                    bool gpu = r.Sensor.StartsWith("GPU [");
                    if (!gpu) {
                        if (r.Type == 1) {
                            if (Regex.IsMatch(r.Label, @"^P-core \d+$")) pT.Add(r.Value);
                            else if (Regex.IsMatch(r.Label, @"^Core ?\d+$")) cT.Add(r.Value);
                            else if (r.Label == "CPU (Tctl/Tdie)" && double.IsNaN(tctl)) tctl = r.Value;
                            else if (r.Label == "CPU Package" && double.IsNaN(pkg)) pkg = r.Value;
                        } else if (r.Type == 6) {
                            if (Regex.IsMatch(r.Label, @"^P-core \d+ Clock")) pC.Add(r.Value);
                            else if (Regex.IsMatch(r.Label, @"^Core ?\d+ Clock")) cC.Add(r.Value);
                        } else if (r.Type == 5 && r.Label == "CPU Package Power" && double.IsNaN(s.CpuPower)) s.CpuPower = r.Value;
                        else if (r.Type == 3 && r.Value > 0) { s.Fans.Add(r); if (board == null) board = r.Sensor; }
                    } else if (r.Sensor.StartsWith("GPU [#0]")) {
                        if (s.GpuName == "") s.GpuName = Between(r.Sensor);
                        switch (r.Type) {
                            case 1:
                                if (r.Label == "GPU Temperature" && double.IsNaN(s.GpuTemp)) s.GpuTemp = r.Value;
                                else if (r.Label.StartsWith("GPU Hot Spot") && double.IsNaN(s.GpuHotSpot)) s.GpuHotSpot = r.Value;
                                break;
                            case 3: if (double.IsNaN(s.GpuFanRpm) && r.Label.StartsWith("GPU Fan")) s.GpuFanRpm = r.Value; break;
                            case 5: if (double.IsNaN(s.GpuPower) && (r.Label == "GPU Power" || r.Label == "Total Board Power" || r.Label == "GPU ASIC Power")) s.GpuPower = r.Value; break;
                            case 6: if (r.Label == "GPU Clock" && double.IsNaN(s.GpuClock)) s.GpuClock = r.Value; break;
                            case 7:
                                if ((r.Label == "GPU Core Load" || r.Label == "GPU Utilization") && double.IsNaN(s.GpuLoad)) s.GpuLoad = r.Value;
                                else if (r.Label == "GPU Memory Usage" && double.IsNaN(s.GpuVramPct)) s.GpuVramPct = r.Value;
                                else if (r.Label.StartsWith("GPU Fan") && double.IsNaN(s.GpuFanPct)) s.GpuFanPct = r.Value;
                                break;
                            default:
                                if (r.Label == "GPU Memory Allocated" && double.IsNaN(s.GpuVramMb)) s.GpuVramMb = r.Value;
                                else if (r.Label == "GPU D3D Memory Dedicated" && double.IsNaN(s.GpuVramMb)) s.GpuVramMb = r.Value;
                                break;
                        }
                    }
                }
                if (pT.Count > 0) s.CpuTemp = Avg(pT);
                else if (cT.Count > 0) s.CpuTemp = Avg(cT);
                else if (!double.IsNaN(tctl)) s.CpuTemp = tctl;
                else s.CpuTemp = pkg;
                s.CpuClock = pC.Count > 0 ? Avg(pC) : Avg(cC);
                if (board != null) {
                    s.BoardName = board;
                    foreach (var r in rs) {
                        if (r.Sensor == board && r.Type == 1 && r.Value > 0 && r.Value < 125) {
                            s.BoardTemps.Add(r);
                            if (double.IsNaN(s.BoardTemp) && (r.Label.IndexOf("Motherboard", StringComparison.OrdinalIgnoreCase) >= 0 || r.Label == "System" || r.Label == "MB")) s.BoardTemp = r.Value;
                        }
                    }
                    if (double.IsNaN(s.BoardTemp) && s.BoardTemps.Count > 0) s.BoardTemp = s.BoardTemps[0].Value;
                }
            } else s.HwError = err;

            if (useNvSmi && s.GpuName == "" && NvSmi.Start()) {
                var v = NvSmi.Last;
                if (v != null) {
                    s.GpuFromNvSmi = true; s.GpuName = NvSmi.Name;
                    s.GpuTemp = v[0]; s.GpuLoad = v[1]; s.GpuVramMb = v[2]; s.GpuVramTotalMb = v[3];
                    if (v[3] > 0) s.GpuVramPct = v[2] * 100.0 / v[3];
                    s.GpuPower = v[4]; s.GpuFanPct = v[5]; s.GpuClock = v[6];
                }
            }
            return s;
        }
    }
}
'@
}

$De = [System.Globalization.CultureInfo]::GetCultureInfo('de-DE')
$script:Windows  = New-Object System.Collections.ArrayList
$script:Updaters = New-Object System.Collections.ArrayList
$script:LastWrite = [datetime]::MinValue
$script:AccentHex = ''
$script:ProgmanH  = [IntPtr]::Zero
$script:TickN = 0
$script:Timer = $null
$script:U = 120; $script:G = 8
$script:Fg = [System.Windows.Media.Brushes]::White
$script:BarBg = $null
$script:BarFg = [System.Windows.Media.Brushes]::White
$script:ShowLabels = $true
$script:ClockStyle = 'analog'
$Palette = @('#0078D4', '#E81123', '#00B294', '#FF8C00', '#8764B8', '#00CC6A', '#EA005E', '#0099BC', '#CA5010', '#5C2E91')
$IconFont = 'Segoe Fluent Icons, Segoe MDL2 Assets'
$TextFont = 'Segoe UI Variable Display, Segoe UI'
$ActionGlyphs = @{ lock = 0xE72E; restart = 0xE777; shutdown = 0xE7E8; recycle = 0xE74D; settings = 0xE713; explorer = 0xE8B7; taskmgr = 0xE9D9 }

# ------------------------------------------------------------------ Helfer
function Load-Config {
    if (-not (Test-Path $CfgFile)) { return $null }
    try { return (Get-Content $CfgFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { Write-Log "Config lesen: $_"; return $null }
}
function Save-Config($cfg) {
    try {
        Set-Content -Path $CfgFile -Value (ConvertTo-Json -InputObject $cfg -Depth 6) -Encoding UTF8
        $script:LastWrite = (Get-Item $CfgFile).LastWriteTimeUtc
    } catch { Write-Log "Config speichern: $_" }
}
function Set-Prop($o, [string]$n, $v) {
    if ($o.PSObject.Properties[$n]) { $o.$n = $v } else { $o | Add-Member -NotePropertyName $n -NotePropertyValue $v }
}
function Get-Opt($cfg, [string]$n, $default) {
    if ($cfg.PSObject.Properties[$n] -and $null -ne $cfg.$n -and "$($cfg.$n)" -ne '') { return $cfg.$n }
    return $default
}
function Get-AccentHex {
    try {
        $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\DWM')
        if ($k) { $v = $k.GetValue('AccentColor', $null); $k.Close()
            if ($null -ne $v) { $u = [BitConverter]::GetBytes([int]$v); return ('#{0:X2}{1:X2}{2:X2}' -f $u[0], $u[1], $u[2]) } }
    } catch {}
    return '#0078D4'
}
function New-Brush([string]$hex, [double]$alpha = 1.0) {
    $c = [System.Windows.Media.Color]([System.Windows.Media.ColorConverter]::ConvertFromString($hex))
    $a = [byte][math]::Max(0, [math]::Min(255, [math]::Round($c.A * $alpha)))
    $b = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromArgb($a, $c.R, $c.G, $c.B))
    $b.Freeze()
    return $b
}
function New-TB([string]$text, [double]$size, [string]$weight = 'Normal', [double]$op = 1.0) {
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $text; $tb.FontSize = $size; $tb.FontWeight = $weight; $tb.Opacity = $op
    $tb.Foreground = $script:Fg
    $tb.FontFamily = $TextFont
    $tb.TextTrimming = 'CharacterEllipsis'
    return $tb
}
function New-Glyph([int]$code, [double]$size) {
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = [string][char]$code; $tb.FontFamily = $IconFont; $tb.FontSize = $size
    $tb.Foreground = $script:Fg
    $tb.HorizontalAlignment = 'Center'; $tb.VerticalAlignment = 'Center'
    return $tb
}
function New-Bar([double]$width) {
    $barGrid = New-Object System.Windows.Controls.Grid
    $barGrid.Height = 6; $barGrid.Width = $width; $barGrid.HorizontalAlignment = 'Left'; $barGrid.Margin = '0,4,0,8'
    $bg = New-Object System.Windows.Controls.Border; $bg.CornerRadius = '3'; $bg.Background = $script:BarBg
    $fill = New-Object System.Windows.Controls.Border; $fill.CornerRadius = '3'; $fill.Background = $script:BarFg
    $fill.HorizontalAlignment = 'Left'; $fill.Width = 0
    [void]$barGrid.Children.Add($bg); [void]$barGrid.Children.Add($fill)
    return @{ Grid = $barGrid; Fill = $fill; Width = $width }
}
function Get-IconSource([string]$path) {
    try {
        $p = [Environment]::ExpandEnvironmentVariables($path)
        if (-not (Test-Path -LiteralPath $p)) { return $null }
        $h = [W11T.Native]::GetIcon($p)
        if ($h -eq [IntPtr]::Zero) { return $null }
        $src = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($h, [System.Windows.Int32Rect]::Empty, [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
        [void][W11T.Native]::DestroyIcon($h)
        $src.Freeze()
        return $src
    } catch { Write-Log "Icon $path : $_"; return $null }
}
function Get-TileSize([string]$size) {
    $unit = $script:U; $gap = $script:G
    switch ($size) {
        'W'     { return @((2 * $unit + $gap), $unit) }
        'L'     { return @((2 * $unit + $gap), (2 * $unit + $gap)) }
        default { return @($unit, $unit) }
    }
}

# ------------------------------------------------------------------ Anordnung
function Place-Tiles($cfg) {
    $wa = [System.Windows.SystemParameters]::WorkArea
    $unit = $script:U; $gap = $script:G; $cell = $unit + $gap; $m = 24
    $placed = New-Object System.Collections.ArrayList
    $changed = $false
    foreach ($t in @($cfg.Tiles)) {
        if ($null -ne $t.X -and $null -ne $t.Y) {
            $sz = Get-TileSize $t.Size
            # Kachel ausserhalb des Bildschirms (z. B. anderer Monitor/Aufloesung)? -> neu platzieren
            if ([double]$t.X -lt $wa.Left -or [double]$t.Y -lt $wa.Top -or ([double]$t.X + $sz[0]) -gt ($wa.Right + 2) -or ([double]$t.Y + $sz[1]) -gt ($wa.Bottom + 2)) {
                $t.X = $null; $t.Y = $null; $changed = $true; continue
            }
            [void]$placed.Add([System.Windows.Rect]::new([double]$t.X + 1, [double]$t.Y + 1, $sz[0] - 2, $sz[1] - 2))
        }
    }
    $cols = [math]::Max(1, [math]::Floor(($wa.Width - 2 * $m + $gap) / $cell))
    $rows = [math]::Max(1, [math]::Floor(($wa.Height - 2 * $m + $gap) / $cell))
    foreach ($t in @($cfg.Tiles)) {
        if ($null -ne $t.X -and $null -ne $t.Y) { continue }
        $sz = Get-TileSize $t.Size
        $wc = [math]::Round(($sz[0] + $gap) / $cell); $hc = [math]::Round(($sz[1] + $gap) / $cell)
        $done = $false
        for ($c = 0; ($c -le $cols - $wc) -and -not $done; $c++) {
            for ($r = 0; ($r -le $rows - $hc) -and -not $done; $r++) {
                $x = $wa.Right - $m - ($c + $wc) * $cell + $gap
                $y = $wa.Top + $m + $r * $cell
                $rect = [System.Windows.Rect]::new($x + 1, $y + 1, $sz[0] - 2, $sz[1] - 2)
                $free = $true
                foreach ($p in $placed) { if ($p.IntersectsWith($rect)) { $free = $false; break } }
                if ($free) {
                    Set-Prop $t 'X' ([double]$x); Set-Prop $t 'Y' ([double]$y)
                    [void]$placed.Add($rect); $done = $true
                }
            }
        }
        if (-not $done) { Set-Prop $t 'X' ([double]($wa.Left + $m)); Set-Prop $t 'Y' ([double]($wa.Top + $m)) }
        $changed = $true
    }
    return $changed
}

function New-ClockLine([double]$c, [double]$len, [double]$thick, $brush, [double]$back = 0) {
    $l = New-Object System.Windows.Shapes.Line
    $l.X1 = $c; $l.Y1 = $c + $back; $l.X2 = $c; $l.Y2 = $c - $len
    $l.StrokeThickness = $thick; $l.Stroke = $brush
    $l.StrokeStartLineCap = 'Round'; $l.StrokeEndLineCap = 'Round'
    $rt = New-Object System.Windows.Media.RotateTransform(0.0, $c, $c)
    $l.RenderTransform = $rt
    return @{ Line = $l; Rot = $rt }
}
function New-AnalogClock($grid, [string]$size, [double]$w, [double]$h) {
    $d = [math]::Min($w, $h) - 22
    if ($size -eq 'W') { $d = $h - 22 }
    $c = $d / 2
    $cv = New-Object System.Windows.Controls.Canvas
    $cv.Width = $d; $cv.Height = $d
    $face = New-Object System.Windows.Shapes.Ellipse
    $face.Width = $d; $face.Height = $d
    $fc = $script:Fg.Color
    $face.Fill = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromArgb(20, $fc.R, $fc.G, $fc.B))
    [void]$cv.Children.Add($face)
    for ($i = 0; $i -lt 60; $i++) {
        $isHour = ($i % 5 -eq 0)
        if (-not $isHour -and $d -lt 120) { continue }
        $len = $d * 0.035; $th = 1.2; $op = 0.45
        if ($isHour) { $len = $d * 0.075; $th = [math]::Max(2, $d / 55); $op = 0.9 }
        $tk = New-Object System.Windows.Shapes.Line
        $tk.X1 = $c; $tk.X2 = $c; $tk.Y1 = $d * 0.04; $tk.Y2 = $d * 0.04 + $len
        $tk.Stroke = $script:Fg; $tk.Opacity = $op; $tk.StrokeThickness = $th
        $tk.StrokeStartLineCap = 'Round'; $tk.StrokeEndLineCap = 'Round'
        $tk.RenderTransform = New-Object System.Windows.Media.RotateTransform(($i * 6.0), $c, $c)
        [void]$cv.Children.Add($tk)
    }
    $hh = New-ClockLine $c ($d * 0.26) ([math]::Max(3, $d / 30)) $script:Fg
    $mh = New-ClockLine $c ($d * 0.38) ([math]::Max(2.5, $d / 42)) $script:Fg
    $sh = New-ClockLine $c ($d * 0.42) ([math]::Max(1.2, $d / 110)) $script:BarFg ($d * 0.08)
    [void]$cv.Children.Add($hh.Line); [void]$cv.Children.Add($mh.Line); [void]$cv.Children.Add($sh.Line)
    $dot = New-Object System.Windows.Shapes.Ellipse
    $ds = [math]::Max(6, $d / 16); $dot.Width = $ds; $dot.Height = $ds; $dot.Fill = $script:BarFg
    [System.Windows.Controls.Canvas]::SetLeft($dot, $c - $ds / 2); [System.Windows.Controls.Canvas]::SetTop($dot, $c - $ds / 2)
    [void]$cv.Children.Add($dot)

    $date = $null; $time = $null
    if ($size -eq 'W') {
        $cv.HorizontalAlignment = 'Left'; $cv.VerticalAlignment = 'Center'; $cv.Margin = '11,0,0,0'
        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.VerticalAlignment = 'Center'; $sp.Margin = (New-Object System.Windows.Thickness(($d + 26), 0, 10, 0))
        $time = New-TB '' 30 'SemiBold'
        $date = New-TB '' 13 'Normal' 0.75; $date.TextWrapping = 'Wrap'
        [void]$sp.Children.Add($time); [void]$sp.Children.Add($date)
        [void]$grid.Children.Add($sp)
    } else {
        $cv.HorizontalAlignment = 'Center'; $cv.VerticalAlignment = 'Center'
        if ($size -eq 'L') {
            $d2 = $d - 34; $k = $d2 / $d
            $cv.LayoutTransform = New-Object System.Windows.Media.ScaleTransform($k, $k)
            $cv.VerticalAlignment = 'Top'; $cv.Margin = '0,12,0,0'
            $date = New-TB '' 13 'SemiBold' 0.8
            $date.HorizontalAlignment = 'Center'; $date.VerticalAlignment = 'Bottom'; $date.Margin = '0,0,0,12'
            [void]$grid.Children.Add($date)
        }
    }
    [void]$grid.Children.Add($cv)
    [void]$script:Updaters.Add(@{ Kind = 'analog'; H = $hh.Rot; M = $mh.Rot; S = $sh.Rot; Time = $time; Date = $date; Size = $size })
}

# ------------------------------------------------------------------ Sicherheit & Updates (Hintergrund)
$script:SecState = $null
$script:SecJob   = $null
$script:SecNext  = [datetime]::MinValue
$SecCheckScript = {
    $r = [ordered]@{ AvName = 'Microsoft Defender'; DefOk = $null; RealTime = $null; SigAge = $null; ScanAge = $null
                     Threats = 0; Updates = -1; Titles = @(); Reboot = $false; UpdError = ''; Checked = (Get-Date) }
    try {
        $m = Get-MpComputerStatus -ErrorAction Stop
        $r.RealTime = [bool]$m.RealTimeProtectionEnabled
        $r.DefOk    = [bool]($m.AntivirusEnabled -and $m.RealTimeProtectionEnabled)
        $r.SigAge   = [int]$m.AntivirusSignatureAge
        $r.ScanAge  = [int]$m.QuickScanAge
        try { $r.Threats = @(Get-MpThreat -ErrorAction Stop | Where-Object { $_.IsActive }).Count } catch {}
    } catch {
        try {
            $av = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop)
            $best = $av | Where-Object { $_.displayName -notmatch 'Defender' } | Select-Object -First 1
            if (-not $best) { $best = $av | Select-Object -First 1 }
            if ($best) {
                $hex = '{0:X6}' -f [int]$best.productState
                $r.AvName = [string]$best.displayName
                $r.RealTime = ($hex.Substring(2, 2) -eq '10' -or $hex.Substring(2, 2) -eq '11')
                $r.DefOk = $r.RealTime -and ($hex.Substring(4, 2) -eq '00')
                $r.SigAge = 0; if ($hex.Substring(4, 2) -ne '00') { $r.SigAge = 99 }
            }
        } catch {}
    }
    try {
        $session  = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $searcher.Online = $true
        # Nur echte Software-Updates, die auch Windows Update als offen anzeigt
        $res = $searcher.Search("IsInstalled=0 and IsHidden=0 and BrowseOnly=0 and Type='Software'")
        $titles = @()
        for ($i = 0; $i -lt $res.Updates.Count; $i++) {
            $upd = $res.Updates.Item($i)
            $title = [string]$upd.Title
            $skip = $false
            # Defender-Virendefinitionen laedt der Defender selbst -> nicht als "Update noetig" zaehlen
            try { foreach ($cat in $upd.Categories) { if ([string]$cat.CategoryID -eq 'e0789628-ce08-4437-be74-2495b842f43b') { $skip = $true } } } catch {}
            if ($title -match 'KB2267602|Security Intelligence|Sicherheitsinformationsupdate|Definitionsupdate|Definition Update') { $skip = $true }
            # bereits heruntergeladen + installiert, wartet nur auf Neustart -> zaehlt als Neustart, nicht als Update
            try { if ($upd.IsInstalled) { $skip = $true } } catch {}
            if (-not $skip) { $titles += $title }
        }
        $r.Updates = $titles.Count
        $r.Titles = @($titles | Select-Object -First 6)
    } catch { $r.UpdError = $_.Exception.Message }
    $r.Reboot = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
                (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
    [pscustomobject]$r
}
function Start-SecCheck {
    if ($script:SecJob) { return }
    try {
        $ps = [PowerShell]::Create()
        [void]$ps.AddScript($SecCheckScript)
        $script:SecJob = @{ PS = $ps; Handle = $ps.BeginInvoke() }
        $script:SecNext = (Get-Date).AddMinutes(15)
    } catch { Write-Log "Sicherheits-Check: $_" }
}
function Poll-SecCheck {
    if (-not $script:SecJob -or -not $script:SecJob.Handle.IsCompleted) { return }
    try {
        $out = $script:SecJob.PS.EndInvoke($script:SecJob.Handle)
        if ($out -and $out.Count -gt 0) { $script:SecState = $out[$out.Count - 1] }
    } catch { Write-Log "Sicherheits-Check Ergebnis: $_" }
    finally { try { $script:SecJob.PS.Dispose() } catch {}; $script:SecJob = $null }
}
function Get-SecSummary {
    # liefert Farbe + Texte fuer die Kachel
    $st = $script:SecState
    $ok = '#30D158'; $warn = '#FF9F0A'; $bad = '#FF453A'
    $res = @{ Level = 'pending'; Color = '#8E8E93'; Short = 'Prüfe ...'; DefColor = '#8E8E93'; DefText = 'Defender: wird geprüft ...'; DefSub = ''
              UpdColor = '#8E8E93'; UpdText = 'Windows Update: wird geprüft ...'; UpdSub = ''; Titles = @() }
    if (-not $st) { return $res }
    $level = 0
    # Defender
    if ($null -eq $st.DefOk) { $res.DefColor = $warn; $res.DefText = "$($st.AvName): Status unbekannt"; $level = [math]::Max($level, 1) }
    elseif ($st.Threats -gt 0) { $res.DefColor = $bad; $res.DefText = "$($st.Threats) Bedrohung(en) gefunden!"; $level = 2 }
    elseif (-not $st.DefOk) { $res.DefColor = $bad; $res.DefText = "$($st.AvName): Schutz AUS!"; $level = 2 }
    elseif ($st.SigAge -ge 3) { $res.DefColor = $warn; $res.DefText = "$($st.AvName): Signaturen veraltet"; $level = [math]::Max($level, 1) }
    else { $res.DefColor = $ok; $res.DefText = "$($st.AvName): Geschützt" }
    if ($null -ne $st.SigAge -and $st.SigAge -lt 99) {
        if ($st.SigAge -eq 0) { $res.DefSub = 'Virensignaturen von heute' } else { $res.DefSub = "Virensignaturen: vor $($st.SigAge) Tag(en)" }
        if ($null -ne $st.ScanAge -and $st.ScanAge -lt 1000) { $res.DefSub += " · Scan vor $($st.ScanAge) T" }
    }
    # Updates
    if ($st.Reboot) { $res.UpdColor = $warn; $res.UpdText = 'Neustart nötig für Updates'; $level = [math]::Max($level, 1) }
    elseif ($st.Updates -gt 0) { $res.UpdColor = $warn; $res.UpdText = "$($st.Updates) Update(s) verfügbar"; $level = [math]::Max($level, 1) }
    elseif ($st.Updates -eq 0) { $res.UpdColor = $ok; $res.UpdText = 'Windows ist aktuell' }
    else { $res.UpdColor = '#8E8E93'; $res.UpdText = 'Update-Status nicht abrufbar' }
    $res.UpdSub = 'Geprüft um ' + ([datetime]$st.Checked).ToString('HH:mm')
    $res.Titles = @($st.Titles)
    switch ($level) {
        0 { $res.Level = 'ok';   $res.Color = $ok;   $res.Short = 'Alles sicher' }
        1 { $res.Level = 'warn'; $res.Color = $warn; if ($st.Reboot) { $res.Short = 'Neustart nötig' } elseif ($st.Updates -gt 0) { $res.Short = "$($st.Updates) Update(s)" } else { $res.Short = 'Prüfen!' } }
        2 { $res.Level = 'bad';  $res.Color = $bad;  $res.Short = 'Achtung!' }
    }
    return $res
}
function New-StatusRow([string]$sub) {
    $row = New-Object System.Windows.Controls.Grid
    $row.Margin = '0,8,0,0'
    $cd1 = New-Object System.Windows.Controls.ColumnDefinition; $cd1.Width = [System.Windows.GridLength]::Auto
    $cd2 = New-Object System.Windows.Controls.ColumnDefinition
    $row.ColumnDefinitions.Add($cd1); $row.ColumnDefinitions.Add($cd2)
    $dot = New-Object System.Windows.Shapes.Ellipse
    $dot.Width = 10; $dot.Height = 10; $dot.VerticalAlignment = 'Top'; $dot.Margin = '0,5,10,0'
    $dot.Fill = New-Brush '#8E8E93'
    $sp = New-Object System.Windows.Controls.StackPanel
    $t1 = New-TB '' 14 'SemiBold'
    $t2 = New-TB '' 12 'Normal' 0.7
    [void]$sp.Children.Add($t1); [void]$sp.Children.Add($t2)
    [System.Windows.Controls.Grid]::SetColumn($sp, 1)
    [void]$row.Children.Add($dot); [void]$row.Children.Add($sp)
    return @{ Row = $row; Dot = $dot; Text = $t1; Sub = $t2 }
}

# ------------------------------------------------------------------ Systemwerte
$MetricInfo = [ordered]@{
    cpu_load   = @{ Label = 'CPU';          Hw = $false; Bar = $true }
    cpu_temp   = @{ Label = 'CPU-Temp';     Hw = $true;  Bar = $true }
    cpu_clock  = @{ Label = 'CPU-Takt';     Hw = $true;  Bar = $false }
    cpu_power  = @{ Label = 'CPU-Leistung'; Hw = $true;  Bar = $false }
    ram        = @{ Label = 'RAM';          Hw = $false; Bar = $true }
    gpu_load   = @{ Label = 'GPU';          Hw = $true;  Bar = $true; Gpu = $true }
    gpu_temp   = @{ Label = 'GPU-Temp';     Hw = $true;  Bar = $true; Gpu = $true }
    gpu_vram   = @{ Label = 'VRAM';         Hw = $true;  Bar = $true; Gpu = $true }
    gpu_power  = @{ Label = 'GPU-Leistung'; Hw = $true;  Bar = $false; Gpu = $true }
    gpu_fan    = @{ Label = 'GPU-Lüfter';   Hw = $true;  Bar = $false; Gpu = $true }
    gpu_clock  = @{ Label = 'GPU-Takt';     Hw = $true;  Bar = $false; Gpu = $true }
    board_temp = @{ Label = 'Mainboard';    Hw = $true;  Bar = $true }
    fans       = @{ Label = 'Lüfter';       Hw = $true;  Bar = $false }
    net_down   = @{ Label = 'Download';     Hw = $false; Bar = $false; Net = $true }
    net_up     = @{ Label = 'Upload';       Hw = $false; Bar = $false; Net = $true }
    uptime     = @{ Label = 'Laufzeit';     Hw = $false; Bar = $false }
}
$script:NeedHw = $false; $script:NeedNet = $false; $script:NeedGpu = $false
$script:NetUnit = 'MBs'
$script:NetHistD = New-Object System.Collections.Generic.List[double]
$script:NetHistU = New-Object System.Collections.Generic.List[double]

function Get-TileMetrics($t) {
    $list = @()
    if ($t.PSObject.Properties['Metrics'] -and $t.Metrics) { $list = @(([string]$t.Metrics).Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $MetricInfo.Contains($_) }) }
    if ($list.Count -eq 0) { $list = @('cpu_load', 'ram') }
    return ,$list
}

function Format-Speed([double]$bps, [switch]$Short) {
    if ($script:NetUnit -eq 'Mbit') {
        $v = $bps * 8 / 1000000
        if ($v -ge 10) { $t = $v.ToString('0', $De) } else { $t = $v.ToString('0.0', $De) }
        if ($Short) { return "$t M" } else { return "$t Mbit/s" }
    }
    if ($bps -ge 1048576) { $t = ($bps / 1048576).ToString('0.0', $De); $u = 'MB/s'; $su = 'M' }
    elseif ($bps -ge 1024) { $t = ($bps / 1024).ToString('0', $De); $u = 'KB/s'; $su = 'K' }
    else { $t = $bps.ToString('0', $De); $u = 'B/s'; $su = 'B' }
    if ($Short) { return "$t $su" } else { return "$t $u" }
}

function Test-Num($v) { return ($null -ne $v -and -not [double]::IsNaN([double]$v)) }

# liefert @(Text, Prozent fuer Balken oder -1)
function Format-Metric([string]$key, $snap, [bool]$short) {
    $hw = $snap.Hw
    switch ($key) {
        'cpu_load' { return @(((([double]$snap.Cpu).ToString('0', $De)) + ' %'), [double]$snap.Cpu) }
        'ram' {
            $p = [double]$snap.Ram[0]
            if ($short) { return @(($p.ToString('0', $De) + ' %'), $p) }
            return @(('{0} %  ({1} / {2} GB)' -f $p.ToString('0', $De), ([double]$snap.Ram[2]).ToString('0.0', $De), ([double]$snap.Ram[1]).ToString('0', $De)), $p)
        }
        'uptime' {
            $ts = [TimeSpan]::FromMilliseconds([double][W11T.Native]::GetTickCount64())
            return @(('{0} T {1} h {2} min' -f $ts.Days, $ts.Hours, $ts.Minutes), -1)
        }
        'net_down' { return @(('↓ ' + (Format-Speed $snap.Down -Short:$short)), -1) }
        'net_up'   { return @(('↑ ' + (Format-Speed $snap.Up -Short:$short)), -1) }
    }
    if (-not $hw) { return @('–', -1) }
    switch ($key) {
        'cpu_temp'   { if (Test-Num $hw.CpuTemp) { return @(($hw.CpuTemp.ToString('0', $De) + ' °C'), $hw.CpuTemp) } }
        'cpu_clock'  { if (Test-Num $hw.CpuClock) { return @((($hw.CpuClock / 1000).ToString('0.00', $De) + ' GHz'), -1) } }
        'cpu_power'  { if (Test-Num $hw.CpuPower) { return @(($hw.CpuPower.ToString('0', $De) + ' W'), -1) } }
        'gpu_load'   { if (Test-Num $hw.GpuLoad) { return @(($hw.GpuLoad.ToString('0', $De) + ' %'), $hw.GpuLoad) } }
        'gpu_temp'   {
            if (Test-Num $hw.GpuTemp) {
                $txt = $hw.GpuTemp.ToString('0', $De) + ' °C'
                if (-not $short -and (Test-Num $hw.GpuHotSpot)) { $txt += '  (Hotspot ' + $hw.GpuHotSpot.ToString('0', $De) + ')' }
                return @($txt, $hw.GpuTemp)
            }
        }
        'gpu_vram' {
            if (Test-Num $hw.GpuVramMb) {
                $txt = ($hw.GpuVramMb / 1024).ToString('0.0', $De) + ' GB'
                if (-not $short -and (Test-Num $hw.GpuVramTotalMb)) { $txt += ' / ' + ($hw.GpuVramTotalMb / 1024).ToString('0', $De) + ' GB' }
                $pct = -1; if (Test-Num $hw.GpuVramPct) { $pct = $hw.GpuVramPct }
                return @($txt, $pct)
            }
            if (Test-Num $hw.GpuVramPct) { return @(($hw.GpuVramPct.ToString('0', $De) + ' %'), $hw.GpuVramPct) }
        }
        'gpu_power'  { if (Test-Num $hw.GpuPower) { return @(($hw.GpuPower.ToString('0', $De) + ' W'), -1) } }
        'gpu_fan'    {
            if (Test-Num $hw.GpuFanRpm) { return @(($hw.GpuFanRpm.ToString('0', $De) + ' RPM'), -1) }
            if (Test-Num $hw.GpuFanPct) { return @(($hw.GpuFanPct.ToString('0', $De) + ' %'), -1) }
        }
        'gpu_clock'  { if (Test-Num $hw.GpuClock) { return @(($hw.GpuClock.ToString('0', $De) + ' MHz'), -1) } }
        'board_temp' { if (Test-Num $hw.BoardTemp) { return @(($hw.BoardTemp.ToString('0', $De) + ' °C'), $hw.BoardTemp) } }
        'fans' {
            $f = @($hw.Fans)
            if ($f.Count -gt 0) {
                $avg = ($f | Measure-Object -Property Value -Average).Average
                if ($short) { return @(('Ø ' + ([double]$avg).ToString('0', $De)), -1) }
                return @(('{0} aktiv · Ø {1} RPM' -f $f.Count, ([double]$avg).ToString('0', $De)), -1)
            }
        }
    }
    return @('–', -1)
}

function Get-Snapshot {
    $snap = @{ Cpu = [W11T.Native]::Cpu(); Ram = [W11T.Native]::Ram(); Hw = $null; Down = 0.0; Up = 0.0 }
    if ($script:NeedHw) {
        try { $snap.Hw = [W11T.Sensors]::Summarize([bool]$script:NeedGpu) } catch { Write-Log "Sensoren: $_" }
    }
    if ($script:NeedNet) {
        try {
            [W11T.Net]::Poll()
            $snap.Down = [W11T.Net]::Down; $snap.Up = [W11T.Net]::Up
            $script:NetHistD.Add($snap.Down); $script:NetHistU.Add($snap.Up)
            while ($script:NetHistD.Count -gt 60) { $script:NetHistD.RemoveAt(0) }
            while ($script:NetHistU.Count -gt 60) { $script:NetHistU.RemoveAt(0) }
        } catch { Write-Log "Netzwerk: $_" }
    }
    return $snap
}

function New-MetricRow([string]$label, [double]$width, [bool]$withBar, [double]$fs) {
    $sp = New-Object System.Windows.Controls.StackPanel
    $g = New-Object System.Windows.Controls.Grid
    $c1 = New-Object System.Windows.Controls.ColumnDefinition
    $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = [System.Windows.GridLength]::Auto
    $g.ColumnDefinitions.Add($c1); $g.ColumnDefinitions.Add($c2)
    $lb = New-TB $label $fs 'Normal' 0.72
    $val = New-TB '–' $fs 'SemiBold'
    $val.Margin = '6,0,0,0'
    [System.Windows.Controls.Grid]::SetColumn($val, 1)
    [void]$g.Children.Add($lb); [void]$g.Children.Add($val)
    [void]$sp.Children.Add($g)
    $bar = $null
    if ($withBar) { $bar = New-Bar $width; $bar.Grid.Margin = '0,3,0,5'; [void]$sp.Children.Add($bar.Grid) }
    else { $sp.Margin = '0,0,0,6' }
    return @{ Panel = $sp; Value = $val; Bar = $bar }
}

function Set-Bar($bar, [double]$pct) {
    if (-not $bar) { return }
    if ($pct -lt 0) { $bar.Fill.Width = 0; return }
    $bar.Fill.Width = [math]::Max(0, [math]::Min($bar.Width, $bar.Width * $pct / 100))
}

function New-Spark([double]$w, [double]$h) {
    $cv = New-Object System.Windows.Controls.Canvas
    $cv.Width = $w; $cv.Height = $h; $cv.ClipToBounds = $true
    $fillD = New-Object System.Windows.Shapes.Polygon
    $fillD.Fill = New-Brush ($script:BarFg.Color.ToString()) 0.22
    $lineD = New-Object System.Windows.Shapes.Polyline
    $lineD.Stroke = $script:BarFg; $lineD.StrokeThickness = 1.8; $lineD.StrokeLineJoin = 'Round'
    $lineU = New-Object System.Windows.Shapes.Polyline
    $lineU.Stroke = New-Brush '#30D158'; $lineU.StrokeThickness = 1.6; $lineU.StrokeLineJoin = 'Round'
    [void]$cv.Children.Add($fillD); [void]$cv.Children.Add($lineD); [void]$cv.Children.Add($lineU)
    return @{ Canvas = $cv; FillD = $fillD; LineD = $lineD; LineU = $lineU; W = $w; H = $h }
}

function Update-Spark($sp) {
    $n = $script:NetHistD.Count
    if ($n -lt 2) { return }
    $max = 51200.0
    foreach ($v in $script:NetHistD) { if ($v -gt $max) { $max = $v } }
    foreach ($v in $script:NetHistU) { if ($v -gt $max) { $max = $v } }
    $step = $sp.W / 59
    $x0 = $sp.W - ($n - 1) * $step
    $pd = New-Object System.Windows.Media.PointCollection
    $pu = New-Object System.Windows.Media.PointCollection
    for ($i = 0; $i -lt $n; $i++) {
        $x = $x0 + $i * $step
        $pd.Add([System.Windows.Point]::new($x, $sp.H - 1 - ($script:NetHistD[$i] / $max) * ($sp.H - 4)))
        $pu.Add([System.Windows.Point]::new($x, $sp.H - 1 - ($script:NetHistU[$i] / $max) * ($sp.H - 4)))
    }
    $pf = New-Object System.Windows.Media.PointCollection
    $pf.Add([System.Windows.Point]::new($x0, $sp.H))
    foreach ($pt in $pd) { $pf.Add($pt) }
    $pf.Add([System.Windows.Point]::new($sp.W, $sp.H))
    $sp.LineD.Points = $pd; $sp.LineU.Points = $pu; $sp.FillD.Points = $pf
}

# ------------------------------------------------------------------ Kachel-Inhalte
function New-TileContent($t, [double]$w, [double]$h) {
    $grid = New-Object System.Windows.Controls.Grid
    $size = [string]$t.Size
    $big = ($size -eq 'L')
    $type = [string]$t.Type
    $label = $true

    switch ($type) {
        'clock' {
            $label = $false
            if ($script:ClockStyle -eq 'analog') {
                New-AnalogClock $grid $size $w $h
                break
            }
            $sp = New-Object System.Windows.Controls.StackPanel
            $sp.VerticalAlignment = 'Center'
            if ($size -eq 'S') { $sp.HorizontalAlignment = 'Center'; $ts = 30; $ds = 12 }
            else { $sp.HorizontalAlignment = 'Left'; $sp.Margin = '18,0,0,0'; $ts = 46; $ds = 14; if ($big) { $ts = 64; $ds = 17 } }
            $time = New-TB '' $ts 'SemiBold'
            $date = New-TB '' $ds 'Normal' 0.85
            $date.TextWrapping = 'Wrap'
            if ($size -eq 'S') { $time.HorizontalAlignment = 'Center'; $date.HorizontalAlignment = 'Center' }
            [void]$sp.Children.Add($time); [void]$sp.Children.Add($date)
            [void]$grid.Children.Add($sp)
            [void]$script:Updaters.Add(@{ Kind = 'clock'; Time = $time; Date = $date; Size = $size })
        }
        'system' {
            $label = $false
            $keys = Get-TileMetrics $t
            if ($size -eq 'S') {
                $sp = New-Object System.Windows.Controls.StackPanel
                $sp.HorizontalAlignment = 'Center'; $sp.VerticalAlignment = 'Center'
                $l1 = New-TB $MetricInfo[$keys[0]].Label 12 'SemiBold' 0.75; $l1.HorizontalAlignment = 'Center'
                $v1 = New-TB '–' 28 'SemiBold'; $v1.HorizontalAlignment = 'Center'
                $v2 = New-TB '' 12 'Normal' 0.85; $v2.HorizontalAlignment = 'Center'
                [void]$sp.Children.Add($l1); [void]$sp.Children.Add($v1); [void]$sp.Children.Add($v2)
                [void]$grid.Children.Add($sp)
                $k2 = $null; if ($keys.Count -gt 1) { $k2 = $keys[1] }
                [void]$script:Updaters.Add(@{ Kind = 'metrics'; Small = $true; K1 = $keys[0]; K2 = $k2; V1 = $v1; V2 = $v2 })
            } else {
                $outer = New-Object System.Windows.Controls.StackPanel
                $outer.Margin = '14,12,14,8'
                [void]$outer.Children.Add((New-TB ([string]$t.Name) 12 'SemiBold' 0.7))
                $rows = New-Object System.Collections.ArrayList
                if ($size -eq 'W') {
                    # 2 Spalten x 2 Zeilen, kurze Werte
                    $cols = New-Object System.Windows.Controls.Grid
                    $cols.Margin = '0,6,0,0'
                    foreach ($i in 0..2) { $cd = New-Object System.Windows.Controls.ColumnDefinition; if ($i -eq 1) { $cd.Width = '14' }; $cols.ColumnDefinitions.Add($cd) }
                    $left = New-Object System.Windows.Controls.StackPanel; $right = New-Object System.Windows.Controls.StackPanel
                    [System.Windows.Controls.Grid]::SetColumn($right, 2)
                    [void]$cols.Children.Add($left); [void]$cols.Children.Add($right)
                    $cw = ($w - 28 - 14) / 2
                    $n = [math]::Min(4, $keys.Count)
                    for ($i = 0; $i -lt $n; $i++) {
                        $k = $keys[$i]
                        $r = New-MetricRow $MetricInfo[$k].Label $cw ([bool]$MetricInfo[$k].Bar) 12.5
                        $r.Key = $k
                        if ($i % 2 -eq 0) { [void]$left.Children.Add($r.Panel) } else { [void]$right.Children.Add($r.Panel) }
                        [void]$rows.Add($r)
                    }
                    [void]$outer.Children.Add($cols)
                } else {
                    $maxRows = [math]::Max(1, [math]::Floor(($h - 46) / 31))
                    $n = [math]::Min($maxRows, $keys.Count)
                    $list = New-Object System.Windows.Controls.StackPanel; $list.Margin = '0,8,0,0'
                    for ($i = 0; $i -lt $n; $i++) {
                        $k = $keys[$i]
                        $r = New-MetricRow $MetricInfo[$k].Label ($w - 28) ([bool]$MetricInfo[$k].Bar) 13
                        $r.Key = $k
                        [void]$list.Children.Add($r.Panel); [void]$rows.Add($r)
                    }
                    [void]$outer.Children.Add($list)
                }
                $hint = New-TB 'Temperaturen: HWiNFO starten (Shared Memory an)' 10.5 'Normal' 0.6
                $hint.Visibility = 'Collapsed'
                [void]$outer.Children.Add($hint)
                [void]$grid.Children.Add($outer)
                [void]$script:Updaters.Add(@{ Kind = 'metrics'; Small = $false; Rows = $rows; Hint = $hint; Short = ($size -eq 'W') })
            }
        }
        'network' {
            $label = $false
            if ($size -eq 'S') {
                $sp = New-Object System.Windows.Controls.StackPanel
                $sp.HorizontalAlignment = 'Center'; $sp.VerticalAlignment = 'Center'
                $gl = New-Glyph 0xE839 22; $gl.Margin = '0,0,0,6'
                $dn = New-TB '↓ –' 15 'SemiBold'; $dn.HorizontalAlignment = 'Center'
                $up = New-TB '↑ –' 13 'Normal' 0.85; $up.HorizontalAlignment = 'Center'
                [void]$sp.Children.Add($gl); [void]$sp.Children.Add($dn); [void]$sp.Children.Add($up)
                [void]$grid.Children.Add($sp)
                [void]$script:Updaters.Add(@{ Kind = 'net'; Small = $true; Down = $dn; Up = $up })
            } else {
                $outer = New-Object System.Windows.Controls.Grid
                $outer.Margin = '14,12,14,10'
                foreach ($i in 0..2) { $rd = New-Object System.Windows.Controls.RowDefinition; if ($i -ne 2) { $rd.Height = [System.Windows.GridLength]::Auto }; $outer.RowDefinitions.Add($rd) }
                $hdr = New-Object System.Windows.Controls.StackPanel; $hdr.Orientation = 'Horizontal'
                $gl = New-Glyph 0xE839 14; $gl.Margin = '0,0,8,0'
                [void]$hdr.Children.Add($gl); [void]$hdr.Children.Add((New-TB ([string]$t.Name) 12 'SemiBold' 0.7))
                $vals = New-Object System.Windows.Controls.StackPanel; $vals.Orientation = 'Horizontal'; $vals.Margin = '0,4,0,4'
                $dn = New-TB '↓ –' 16 'SemiBold'; $dn.Foreground = $script:BarFg; $dn.Margin = '0,0,14,0'
                $up = New-TB '↑ –' 16 'SemiBold'; $up.Foreground = New-Brush '#30D158'
                [void]$vals.Children.Add($dn); [void]$vals.Children.Add($up)
                $info = $null
                $gh = $h - 70
                if ($size -eq 'L') {
                    $info = New-TB '' 11.5 'Normal' 0.65; $info.Margin = '0,0,0,6'
                    [void]$vals.Children.Clear(); $vals.Orientation = 'Vertical'
                    $dn.FontSize = 20; $up.FontSize = 20; $dn.Margin = '0'
                    [void]$vals.Children.Add($dn); [void]$vals.Children.Add($up); [void]$vals.Children.Add($info)
                    $gh = $h - 150
                }
                $spk = New-Spark ($w - 28) ([math]::Max(20, $gh))
                $spk.Canvas.VerticalAlignment = 'Bottom'
                [System.Windows.Controls.Grid]::SetRow($vals, 1); [System.Windows.Controls.Grid]::SetRow($spk.Canvas, 2)
                [void]$outer.Children.Add($hdr); [void]$outer.Children.Add($vals); [void]$outer.Children.Add($spk.Canvas)
                [void]$grid.Children.Add($outer)
                [void]$script:Updaters.Add(@{ Kind = 'net'; Small = $false; Down = $dn; Up = $up; Spark = $spk; Info = $info })
            }
        }
        'board' {
            $label = $false
            $outer = New-Object System.Windows.Controls.StackPanel
            $outer.Margin = '14,12,14,8'
            $hdr = New-Object System.Windows.Controls.StackPanel; $hdr.Orientation = 'Horizontal'
            $gl = New-Glyph 0xE950 14; $gl.Margin = '0,0,8,0'
            $title = New-TB ([string]$t.Name) 12 'SemiBold' 0.7
            $title.MaxWidth = $w - 54
            [void]$hdr.Children.Add($gl); [void]$hdr.Children.Add($title)
            $list = New-Object System.Windows.Controls.StackPanel; $list.Margin = '0,6,0,0'
            [void]$outer.Children.Add($hdr); [void]$outer.Children.Add($list)
            [void]$grid.Children.Add($outer)
            $maxRows = [math]::Max(1, [math]::Floor(($h - 40) / 19))
            [void]$script:Updaters.Add(@{ Kind = 'board'; List = $list; Title = $title; MaxRows = $maxRows; Small = ($size -eq 'S'); Named = ([string]$t.Name -ne 'Mainboard') })
        }
        'drive' {
            $label = $false
            $sp = New-Object System.Windows.Controls.StackPanel
            $sp.VerticalAlignment = 'Center'
            if ($size -eq 'S') { $sp.Margin = '12,0,12,0' } else { $sp.Margin = '16,0,16,0' }
            $bw = $w - 24; if ($size -ne 'S') { $bw = $w - 32 }
            $hdr = New-Object System.Windows.Controls.StackPanel; $hdr.Orientation = 'Horizontal'
            $gl = New-Glyph 0xEDA2 16; $gl.Margin = '0,0,8,0'
            [void]$hdr.Children.Add($gl)
            [void]$hdr.Children.Add((New-TB ([string]$t.Name) 14 'SemiBold'))
            $free = New-TB '' 13 'Normal' 0.9; $free.Margin = '0,8,0,0'; $free.TextWrapping = 'Wrap'
            $bar = New-Bar $bw
            [void]$sp.Children.Add($hdr); [void]$sp.Children.Add($free); [void]$sp.Children.Add($bar.Grid)
            [void]$grid.Children.Add($sp)
            [void]$script:Updaters.Add(@{ Kind = 'drive'; Drive = [string]$t.Target; Free = $free; Bar = $bar; Small = ($size -eq 'S') })
        }
        'security' {
            $label = $false
            if ($size -eq 'S') {
                $sp = New-Object System.Windows.Controls.StackPanel
                $sp.HorizontalAlignment = 'Center'; $sp.VerticalAlignment = 'Center'
                $ico = New-Glyph 0xEA18 40
                $txt = New-TB 'Prüfe ...' 13 'SemiBold'; $txt.HorizontalAlignment = 'Center'; $txt.Margin = '0,8,0,0'
                [void]$sp.Children.Add($ico); [void]$sp.Children.Add($txt)
                [void]$grid.Children.Add($sp)
                [void]$script:Updaters.Add(@{ Kind = 'security'; Small = $true; Icon = $ico; Short = $txt; Tip = $grid })
            } else {
                $sp = New-Object System.Windows.Controls.StackPanel
                $sp.Margin = '16,14,16,12'; $sp.VerticalAlignment = 'Center'
                $hdr = New-Object System.Windows.Controls.StackPanel; $hdr.Orientation = 'Horizontal'
                $ico = New-Glyph 0xEA18 16; $ico.Margin = '0,0,8,0'
                [void]$hdr.Children.Add($ico)
                [void]$hdr.Children.Add((New-TB 'Sicherheit & Updates' 13 'SemiBold' 0.8))
                [void]$sp.Children.Add($hdr)
                $def = New-StatusRow; $upd = New-StatusRow
                [void]$sp.Children.Add($def.Row); [void]$sp.Children.Add($upd.Row)
                $list = $null
                if ($big) {
                    $list = New-TB '' 12 'Normal' 0.75
                    $list.TextWrapping = 'Wrap'; $list.TextTrimming = 'WordEllipsis'; $list.Margin = '20,10,0,0'; $list.MaxHeight = $h - 150
                    [void]$sp.Children.Add($list)
                }
                [void]$grid.Children.Add($sp)
                [void]$script:Updaters.Add(@{ Kind = 'security'; Small = $false; Icon = $ico; Def = $def; Upd = $upd; List = $list; Tip = $grid })
            }
            if (-not $script:SecState) { $script:SecNext = [datetime]::MinValue }
        }
        'note' {
            $label = $false
            $sp = New-Object System.Windows.Controls.StackPanel
            $sp.Margin = '14,12,14,12'
            $hdr = New-TB ([string]$t.Name) 12 'SemiBold' 0.75
            $txt = New-TB ([string]$t.Target) 14 'Normal'
            if ($size -eq 'S') { $txt.FontSize = 12.5 }
            $txt.TextWrapping = 'Wrap'; $txt.TextTrimming = 'WordEllipsis'; $txt.Margin = '0,6,0,0'
            $txt.MaxHeight = $h - 40
            [void]$sp.Children.Add($hdr); [void]$sp.Children.Add($txt)
            [void]$grid.Children.Add($sp)
        }
        default {
            # app / folder / web / action
            $isz = 48; if ($big) { $isz = 72 }
            $el = $null
            if ($type -eq 'app' -or $type -eq 'folder') {
                $src = Get-IconSource ([string]$t.Target)
                if ($src) {
                    $img = New-Object System.Windows.Controls.Image
                    $img.Source = $src; $img.Width = $isz; $img.Height = $isz
                    [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($img, 'HighQuality')
                    $el = $img
                } elseif ($type -eq 'folder') { $el = New-Glyph 0xE8B7 ($isz * 0.75) }
                else { $el = New-Glyph 0xE71D ($isz * 0.75) }
            } elseif ($type -eq 'web') { $el = New-Glyph 0xE774 ($isz * 0.75) }
            elseif ($type -eq 'action') {
                $code = 0xE713
                if ($ActionGlyphs.ContainsKey([string]$t.Target)) { $code = $ActionGlyphs[[string]$t.Target] }
                $el = New-Glyph $code ($isz * 0.75)
            }
            if ($el) {
                $el.HorizontalAlignment = 'Center'; $el.VerticalAlignment = 'Center'
                if ($size -eq 'S') { $el.Margin = '0,0,0,16' } else { $el.Margin = '0,0,0,14' }
                [void]$grid.Children.Add($el)
            }
        }
    }
    if ($label -and $script:ShowLabels) {
        $lb = New-TB ([string]$t.Name) 12.5 'SemiBold'
        $lb.VerticalAlignment = 'Bottom'; $lb.HorizontalAlignment = 'Left'; $lb.Margin = '10,0,10,8'
        [void]$grid.Children.Add($lb)
    }
    return $grid
}

function Update-Tiles {
    $snap = Get-Snapshot
    $now = Get-Date
    foreach ($u in $script:Updaters) {
        try {
            switch ($u.Kind) {
                'clock' {
                    $u.Time.Text = $now.ToString('HH:mm')
                    if ($u.Size -eq 'S')     { $u.Date.Text = $now.ToString('ddd, d. MMM', $De) }
                    elseif ($u.Size -eq 'L') { $u.Date.Text = $now.ToString('dddd', $De) + "`n" + $now.ToString('d. MMMM yyyy', $De) }
                    else                     { $u.Date.Text = $now.ToString('dddd, d. MMMM', $De) }
                }
                'analog' {
                    $u.S.Angle = $now.Second * 6
                    $u.M.Angle = $now.Minute * 6 + $now.Second * 0.1
                    $u.H.Angle = ($now.Hour % 12) * 30 + $now.Minute * 0.5
                    if ($u.Time) { $u.Time.Text = $now.ToString('HH:mm') }
                    if ($u.Date) {
                        if ($u.Size -eq 'L') { $u.Date.Text = $now.ToString('dddd, d. MMMM', $De) }
                        else { $u.Date.Text = $now.ToString('dddd', $De) + "`n" + $now.ToString('d. MMMM', $De) }
                    }
                }
                'metrics' {
                    if ($u.Small) {
                        $r1 = Format-Metric $u.K1 $snap $true
                        $u.V1.Text = $r1[0]
                        if ($u.K2) { $r2 = Format-Metric $u.K2 $snap $true; $u.V2.Text = $MetricInfo[$u.K2].Label + '  ' + $r2[0] }
                    } else {
                        $missing = $false
                        foreach ($r in $u.Rows) {
                            $res = Format-Metric $r.Key $snap ([bool]$u.Short)
                            $r.Value.Text = $res[0]
                            Set-Bar $r.Bar ([double]$res[1])
                            if ($res[0] -eq '–' -and $MetricInfo[$r.Key].Hw) { $missing = $true }
                        }
                        if ($missing -and -not ($snap.Hw -and $snap.Hw.HwOk)) { $u.Hint.Visibility = 'Visible' } else { $u.Hint.Visibility = 'Collapsed' }
                    }
                }
                'net' {
                    $u.Down.Text = '↓ ' + (Format-Speed $snap.Down)
                    $u.Up.Text = '↑ ' + (Format-Speed $snap.Up)
                    if ($u.Spark) { Update-Spark $u.Spark }
                    if ($u.Info) {
                        $ad = [W11T.Net]::Adapter; $ip = [W11T.Net]::Ip
                        if ($ad) { $u.Info.Text = "$ad · $ip" } else { $u.Info.Text = 'Keine Verbindung' }
                    }
                }
                'board' {
                    $u.List.Children.Clear()
                    $hw = $snap.Hw
                    if (-not $hw -or -not $hw.HwOk) {
                        $tb = New-TB 'HWiNFO starten und "Shared Memory Support" aktivieren.' 12 'Normal' 0.75
                        $tb.TextWrapping = 'Wrap'
                        [void]$u.List.Children.Add($tb)
                        break
                    }
                    if (-not $u.Named -and $hw.BoardName) { $u.Title.Text = ($hw.BoardName -replace '\s*\(.*\)\s*$', '') }
                    $items = New-Object System.Collections.ArrayList
                    foreach ($r in $hw.BoardTemps) { [void]$items.Add(@($r.Label, ($r.Value.ToString('0', $De) + ' °C'))) }
                    foreach ($r in $hw.Fans) { [void]$items.Add(@($r.Label, ($r.Value.ToString('0', $De) + ' RPM'))) }
                    if ($items.Count -eq 0) { [void]$u.List.Children.Add((New-TB 'Keine Mainboard-Sensoren gefunden' 12 'Normal' 0.75)) }
                    $max = $u.MaxRows
                    for ($i = 0; $i -lt [math]::Min($max, $items.Count); $i++) {
                        $g = New-Object System.Windows.Controls.Grid
                        $c1 = New-Object System.Windows.Controls.ColumnDefinition
                        $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = [System.Windows.GridLength]::Auto
                        $g.ColumnDefinitions.Add($c1); $g.ColumnDefinitions.Add($c2)
                        $fs = 12.5; if ($u.Small) { $fs = 11.5 }
                        $l = New-TB ([string]$items[$i][0]) $fs 'Normal' 0.75
                        $v = New-TB ([string]$items[$i][1]) $fs 'SemiBold'; $v.Margin = '6,0,0,0'
                        [System.Windows.Controls.Grid]::SetColumn($v, 1)
                        [void]$g.Children.Add($l); [void]$g.Children.Add($v)
                        $g.Margin = '0,0,0,2'
                        [void]$u.List.Children.Add($g)
                    }
                }
                'security' {
                    $sum = Get-SecSummary
                    $u.Icon.Foreground = New-Brush $sum.Color
                    $tip = $sum.DefText + "`n" + $sum.UpdText
                    if ($sum.Titles.Count -gt 0) { $tip += "`n" + (($sum.Titles | ForEach-Object { '• ' + $_ }) -join "`n") }
                    if ($sum.UpdSub) { $tip += "`n" + $sum.UpdSub }
                    $tip += "`n(Rechtsklick > Jetzt prüfen)"
                    $u.Tip.ToolTip = $tip
                    if ($u.Small) { $u.Short.Text = $sum.Short }
                    else {
                        $u.Def.Dot.Fill = New-Brush $sum.DefColor; $u.Def.Text.Text = $sum.DefText; $u.Def.Sub.Text = $sum.DefSub
                        $u.Upd.Dot.Fill = New-Brush $sum.UpdColor; $u.Upd.Text.Text = $sum.UpdText; $u.Upd.Sub.Text = $sum.UpdSub
                        if ($u.List) {
                            if ($sum.Titles.Count -gt 0) { $u.List.Text = (($sum.Titles | ForEach-Object { '• ' + $_ }) -join "`n") } else { $u.List.Text = '' }
                        }
                    }
                }
                'drive' {
                    if (($script:TickN % 30) -ne 1 -and $u.Free.Text) { break }
                    $root = $u.Drive.Substring(0, 1) + ':\'
                    $di = New-Object System.IO.DriveInfo($root)
                    if ($di.IsReady) {
                        $tot = $di.TotalSize / 1GB; $fr = $di.AvailableFreeSpace / 1GB
                        if ($u.Small) { $u.Free.Text = ('{0:0} GB frei' -f $fr) }
                        else { $u.Free.Text = ('{0:0} GB frei von {1:0} GB' -f $fr, $tot) }
                        $u.Bar.Fill.Width = [math]::Max(0, $u.Bar.Width * (1 - $fr / $tot))
                    } else { $u.Free.Text = 'nicht bereit' }
                }
            }
        } catch { Write-Log "Update $($u.Kind): $_" }
    }
}

# ------------------------------------------------------------------ Aktionen
function Invoke-Tile($t) {
    try {
        $target = [Environment]::ExpandEnvironmentVariables([string]$t.Target)
        switch ([string]$t.Type) {
            'app'    { Start-Process -FilePath $target }
            'folder' { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $target) }
            'web'    { Start-Process -FilePath $target }
            'drive'  { Start-Process -FilePath 'explorer.exe' -ArgumentList ($target.Substring(0, 1) + ':\') }
            'system' { Start-Process -FilePath 'taskmgr.exe' }
            'network' { Start-Process -FilePath 'ms-settings:network-status' }
            'board' { Start-Process -FilePath 'taskmgr.exe' }
            'clock'  { Start-Process -FilePath 'ms-clock:' }
            'security' {
                $st = $script:SecState
                if ($st -and ($st.Updates -gt 0 -or $st.Reboot)) { Start-Process -FilePath 'ms-settings:windowsupdate' }
                elseif ($st -and ($st.DefOk -eq $true) -and $st.Threats -eq 0) { Start-Process -FilePath 'ms-settings:windowsupdate' }
                else { Start-Process -FilePath 'windowsdefender:' }
                $script:SecNext = (Get-Date).AddSeconds(20)
            }
            'action' {
                switch ($target) {
                    'lock'     { Start-Process -FilePath 'rundll32.exe' -ArgumentList 'user32.dll,LockWorkStation' }
                    'restart'  { if ([System.Windows.MessageBox]::Show('PC jetzt neu starten?', 'Kachel', 'YesNo', 'Question') -eq 'Yes') { Start-Process -FilePath 'shutdown.exe' -ArgumentList '/r /t 0' } }
                    'shutdown' { if ([System.Windows.MessageBox]::Show('PC jetzt herunterfahren?', 'Kachel', 'YesNo', 'Question') -eq 'Yes') { Start-Process -FilePath 'shutdown.exe' -ArgumentList '/s /t 0' } }
                    'recycle'  { Start-Process -FilePath 'explorer.exe' -ArgumentList 'shell:RecycleBinFolder' }
                    'settings' { Start-Process -FilePath 'ms-settings:' }
                    'explorer' { Start-Process -FilePath 'explorer.exe' }
                    'taskmgr'  { Start-Process -FilePath 'taskmgr.exe' }
                }
            }
        }
    } catch {
        Write-Log "Öffnen $($t.Name): $_"
        [void][System.Windows.MessageBox]::Show("'$($t.Name)' konnte nicht geöffnet werden:`n$($_.Exception.Message)", 'Kachel', 'OK', 'Warning')
    }
}

function Snap-AndSave($win) {
    $wa = [System.Windows.SystemParameters]::WorkArea
    $step = ($script:U + $script:G) / 2
    $pad = [double]$win.Tag.Pad
    $tw = $win.Width - 2 * $pad; $th = $win.Height - 2 * $pad
    $x = $wa.Left + [math]::Round(($win.Left + $pad - $wa.Left) / $step) * $step
    $y = $wa.Top  + [math]::Round(($win.Top + $pad - $wa.Top) / $step) * $step
    $x = [math]::Max($wa.Left, [math]::Min($x, $wa.Right - $tw))
    $y = [math]::Max($wa.Top,  [math]::Min($y, $wa.Bottom - $th))
    $win.Left = $x - $pad; $win.Top = $y - $pad
    $cfg = Load-Config
    if (-not $cfg) { return }
    foreach ($t in @($cfg.Tiles)) {
        if ($t.Id -eq $win.Tag.Id) { Set-Prop $t 'X' ([double]$x); Set-Prop $t 'Y' ([double]$y) }
    }
    Save-Config $cfg
}

function Invoke-Menu($tag) {
    try {
        switch ($tag.Cmd) {
            'customize' {
                if ($env:W11C_EXE -and (Test-Path $env:W11C_EXE)) { Start-Process -FilePath $env:W11C_EXE; return }
                $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
                $main = Join-Path $PSScriptRoot 'Win11Customizer.ps1'
                Start-Process -FilePath $ps -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $main)) -WindowStyle Hidden
            }
            'check' { $script:SecNext = [datetime]::MinValue; Start-SecCheck }
            'remove' {
                $cfg = Load-Config; if (-not $cfg) { return }
                $cfg.Tiles = @(@($cfg.Tiles) | Where-Object { $_.Id -ne $tag.Id })
                Save-Config $cfg; Rebuild
            }
            'arrange' {
                $cfg = Load-Config; if (-not $cfg) { return }
                foreach ($t in @($cfg.Tiles)) { Set-Prop $t 'X' $null; Set-Prop $t 'Y' $null }
                Save-Config $cfg; Rebuild
            }
            'hide' {
                $cfg = Load-Config; if (-not $cfg) { return }
                Set-Prop $cfg 'Enabled' $false
                Save-Config $cfg; Stop-Host
            }
        }
    } catch { Write-Log "Menü: $_" }
}

# ------------------------------------------------------------------ Fenster
function New-TileWindow($t, [int]$index, $cfg) {
    $sz = Get-TileSize ([string]$t.Size)
    $w = $sz[0]; $h = $sz[1]
    $style   = [string](Get-Opt $cfg 'Style' 'mac-dark')
    $opacity = [double](Get-Opt $cfg 'Opacity' '0.9')
    $corners = [string](Get-Opt $cfg 'Corners' 'mac')
    $shadow  = [string](Get-Opt $cfg 'Shadow' 'on') -ne 'off'

    $color = [string]$t.Color
    $border = $null
    $fgHex = '#FFFFFF'; $barFgHex = '#FFFFFF'; $barBgA = 0.22
    if ($color -match '^#[0-9A-Fa-f]{6}$') { $bg = $color }
    elseif ($style -eq 'accent')   { $bg = $script:AccentHex }
    elseif ($style -eq 'color')    { $bg = $Palette[$index % $Palette.Count] }
    elseif ($style -eq 'mac-light') { $bg = '#F5F5F7'; $fgHex = '#1D1D1F'; $barFgHex = $script:AccentHex; $barBgA = 0.12; $border = New-Brush '#000000' 0.07 }
    elseif ($style -eq 'mac-dark')  { $bg = '#1C1C1E'; $barFgHex = $script:AccentHex; $barBgA = 0.16; $border = New-Brush '#FFFFFF' 0.09 }
    else { $bg = '#15171F'; $border = New-Brush '#FFFFFF' 0.16 }
    $script:Fg = New-Brush $fgHex
    $script:BarFg = New-Brush $barFgHex
    $script:BarBg = New-Brush $fgHex $barBgA
    $pad = 0; if ($shadow) { $pad = 16 }

    $win = New-Object System.Windows.Window
    $win.WindowStyle = 'None'; $win.AllowsTransparency = $true; $win.ResizeMode = 'NoResize'
    $win.Background = [System.Windows.Media.Brushes]::Transparent
    $win.ShowInTaskbar = $false; $win.ShowActivated = $false; $win.Topmost = $false
    $win.WindowStartupLocation = 'Manual'
    $win.Width = $w + 2 * $pad; $win.Height = $h + 2 * $pad
    $win.Left = [double]$t.X - $pad; $win.Top = [double]$t.Y - $pad
    $win.Title = "Kachel - $($t.Name)"
    $win.Cursor = [System.Windows.Input.Cursors]::Hand

    $radius = 22
    if ($corners -eq 'square') { $radius = 0 } elseif ($corners -eq 'round') { $radius = 12 }
    $root = New-Object System.Windows.Controls.Border
    $root.Width = $w; $root.Height = $h
    $root.Margin = New-Object System.Windows.Thickness($pad)
    $root.CornerRadius = New-Object System.Windows.CornerRadius($radius)
    $root.Background = New-Brush $bg $opacity
    if ($border) { $root.BorderBrush = $border; $root.BorderThickness = '1' }
    if ($shadow) {
        $fx = New-Object System.Windows.Media.Effects.DropShadowEffect
        $fx.BlurRadius = 18; $fx.ShadowDepth = 4; $fx.Direction = 270; $fx.Opacity = 0.35; $fx.Color = [System.Windows.Media.Colors]::Black
        $root.Effect = $fx
    }
    $root.RenderTransformOrigin = '0.5,0.5'
    $scale = New-Object System.Windows.Media.ScaleTransform(1.0, 1.0)
    $root.RenderTransform = $scale

    $grid = New-Object System.Windows.Controls.Grid
    [void]$grid.Children.Add((New-TileContent $t $w $h))
    $ov = New-Object System.Windows.Controls.Border
    $ov.CornerRadius = New-Object System.Windows.CornerRadius($radius)
    $ov.Background = $script:Fg; $ov.Opacity = 0; $ov.IsHitTestVisible = $false
    [void]$grid.Children.Add($ov)
    $root.Child = $grid
    $win.Content = $root
    $win.Tag = @{ Id = [string]$t.Id; Tile = $t; Ov = $ov; Scale = $scale; Pad = $pad }

    # Rechtsklick-Menü
    $cm = New-Object System.Windows.Controls.ContextMenu
    foreach ($it in @(@('Kacheln anpassen ...', 'customize'), @('Sicherheit & Updates jetzt prüfen', 'check'), @('Diese Kachel entfernen', 'remove'), @('Alle Kacheln neu anordnen', 'arrange'), @('Kacheln ausblenden', 'hide'))) {
        $mi = New-Object System.Windows.Controls.MenuItem
        $mi.Header = $it[0]
        $mi.Tag = @{ Cmd = $it[1]; Id = [string]$t.Id }
        $mi.add_Click({ param($s, $e) Invoke-Menu $s.Tag })
        [void]$cm.Items.Add($mi)
    }
    $win.ContextMenu = $cm

    $win.add_SourceInitialized({ param($s, $e)
        try { [W11T.Native]::PinToDesktop((New-Object System.Windows.Interop.WindowInteropHelper $s).Handle) } catch { Write-Log "Pin: $_" } })
    $win.add_Activated({ param($s, $e)
        try { [W11T.Native]::SendToBottom((New-Object System.Windows.Interop.WindowInteropHelper $s).Handle) } catch {} })
    $win.add_MouseEnter({ param($s, $e) $s.Tag.Ov.Opacity = 0.07 })
    $win.add_MouseLeave({ param($s, $e) $s.Tag.Ov.Opacity = 0; $s.Tag.Scale.ScaleX = 1; $s.Tag.Scale.ScaleY = 1 })
    $win.add_MouseLeftButtonDown({ param($s, $e)
        $s.Tag.Scale.ScaleX = 0.97; $s.Tag.Scale.ScaleY = 0.97
        $x0 = $s.Left; $y0 = $s.Top
        try { $s.DragMove() } catch {}
        $s.Tag.Scale.ScaleX = 1; $s.Tag.Scale.ScaleY = 1
        if ([math]::Abs($s.Left - $x0) -gt 3 -or [math]::Abs($s.Top - $y0) -gt 3) { Snap-AndSave $s }
        else { Invoke-Tile $s.Tag.Tile }
        try { [W11T.Native]::SendToBottom((New-Object System.Windows.Interop.WindowInteropHelper $s).Handle) } catch {}
    })
    return $win
}

function Stop-Host {
    foreach ($w in @($script:Windows)) { try { $w.Close() } catch {} }
    $script:Windows.Clear(); $script:Updaters.Clear()
    if ($script:Timer) { $script:Timer.Stop() }
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
}

function Rebuild {
    $cfg = Load-Config
    if ($null -eq $cfg -or -not $cfg.Enabled) { Stop-Host; return }
    $script:LastWrite = (Get-Item $CfgFile).LastWriteTimeUtc
    $script:AccentHex = Get-AccentHex
    $script:ProgmanH = [W11T.Native]::Progman()

    foreach ($w in @($script:Windows)) { try { $w.Close() } catch {} }
    $script:Windows.Clear(); $script:Updaters.Clear()

    $sc = 1.0
    try { $sc = [double](Get-Opt $cfg 'Scale' '1') } catch {}
    if ($sc -lt 0.5 -or $sc -gt 3) { $sc = 1.0 }
    $script:U = [math]::Round(120 * $sc); $script:G = [math]::Round(12 * $sc)
    $script:ShowLabels = ([string](Get-Opt $cfg 'Labels' 'on')) -ne 'off'
    $script:ClockStyle = [string](Get-Opt $cfg 'ClockStyle' 'analog')

    if (-not $cfg.PSObject.Properties['Tiles']) { Set-Prop $cfg 'Tiles' @() }
    $cfg.Tiles = @(@($cfg.Tiles) | Where-Object { $_ })
    $script:NetUnit = [string](Get-Opt $cfg 'NetUnit' 'MBs')
    $script:NeedHw = $false; $script:NeedNet = $false; $script:NeedGpu = $false
    foreach ($t in @($cfg.Tiles)) {
        switch ([string]$t.Type) {
            'network' { $script:NeedNet = $true }
            'board'   { $script:NeedHw = $true }
            'system'  {
                foreach ($k in (Get-TileMetrics $t)) {
                    if ($MetricInfo[$k].Hw)  { $script:NeedHw = $true }
                    if ($MetricInfo[$k].Gpu) { $script:NeedGpu = $true }
                    if ($MetricInfo[$k].Net) { $script:NeedNet = $true }
                }
            }
        }
    }
    if (Place-Tiles $cfg) { Save-Config $cfg }

    $i = 0
    foreach ($t in @($cfg.Tiles)) {
        try {
            $w = New-TileWindow $t $i $cfg
            [void]$script:Windows.Add($w)
            $w.Show()
        } catch { Write-Log "Kachel '$($t.Name)': $_" }
        $i++
    }
    [void][W11T.Native]::Cpu()
    Update-Tiles
}

function On-Tick {
    $script:TickN++
    Poll-SecCheck
    $hasSec = $false
    foreach ($u in $script:Updaters) { if ($u.Kind -eq 'security') { $hasSec = $true; break } }
    if ($hasSec -and -not $script:SecJob -and (Get-Date) -ge $script:SecNext) { Start-SecCheck }
    if (($script:TickN % 2) -eq 0) {
        if (-not (Test-Path $CfgFile)) { Stop-Host; return }
        $lw  = (Get-Item $CfgFile).LastWriteTimeUtc
        $acc = Get-AccentHex
        $pm  = [W11T.Native]::Progman()
        $explorerNew = ($pm -ne [IntPtr]::Zero -and $pm -ne $script:ProgmanH)
        if ($lw -ne $script:LastWrite -or $acc -ne $script:AccentHex -or $explorerNew) { Rebuild; return }
    }
    Update-Tiles
}

# ------------------------------------------------------------------ Start
try {
    $first = Load-Config
    if ($null -eq $first -or -not $first.Enabled) { return }
    Rebuild
    $script:Timer = New-Object System.Windows.Threading.DispatcherTimer
    $script:Timer.Interval = [TimeSpan]::FromSeconds(1)
    $script:Timer.add_Tick({ try { On-Tick } catch { Write-Log "Tick: $_" } })
    $script:Timer.Start()
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.add_UnhandledException({
        param($s, $e)
        $e.Handled = $true
        $pos = ''
        try { if ($e.Exception.ErrorRecord) { $pos = $e.Exception.ErrorRecord.InvocationInfo.PositionMessage } } catch {}
        Write-Log ("Fehler: {0}`n{1}" -f $e.Exception.Message, $pos)
    })
    [System.Windows.Threading.Dispatcher]::Run()
} catch {
    Write-Log "Absturz: $_"
} finally {
    try { $mutex.ReleaseMutex() } catch {}
    $mutex.Dispose()
}
