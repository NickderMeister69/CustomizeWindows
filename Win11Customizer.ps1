#Requires -Version 5.1
<#
    Win11 Customizer  -  Windows 11 komplett nach deinem Geschmack anpassen
    ---------------------------------------------------------------------
    - Läuft mit dem in Windows eingebauten PowerShell 5.1 (keine Installation nötig)
    - Ändert nur Einstellungen deines Benutzerkontos (HKCU) -> keine Admin-Rechte nötig
    - Jeder Originalwert wird vor der ersten Änderung automatisch gesichert und
      lässt sich über "Backup & Profile" mit einem Klick wiederherstellen.
    Start: Doppelklick auf "Win11 Customizer starten.bat"
#>

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$AppVersion = '1.0'
$AppDir     = Join-Path $env:APPDATA 'Win11Customizer'
$BackupFile = Join-Path $AppDir 'original-backup.json'
$LogFile    = Join-Path $AppDir 'error.log'
if (-not (Test-Path $AppDir)) { New-Item -ItemType Directory -Path $AppDir -Force | Out-Null }

function Write-Log([string]$msg) {
    try { Add-Content -Path $LogFile -Value ("[{0}] {1}" -f (Get-Date -Format 's'), $msg) -Encoding UTF8 } catch {}
}

# =====================================================================
#  Native Windows-Funktionen
# =====================================================================
if (-not ('W11C.Native' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace W11C {
    public static class Native {
        [StructLayout(LayoutKind.Sequential)]
        public struct ANIMATIONINFO { public uint cbSize; public int iMinAnimate; }

        [DllImport("user32.dll", EntryPoint = "SystemParametersInfoW", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool SPISetStr(uint a, uint p, string v, uint f);
        [DllImport("user32.dll", EntryPoint = "SystemParametersInfoW", SetLastError = true)]
        public static extern bool SPISetPtr(uint a, uint p, IntPtr v, uint f);
        [DllImport("user32.dll", EntryPoint = "SystemParametersInfoW", SetLastError = true)]
        static extern bool SPIGetBool(uint a, uint p, ref bool v, uint f);
        [DllImport("user32.dll", EntryPoint = "SystemParametersInfoW", SetLastError = true)]
        static extern bool SPIInts(uint a, uint p, int[] v, uint f);
        [DllImport("user32.dll", EntryPoint = "SystemParametersInfoW", SetLastError = true)]
        static extern bool SPIAnim(uint a, uint p, ref ANIMATIONINFO v, uint f);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr SendMessageTimeout(IntPtr h, uint m, UIntPtr w, string l, uint flags, uint timeout, out UIntPtr r);
        [DllImport("user32.dll")]
        static extern bool SetSysColors(int c, int[] e, int[] v);
        [DllImport("dwmapi.dll")]
        static extern int DwmSetWindowAttribute(IntPtr h, int a, ref int v, int s);

        public static bool GetBool(uint a) { bool v = false; SPIGetBool(a, 0, ref v, 0); return v; }
        public static bool SetBool(uint a, bool v) { return SPISetPtr(a, 0, v ? new IntPtr(1) : IntPtr.Zero, 3); }
        public static bool SetMouse(int t1, int t2, int speed) { return SPIInts(4, 0, new int[] { t1, t2, speed }, 3); }
        public static bool SetMinAnimate(bool on) {
            ANIMATIONINFO ai = new ANIMATIONINFO();
            ai.cbSize = (uint)Marshal.SizeOf(typeof(ANIMATIONINFO));
            ai.iMinAnimate = on ? 1 : 0;
            return SPIAnim(0x49, ai.cbSize, ref ai, 3);
        }
        public static void Broadcast(string area) {
            UIntPtr r;
            SendMessageTimeout(new IntPtr(0xffff), 0x1A, UIntPtr.Zero, area, 2, 1500, out r);
        }
        public static void SetDesktopColor(int r, int g, int b) {
            SetSysColors(1, new int[] { 1 }, new int[] { r | (g << 8) | (b << 16) });
        }
        public static void StyleWindow(IntPtr h) {
            int round = 2; DwmSetWindowAttribute(h, 33, ref round, 4);
            int dark = 1;  DwmSetWindowAttribute(h, 20, ref dark, 4);
        }
    }
}
'@
}

# =====================================================================
#  Registry-Helfer mit automatischem Original-Backup
# =====================================================================
$HK   = [Microsoft.Win32.Registry]::CurrentUser
$ADV  = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$PERS = 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
$DWM  = 'Software\Microsoft\Windows\DWM'
$ACC  = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Accent'
$SRCH = 'Software\Microsoft\Windows\CurrentVersion\Search'
$CDM  = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
$DESK = 'Control Panel\Desktop'
$ICONS = 'Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel'
$CLASSIC_ROOT = 'Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}'
$CLASSIC = "$CLASSIC_ROOT\InprocServer32"

$script:Backup = @{}
$script:DeferSave = $false

function ConvertTo-DWord([int64]$v) {
    if ($v -gt 2147483647) { $v = $v - 4294967296 }
    return [int32]$v
}

function ConvertFrom-HexBytes([string]$hex) {
    if ([string]::IsNullOrEmpty($hex)) { return ,([byte[]]@()) }
    $b = New-Object byte[] ([int]($hex.Length / 2))
    for ($i = 0; $i -lt $b.Length; $i++) { $b[$i] = [Convert]::ToByte($hex.Substring($i * 2, 2), 16) }
    return ,$b
}

function Get-Reg([string]$Path, [string]$Name, $Default = $null) {
    $k = $null
    try {
        $k = $HK.OpenSubKey($Path)
        if ($null -eq $k) { return $Default }
        $v = $k.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($null -eq $v) { return $Default }
        if ($v -is [array]) { return ,$v }
        return $v
    } catch { return $Default }
    finally { if ($k) { $k.Close() } }
}

function Get-CurrentEntry([string]$Path, [string]$Name) {
    $e = [ordered]@{ Path = $Path; Name = $Name; Exists = $false; KeyExisted = $false; Kind = ''; Value = $null }
    $k = $HK.OpenSubKey($Path)
    if ($k) {
        $e.KeyExisted = $true
        try {
            if (@($k.GetValueNames()) -contains $Name) {
                $kind = $k.GetValueKind($Name).ToString()
                $val  = $k.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                if ($kind -eq 'Binary') { $val = (@($val) | ForEach-Object { ([byte]$_).ToString('X2') }) -join '' }
                $e.Exists = $true; $e.Kind = $kind; $e.Value = $val
            }
        } finally { $k.Close() }
    }
    return [pscustomobject]$e
}

function Load-Backup {
    $script:Backup = @{}
    if (Test-Path $BackupFile) {
        try {
            $data = Get-Content $BackupFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($e in @($data)) { if ($e.Path) { $script:Backup["$($e.Path)|$($e.Name)"] = $e } }
        } catch { Write-Log "Backup konnte nicht gelesen werden: $_" }
    }
}

function Save-Backup {
    try {
        $json = ConvertTo-Json -InputObject @($script:Backup.Values) -Depth 5
        Set-Content -Path $BackupFile -Value $json -Encoding UTF8
    } catch { Write-Log "Backup konnte nicht gespeichert werden: $_" }
}

function Remember-Original([string]$Path, [string]$Name) {
    $key = "$Path|$Name"
    if ($script:Backup.ContainsKey($key)) { return }
    $script:Backup[$key] = Get-CurrentEntry $Path $Name
    if (-not $script:DeferSave) { Save-Backup }
}

function Remember-SPI([string]$Name, [uint32]$GetCode, [uint32]$SetCode) {
    $key = "SPI|$Name"
    if ($script:Backup.ContainsKey($key)) { return }
    $script:Backup[$key] = [pscustomobject]@{
        Path = 'SPI'; Name = $Name; Exists = $true; KeyExisted = $true; Kind = 'Bool'
        Value = [W11C.Native]::GetBool($GetCode); GetCode = $GetCode; SetCode = $SetCode
    }
    if (-not $script:DeferSave) { Save-Backup }
}

function Set-Reg([string]$Path, [string]$Name, $Value, [string]$Kind = 'DWord') {
    Remember-Original $Path $Name
    $k = $HK.CreateSubKey($Path)
    if ($null -eq $k) { throw "Registry-Schlüssel nicht beschreibbar: $Path" }
    try {
        switch ($Kind) {
            'DWord'       { $Value = ConvertTo-DWord ([int64]$Value) }
            'QWord'       { $Value = [int64]$Value }
            'Binary'      { if ($Value -is [string]) { $Value = ConvertFrom-HexBytes $Value } else { $Value = [byte[]]$Value } }
            'MultiString' { $Value = [string[]]@($Value) }
            default       { $Value = [string]$Value }
        }
        $k.SetValue($Name, $Value, [Microsoft.Win32.RegistryValueKind]$Kind)
    } finally { $k.Close() }
}

function Remove-RegValueTracked([string]$Path, [string]$Name, [bool]$KeyExisted = $true) {
    Remember-Original $Path $Name
    $k = $HK.OpenSubKey($Path, $true)
    if ($null -eq $k) { return }
    $k.DeleteValue($Name, $false)
    $empty = ($k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0)
    $k.Close()
    if ($empty -and -not $KeyExisted) {
        try { $HK.DeleteSubKey($Path, $false) } catch {}
        # leere, von uns angelegte CLSID-Schlüssel ebenfalls entfernen
        if ($Path -like 'Software\Classes\CLSID\*') {
            $parent = $Path.Substring(0, $Path.LastIndexOf('\'))
            $pk = $HK.OpenSubKey($parent)
            if ($pk -and $parent -ne 'Software\Classes\CLSID') {
                $pEmpty = ($pk.ValueCount -eq 0 -and $pk.SubKeyCount -eq 0); $pk.Close()
                if ($pEmpty) { try { $HK.DeleteSubKey($parent, $false) } catch {} }
            } elseif ($pk) { $pk.Close() }
        }
    }
}

function Apply-Entry($e) {
    if ($e.Path -eq 'SPI') {
        Remember-SPI $e.Name ([uint32]$e.GetCode) ([uint32]$e.SetCode)
        [void][W11C.Native]::SetBool([uint32]$e.SetCode, [bool]$e.Value)
        return
    }
    if ($e.Exists) {
        $kind = [string]$e.Kind
        $val  = $e.Value
        if ($kind -eq 'Binary')      { $val = [string]$val }
        elseif ($kind -eq 'MultiString') { $val = [string[]]@($val) }
        elseif ($kind -ne 'DWord' -and $kind -ne 'QWord') { $val = [string]$val }
        Set-Reg $e.Path $e.Name $val $kind
    } else {
        Remove-RegValueTracked $e.Path $e.Name ([bool]$e.KeyExisted)
    }
}

function Send-SettingChange {
    foreach ($a in @('ImmersiveColorSet', 'TraySettings', 'WindowsThemeElement')) {
        try { [W11C.Native]::Broadcast($a) } catch {}
    }
}

# =====================================================================
#  Farb-Helfer
# =====================================================================
function ConvertFrom-Hex([string]$hex) {
    $h = $hex.Trim().TrimStart('#')
    [pscustomobject]@{
        R = [Convert]::ToInt32($h.Substring(0, 2), 16)
        G = [Convert]::ToInt32($h.Substring(2, 2), 16)
        B = [Convert]::ToInt32($h.Substring(4, 2), 16)
    }
}
function Format-Hex($c) { '#{0:X2}{1:X2}{2:X2}' -f [int]$c.R, [int]$c.G, [int]$c.B }
function Mix-Color($c, [int]$r, [int]$g, [int]$b, [double]$f) {
    [pscustomobject]@{
        R = [int][math]::Round($c.R + ($r - $c.R) * $f)
        G = [int][math]::Round($c.G + ($g - $c.G) * $f)
        B = [int][math]::Round($c.B + ($b - $c.B) * $f)
    }
}
function WColor([string]$hex) { [System.Windows.Media.Color]([System.Windows.Media.ColorConverter]::ConvertFromString($hex)) }
function Brush([string]$hex) { $b = [System.Windows.Media.SolidColorBrush]::new((WColor $hex)); $b.Freeze(); return $b }
function DColor([string]$hex, [int]$a) { $c = ConvertFrom-Hex $hex; [System.Drawing.Color]::FromArgb($a, $c.R, $c.G, $c.B) }

function Get-AccentHex {
    $v = Get-Reg $DWM 'AccentColor' $null
    if ($null -eq $v) { $v = Get-Reg $ACC 'AccentColorMenu' $null }
    if ($null -eq $v) { return '#0078D4' }
    $u = [BitConverter]::GetBytes([int]$v)   # ABGR -> Bytes R,G,B,A
    return ('#{0:X2}{1:X2}{2:X2}' -f $u[0], $u[1], $u[2])
}

function Set-AccentColor([string]$hex) {
    $c = ConvertFrom-Hex $hex
    $shades = @(
        (Mix-Color $c 255 255 255 0.55), (Mix-Color $c 255 255 255 0.35), (Mix-Color $c 255 255 255 0.18),
        $c,
        (Mix-Color $c 0 0 0 0.18), (Mix-Color $c 0 0 0 0.36), (Mix-Color $c 0 0 0 0.55), (Mix-Color $c 0 0 0 0.70)
    )
    $bytes = New-Object System.Collections.Generic.List[byte]
    foreach ($s in $shades) { $bytes.Add([byte]$s.R); $bytes.Add([byte]$s.G); $bytes.Add([byte]$s.B); $bytes.Add([byte]0) }
    $abgr  = [int64]4278190080 + [int64]$c.B * 65536 + [int64]$c.G * 256 + [int64]$c.R
    $d2    = $shades[5]
    $abgr2 = [int64]4278190080 + [int64]$d2.B * 65536 + [int64]$d2.G * 256 + [int64]$d2.R
    $argb  = [int64]3288334336 + [int64]$c.R * 65536 + [int64]$c.G * 256 + [int64]$c.B   # 0xC4RRGGBB

    Set-Reg $DESK 'AutoColorization' 0
    Set-Reg $ACC  'AccentPalette'   ([byte[]]$bytes.ToArray()) 'Binary'
    Set-Reg $ACC  'AccentColorMenu' $abgr
    Set-Reg $ACC  'StartColorMenu'  $abgr2
    Set-Reg $DWM  'AccentColor'     $abgr
    Set-Reg $DWM  'ColorizationColor'     $argb
    Set-Reg $DWM  'ColorizationAfterglow' $argb
    Send-SettingChange
}

# =====================================================================
#  Spezial-Funktionen (Hintergrund, Mauszeiger, Sounds, Explorer)
# =====================================================================
function Set-Wallpaper([string]$file, [string]$style) {
    if ($style) { Set-Reg $DESK 'WallpaperStyle' $style 'String'; Set-Reg $DESK 'TileWallpaper' '0' 'String' }
    Remember-Original $DESK 'Wallpaper'
    if (-not [W11C.Native]::SPISetStr(0x14, 0, $file, 3)) { throw 'Hintergrundbild konnte nicht gesetzt werden.' }
}

function Set-SolidBackground([string]$hex) {
    $c = ConvertFrom-Hex $hex
    Set-Reg 'Control Panel\Colors' 'Background' ("{0} {1} {2}" -f $c.R, $c.G, $c.B) 'String'
    Remember-Original $DESK 'Wallpaper'
    [void][W11C.Native]::SPISetStr(0x14, 0, '', 3)
    [W11C.Native]::SetDesktopColor($c.R, $c.G, $c.B)
}

function Draw-Glow($g, [string]$hex, [int]$x, [int]$y, [int]$w, [int]$h, [int]$alpha) {
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddEllipse($x, $y, $w, $h)
    $pg = New-Object System.Drawing.Drawing2D.PathGradientBrush($path)
    $pg.CenterColor = DColor $hex $alpha
    $pg.SurroundColors = [System.Drawing.Color[]]@((DColor $hex 0))
    $g.FillPath($pg, $path)
    $pg.Dispose(); $path.Dispose()
}

function New-GradientWallpaper([string]$name, [string[]]$colors, [string]$glow) {
    $dir = Join-Path $AppDir 'Wallpapers'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $file = Join-Path $dir (($name -replace '[^A-Za-z0-9]', '_') + '.png')
    if (Test-Path $file) { return $file }
    $w = 3840; $h = 2160
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
        $cols = @($colors | ForEach-Object { DColor $_ 255 })
        $lg = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $cols[0], $cols[-1], [single]30)
        $blend = New-Object System.Drawing.Drawing2D.ColorBlend($cols.Count)
        $blend.Colors = [System.Drawing.Color[]]$cols
        $pos = New-Object 'single[]' $cols.Count
        for ($i = 0; $i -lt $cols.Count; $i++) { $pos[$i] = [single]($i / ($cols.Count - 1)) }
        $blend.Positions = $pos
        $lg.InterpolationColors = $blend
        $g.FillRectangle($lg, $rect)
        $lg.Dispose()
        Draw-Glow $g $glow 2100 900 2600 2000 95
        Draw-Glow $g $glow -500 -500 2200 1700 55
        Draw-Glow $g $glow 1200 1500 1600 1200 35
        $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally { $g.Dispose(); $bmp.Dispose() }
    return $file
}

$CursorMap = [ordered]@{
    Arrow = 'aero_arrow{0}.cur'; Help = 'aero_helpsel{0}.cur'; AppStarting = 'aero_working{0}.ani'
    Wait = 'aero_busy{0}.ani'; NWPen = 'aero_pen{0}.cur'; No = 'aero_unavail{0}.cur'
    SizeNS = 'aero_ns{0}.cur'; SizeWE = 'aero_ew{0}.cur'; SizeNWSE = 'aero_nwse{0}.cur'
    SizeNESW = 'aero_nesw{0}.cur'; SizeAll = 'aero_move{0}.cur'; UpArrow = 'aero_up{0}.cur'
    Hand = 'aero_link{0}.cur'; Pin = 'aero_pin{0}.cur'; Person = 'aero_person{0}.cur'
}
function Set-CursorSize([int]$size) {
    $suffix = @('', '_l', '_xl')[$size]
    $names  = @('Windows Standard', 'Windows Standard (groß)', 'Windows Standard (sehr groß)')
    $p = 'Control Panel\Cursors'
    $script:DeferSave = $true
    try {
        foreach ($kv in $CursorMap.GetEnumerator()) {
            $file = $kv.Value -f $suffix
            if (-not (Test-Path (Join-Path $env:WINDIR "Cursors\$file"))) { $file = $kv.Value -f '' }
            if (Test-Path (Join-Path $env:WINDIR "Cursors\$file")) {
                Set-Reg $p $kv.Key "%SystemRoot%\cursors\$file" 'ExpandString'
            }
        }
        Set-Reg $p '' $names[$size] 'String'
    } finally { $script:DeferSave = $false; Save-Backup }
    [void][W11C.Native]::SPISetPtr(0x57, 0, [IntPtr]::Zero, 3)
}

function Set-SystemSounds([bool]$on) {
    $root = 'AppEvents\Schemes\Apps'
    $script:DeferSave = $true
    try {
        $apps = $HK.OpenSubKey($root)
        if ($apps) {
            foreach ($app in $apps.GetSubKeyNames()) {
                $ak = $apps.OpenSubKey($app)
                if (-not $ak) { continue }
                foreach ($ev in $ak.GetSubKeyNames()) {
                    $cur = "$root\$app\$ev\.Current"
                    if ($on) {
                        $src = Get-CurrentEntry "$root\$app\$ev\.Default" ''
                        if ($src.Exists) { Set-Reg $cur '' $src.Value $src.Kind }
                    } else {
                        $ck = $HK.OpenSubKey($cur)
                        if ($ck) { $ck.Close(); Set-Reg $cur '' '' 'String' }
                    }
                }
                $ak.Close()
            }
            $apps.Close()
        }
        $scheme = '.None'; if ($on) { $scheme = '.Default' }
        Set-Reg 'AppEvents\Schemes' '' $scheme 'String'
    } finally { $script:DeferSave = $false; Save-Backup }
}

function Apply-Live {
    try { [void][W11C.Native]::SPISetPtr(0x57, 0, [IntPtr]::Zero, 3) } catch {}
    try {
        $s  = [int](Get-Reg 'Control Panel\Mouse' 'MouseSpeed' '1')
        $t1 = [int](Get-Reg 'Control Panel\Mouse' 'MouseThreshold1' '6')
        $t2 = [int](Get-Reg 'Control Panel\Mouse' 'MouseThreshold2' '10')
        [void][W11C.Native]::SetMouse($t1, $t2, $s)
    } catch {}
    try { [void][W11C.Native]::SPISetPtr(0x6B, [uint32](Get-Reg $DESK 'MenuShowDelay' '400'), [IntPtr]::Zero, 3) } catch {}
    try { [void][W11C.Native]::SetMinAnimate(((Get-Reg "$DESK\WindowMetrics" 'MinAnimate' '1') -ne '0')) } catch {}
    try { [void][W11C.Native]::SPISetStr(0x14, 0, [string](Get-Reg $DESK 'Wallpaper' ''), 3) } catch {}
    Send-SettingChange
}

function Restart-Explorer {
    try {
        Get-Process explorer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 1500
        if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
        $ui.RestartBanner.Visibility = 'Collapsed'
        Show-Toast 'Explorer neu gestartet - alles übernommen'
    } catch { Show-Toast ("Explorer-Neustart fehlgeschlagen: " + $_.Exception.Message) -IsError }
}

# =====================================================================
#  Einstellungs-Definitionen
# =====================================================================
function T($title, $desc, $icon, $path, $name, $on, $off, $default, [switch]$Restart) {
    @{ Title = $title; Desc = $desc; Icon = $icon; Path = $path; Name = $name; On = $on; Off = $off; Default = $default; Restart = [bool]$Restart }
}

# ---------- Farben ----------
$Defs = @{}
$Defs.AppsMode = @{ Title = 'App-Modus'; Desc = 'Hell oder dunkel für Apps wie Einstellungen, Explorer, Store.'; Icon = [string][char]0xE706
    Path = $PERS; Name = 'AppsUseLightTheme'; Default = 1; Options = @(@('Dunkel', 0), @('Hell', 1)) }
$Defs.SysMode  = @{ Title = 'Windows-Modus'; Desc = 'Hell oder dunkel für Taskleiste, Startmenü und Info-Center.'; Icon = [string][char]0xE7F4
    Path = $PERS; Name = 'SystemUsesLightTheme'; Default = 0; Restart = $true; Options = @(@('Dunkel', 0), @('Hell', 1)) }
$Defs.Transparency = T 'Transparenz-Effekte' 'Milchglas-Effekt für Taskleiste, Startmenü und Fenster.' ([string][char]0xE890) $PERS 'EnableTransparency' 1 0 1
$Defs.AccentBar    = T 'Akzentfarbe auf Start & Taskleiste' 'Färbt Taskleiste und Startmenü in deiner Akzentfarbe (nur im dunklen Windows-Modus).' ([string][char]0xE790) $PERS 'ColorPrevalence' 1 0 0 -Restart
$Defs.AccentTitle  = T 'Akzentfarbe auf Titelleisten & Rahmen' 'Fensterrahmen und Titelleisten bekommen deine Akzentfarbe.' ([string][char]0xE737) $DWM 'ColorPrevalence' 1 0 0
$Defs.AutoAccent   = T 'Akzentfarbe automatisch vom Hintergrund' 'Windows wählt die Farbe passend zum Hintergrundbild.' ([string][char]0xE8B9) $DESK 'AutoColorization' 1 0 0

# ---------- Taskleiste ----------
$Defs.TbAlign  = @{ Title = 'Ausrichtung'; Desc = 'Symbole in der Mitte (Windows 11) oder links wie bei Windows 10.'; Icon = [string][char]0xE7F4
    Path = $ADV; Name = 'TaskbarAl'; Default = 1; Options = @(@('Links', 0), @('Mitte', 1)) }
$Defs.TbSearch = @{ Title = 'Suche in der Taskleiste'; Desc = 'Ausblenden, nur Lupe, Suchfeld oder Lupe mit Text.'; Icon = [string][char]0xE721
    Path = $SRCH; Name = 'SearchboxTaskbarMode'; Default = 2; Options = @(@('Aus', 0), @('Symbol', 1), @('Feld', 2), @('Symbol + Text', 3)) }
$Defs.TbGlom   = @{ Title = 'Fenster gruppieren'; Desc = 'Wie Fenster derselben App in der Taskleiste zusammengefasst werden.'; Icon = [string][char]0xE8A9
    Path = $ADV; Name = 'TaskbarGlomLevel'; Default = 0; Restart = $true; Options = @(@('Immer', 0), @('Wenn voll', 1), @('Nie', 2)) }
$Defs.TbTaskView = T 'Taskansicht-Button' 'Button für virtuelle Desktops und Fensterübersicht.' ([string][char]0xE7C4) $ADV 'ShowTaskViewButton' 1 0 1
$Defs.TbWidgets  = T 'Widgets-Button' 'Wetter/News-Widgets links in der Taskleiste.' ([string][char]0xE71D) $ADV 'TaskbarDa' 1 0 1
$Defs.TbAutoHide = @{ Title = 'Taskleiste automatisch ausblenden'; Desc = 'Taskleiste erscheint erst, wenn die Maus unten an den Rand geht.'; Icon = [string][char]0xE740; Restart = $true
    Get = { $b = Get-Reg 'Software\Microsoft\Windows\CurrentVersion\Explorer\StuckRects3' 'Settings' $null
            if ($b -and $b.Length -gt 8) { return (([int]$b[8] -band 1) -eq 1) }; return $false }
    Set = { param($on)
            $p = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StuckRects3'
            $b = Get-Reg $p 'Settings' $null
            if (-not $b -or $b.Length -le 8) { throw 'Taskleisten-Einstellung nicht gefunden.' }
            $nb = [byte[]]$b.Clone()
            if ($on) { $nb[8] = [byte]([int]$nb[8] -bor 1) } else { $nb[8] = [byte]([int]$nb[8] -band 254) }
            Set-Reg $p 'Settings' $nb 'Binary' } }
$Defs.TbSeconds  = T 'Sekunden in der Uhr' 'Zeigt die Uhrzeit unten rechts mit Sekunden an.' ([string][char]0xE823) $ADV 'ShowSecondsInSystemClock' 1 0 0 -Restart
$Defs.TbEndTask  = T '"Task beenden" im Rechtsklick' 'Hängende Apps direkt per Rechtsklick in der Taskleiste beenden.' ([string][char]0xE711) "$ADV\TaskbarDeveloperSettings" 'TaskbarEndTask' 1 0 0
$Defs.TbMulti    = T 'Taskleiste auf allen Bildschirmen' 'Bei mehreren Monitoren auf jedem eine Taskleiste.' ([string][char]0xE7F4) $ADV 'MMTaskbarEnabled' 1 0 1
$Defs.TbBadges   = T 'Zähler auf App-Symbolen' 'Kleine Zahlen für ungelesene Nachrichten (z. B. Mail, Discord).' ([string][char]0xE8BD) $ADV 'TaskbarBadges' 1 0 1
$Defs.TbDesktop  = T '"Desktop anzeigen" ganz rechts' 'Klick in die rechte Ecke der Taskleiste minimiert alle Fenster.' ([string][char]0xE7F8) $ADV 'TaskbarSd' 1 0 1

# ---------- Startmenü ----------
$Defs.StLayout = @{ Title = 'Startmenü-Layout'; Desc = 'Mehr Platz für angeheftete Apps oder für Empfehlungen.'; Icon = [string][char]0xE71D
    Path = $ADV; Name = 'Start_Layout'; Default = 0; Options = @(@('Standard', 0), @('Mehr Pins', 1), @('Mehr Empfehlungen', 2)) }
$Defs.StDocs  = T 'Zuletzt geöffnete Dateien' 'Zeigt zuletzt geöffnete Dateien im Start, in Sprunglisten und im Explorer.' ([string][char]0xE8A5) $ADV 'Start_TrackDocs' 1 0 1
$Defs.StProgs = T 'Meistverwendete Apps' 'Zeigt deine meistgenutzten Apps im Startmenü.' ([string][char]0xE8FD) $ADV 'Start_TrackProgs' 1 0 1
$Defs.StIris  = T 'Tipps & App-Werbung im Start' 'Empfehlungen für Tipps, Verknüpfungen und neue Apps.' ([string][char]0xE789) $ADV 'Start_IrisRecommendations' 1 0 1
$Defs.StAcct  = T 'Konto-Hinweise im Start' 'Hinweise zum Microsoft-Konto am Profilbild.' ([string][char]0xE77B) $ADV 'Start_AccountNotifications' 1 0 1
$Defs.StBing  = @{ Title = 'Websuche (Bing) im Startmenü'; Desc = 'Aus = Suche zeigt nur deine Apps, Dateien und Einstellungen.'; Icon = [string][char]0xE774; Restart = $true
    Get = { (Get-Reg $SRCH 'BingSearchEnabled' 1) -ne 0 }
    Set = { param($on)
            $v = 0; if ($on) { $v = 1 }
            Set-Reg $SRCH 'BingSearchEnabled' $v
            Set-Reg $SRCH 'CortanaConsent' $v
            try { Set-Reg 'Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' (1 - $v) } catch {} } }
$Defs.StHighlights = T 'Suchhighlights' 'Bunte Tagesthemen und Bilder im Suchfeld.' ([string][char]0xE721) 'Software\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsDynamicSearchBoxEnabled' 1 0 1

# ---------- Explorer ----------
$Defs.ExClassic = @{ Title = 'Klassisches Rechtsklick-Menü'; Desc = 'Volles Windows-10-Kontextmenü ohne "Weitere Optionen anzeigen".'; Icon = [string][char]0xE8C4; Restart = $true
    Get = { $k = $HK.OpenSubKey($CLASSIC); if ($k) { $k.Close(); return $true }; return $false }
    Set = { param($on)
            if ($on) { Set-Reg $CLASSIC '' '' 'String' }
            else {
                Remember-Original $CLASSIC ''
                try { $HK.DeleteSubKeyTree($CLASSIC_ROOT, $false) } catch {}
            } } }
$Defs.ExExt     = T 'Dateiendungen anzeigen' 'Zeigt .exe, .jpg, .pdf usw. hinter dem Dateinamen.' ([string][char]0xE8A5) $ADV 'HideFileExt' 0 1 1
$Defs.ExHidden  = T 'Versteckte Dateien anzeigen' 'Zeigt versteckte Ordner wie AppData.' ([string][char]0xE890) $ADV 'Hidden' 1 2 2
$Defs.ExSuper   = T 'Geschützte Systemdateien anzeigen' 'Nur für Profis - diese Dateien nicht löschen!' ([string][char]0xE7BA) $ADV 'ShowSuperHidden' 1 0 0
$Defs.ExLaunch  = @{ Title = 'Explorer öffnet mit'; Desc = 'Welche Seite beim Öffnen des Explorers zuerst kommt.'; Icon = [string][char]0xE8B7
    Path = $ADV; Name = 'LaunchTo'; Default = 2; Options = @(@('Start', 2), @('Dieser PC', 1), @('Downloads', 3)) }
$Defs.ExCompact = T 'Kompakte Ansicht' 'Weniger Abstand zwischen Dateien - mehr passt auf den Bildschirm.' ([string][char]0xE8FD) $ADV 'UseCompactMode' 1 0 0
$Defs.ExCheck   = T 'Kontrollkästchen zum Auswählen' 'Häkchen an Dateien zum einfachen Mehrfach-Auswählen.' ([string][char]0xE73E) $ADV 'AutoCheckSelect' 1 0 0
$Defs.ExPath    = T 'Vollständiger Pfad in der Titelleiste' 'Zeigt z. B. C:\Users\...\Bilder statt nur "Bilder".' ([string][char]0xE8B7) 'Software\Microsoft\Windows\CurrentVersion\Explorer\CabinetState' 'FullPath' 1 0 0
$Defs.ExRecent  = T 'Zuletzt verwendete Dateien in "Start"' 'Liste der zuletzt benutzten Dateien auf der Explorer-Startseite.' ([string][char]0xE81C) 'Software\Microsoft\Windows\CurrentVersion\Explorer' 'ShowRecent' 1 0 1
$Defs.ExFreq    = T 'Häufig verwendete Ordner' 'Häufig benutzte Ordner im Schnellzugriff.' ([string][char]0xE8B7) 'Software\Microsoft\Windows\CurrentVersion\Explorer' 'ShowFrequent' 1 0 1

# ---------- Desktop ----------
$Defs.DkIcons   = T 'Desktop-Symbole anzeigen' 'Alle Symbole auf dem Desktop ein- oder ausblenden (cleaner Look).' ([string][char]0xE7F8) $ADV 'HideIcons' 0 1 0 -Restart
$Defs.DkPC      = T 'Dieser PC' 'Symbol "Dieser PC" auf dem Desktop.' ([string][char]0xE7F8) $ICONS '{20D04FE0-3AEA-1069-A2D8-08002B30309D}' 0 1 1 -Restart
$Defs.DkBin     = T 'Papierkorb' 'Symbol "Papierkorb" auf dem Desktop.' ([string][char]0xE74D) $ICONS '{645FF040-5081-101B-9F08-00AA002F954E}' 0 1 0 -Restart
$Defs.DkUser    = T 'Benutzerordner' 'Dein persönlicher Ordner auf dem Desktop.' ([string][char]0xE77B) $ICONS '{59031a47-3f72-44a7-89c5-5595fe6b30ee}' 0 1 1 -Restart
$Defs.DkNet     = T 'Netzwerk' 'Symbol "Netzwerk" auf dem Desktop.' ([string][char]0xE774) $ICONS '{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}' 0 1 1 -Restart
$Defs.DkCP      = T 'Systemsteuerung' 'Die klassische Systemsteuerung auf dem Desktop.' ([string][char]0xE713) $ICONS '{5399E694-6CE5-4D6C-8FCE-1D8870FDCBA0}' 0 1 1 -Restart
$Defs.DkStyle   = @{ Title = 'Bildanpassung'; Desc = 'Wie das Hintergrundbild auf den Bildschirm passt.'; Icon = [string][char]0xE740
    Path = $DESK; Name = 'WallpaperStyle'; Default = '10'; Options = @(@('Füllen', '10'), @('Anpassen', '6'), @('Strecken', '2'), @('Zentriert', '0'), @('Spannen', '22'))
    Set = { param($v)
            Set-Reg $DESK 'WallpaperStyle' ([string]$v) 'String'
            Set-Reg $DESK 'TileWallpaper' '0' 'String'
            $wp = [string](Get-Reg $DESK 'Wallpaper' '')
            if ($wp) { Set-Wallpaper $wp $null } } }

# ---------- Effekte & Maus ----------
$Defs.FxAnim = @{ Title = 'Animationen'; Desc = 'Fenster- und Menü-Animationen. Aus = alles fühlt sich schneller an.'; Icon = [string][char]0xE945
    Get = { [W11C.Native]::GetBool(0x1042) }
    Set = { param($on)
            Remember-SPI 'ClientAnimation' 0x1042 0x1043
            [void][W11C.Native]::SetBool(0x1043, [bool]$on)
            $v = '0'; if ($on) { $v = '1' }
            Set-Reg "$DESK\WindowMetrics" 'MinAnimate' $v 'String'
            [void][W11C.Native]::SetMinAnimate([bool]$on) } }
$Defs.FxMenu = @{ Title = 'Menü-Geschwindigkeit'; Desc = 'Wie schnell Untermenüs aufklappen.'; Icon = [string][char]0xE916
    Path = $DESK; Name = 'MenuShowDelay'; Kind = 'String'; Default = '400'; Options = @(@('Normal', '400'), @('Schnell', '150'), @('Sofort', '0'))
    Set = { param($v)
            Set-Reg $DESK 'MenuShowDelay' ([string]$v) 'String'
            [void][W11C.Native]::SPISetPtr(0x6B, [uint32]$v, [IntPtr]::Zero, 3) } }
$Defs.FxSnap  = T 'Snap-Layouts beim Maximieren-Button' 'Layout-Vorschläge, wenn du über den Maximieren-Button fährst.' ([string][char]0xE8A9) $ADV 'EnableSnapAssistFlyout' 1 0 1
$Defs.FxShake = @{ Title = 'Fenster schütteln = andere minimieren'; Desc = 'Fenster an der Titelleiste schütteln minimiert alle anderen.'; Icon = [string][char]0xE7C4
    Get = { (Get-Reg $ADV 'DisallowShaking' 1) -eq 0 }
    Set = { param($on) $v = 1; if ($on) { $v = 0 }; Set-Reg $ADV 'DisallowShaking' $v } }
$Defs.FxShadow = @{ Title = 'Mauszeiger-Schatten'; Desc = 'Kleiner Schatten unter dem Mauszeiger.'; Icon = [string][char]0xE962
    Get = { [W11C.Native]::GetBool(0x101A) }
    Set = { param($on) Remember-SPI 'CursorShadow' 0x101A 0x101B; [void][W11C.Native]::SetBool(0x101B, [bool]$on) } }
$Defs.FxAccel = @{ Title = 'Mausbeschleunigung'; Desc = 'Aus = 1:1-Bewegung, beliebt beim Zocken (bessere Zielgenauigkeit).'; Icon = [string][char]0xE962
    Get = { [string](Get-Reg 'Control Panel\Mouse' 'MouseSpeed' '1') -ne '0' }
    Set = { param($on)
            if ($on) { $s = 1; $t1 = 6; $t2 = 10 } else { $s = 0; $t1 = 0; $t2 = 0 }
            Set-Reg 'Control Panel\Mouse' 'MouseSpeed' "$s" 'String'
            Set-Reg 'Control Panel\Mouse' 'MouseThreshold1' "$t1" 'String'
            Set-Reg 'Control Panel\Mouse' 'MouseThreshold2' "$t2" 'String'
            [void][W11C.Native]::SetMouse($t1, $t2, $s) } }
$Defs.FxCursor = @{ Title = 'Mauszeiger-Größe'; Desc = 'Windows-11-Zeiger in normal, groß oder extra groß.'; Icon = [string][char]0xE962
    Options = @(@('Normal', 0), @('Groß', 1), @('Extra groß', 2))
    Get = { $a = [string](Get-Reg 'Control Panel\Cursors' 'Arrow' ''); if ($a -match '_xl\.') { 2 } elseif ($a -match '_l\.') { 1 } else { 0 } }
    Set = { param($v) Set-CursorSize ([int]$v) } }
$Defs.FxSounds = @{ Title = 'Windows-Systemsounds'; Desc = 'Alle Klick-, Hinweis- und Fehlersounds von Windows.'; Icon = [string][char]0xE767
    Get = { [string](Get-Reg 'AppEvents\Schemes' '' '.Default') -ne '.None' }
    Set = { param($on) Set-SystemSounds ([bool]$on) } }

# ---------- Werbung ----------
function M($title, $desc, $icon, [string[]]$multi, $default = 1) {
    @{ Title = $title; Desc = $desc; Icon = $icon; Multi = $multi; On = 1; Off = 0; Default = $default }
}
$Defs.AdTips    = M 'Tipps & Vorschläge als Benachrichtigung' '"Hol das Beste aus Windows raus"-Popups.' ([string][char]0xEA8F) @("$CDM|SubscribedContent-338389Enabled", "$CDM|SoftLandingEnabled")
$Defs.AdSettings = M 'Vorschläge in den Einstellungen' 'Empfohlene Inhalte und Werbung in der Einstellungen-App.' ([string][char]0xE713) @("$CDM|SubscribedContent-338393Enabled", "$CDM|SubscribedContent-353694Enabled", "$CDM|SubscribedContent-353696Enabled")
$Defs.AdLock    = M 'Fun Facts auf dem Sperrbildschirm' 'Tipps, Witze und Werbung auf dem Sperrbildschirm.' ([string][char]0xE72E) @("$CDM|RotatingLockScreenOverlayEnabled", "$CDM|SubscribedContent-338387Enabled")
$Defs.AdWelcome = M 'Willkommens-Seite nach Updates' '"Lass uns die Einrichtung abschließen"-Bildschirm.' ([string][char]0xE777) @("$CDM|SubscribedContent-310093Enabled", 'Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement|ScoobeSystemSettingEnabled')
$Defs.AdApps    = M 'Apps automatisch installieren' 'Verhindert, dass Windows Spiele & Werbe-Apps von selbst installiert.' ([string][char]0xE7B8) @("$CDM|SilentInstalledAppsEnabled", "$CDM|PreInstalledAppsEnabled", "$CDM|OemPreInstalledAppsEnabled")
$Defs.AdSync    = T 'OneDrive-/Microsoft-365-Werbung im Explorer' 'Werbebanner oben im Datei-Explorer.' ([string][char]0xE753) $ADV 'ShowSyncProviderNotifications' 1 0 1
$Defs.AdId      = T 'Personalisierte Werbung (Werbe-ID)' 'Apps dürfen dir per Werbe-ID passende Werbung zeigen.' ([string][char]0xE72E) 'Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 1 0 1
$Defs.AdTailored = T 'Maßgeschneiderte Erlebnisse' 'Microsoft nutzt Diagnosedaten für Tipps und Angebote.' ([string][char]0xE9D9) 'Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 1 0 1
$AdDefs = @($Defs.AdTips, $Defs.AdSettings, $Defs.AdLock, $Defs.AdWelcome, $Defs.AdApps, $Defs.AdSync, $Defs.AdId, $Defs.AdTailored, $Defs.StIris, $Defs.StAcct, $Defs.StHighlights)

# ---------- Themes ----------
$Presets = @(
    @{ Name = 'Midnight Purple'; Accent = '#8B5CF6'; Light = 0; Colors = @('#0B0A1F', '#2A1B5C', '#5B2A86'); Glow = '#A78BFA'; TbAccent = 0; TitleAccent = 1 },
    @{ Name = 'Ocean Deep';      Accent = '#0EA5E9'; Light = 0; Colors = @('#04111F', '#0A3D62', '#0E7490'); Glow = '#38BDF8'; TbAccent = 0; TitleAccent = 1 },
    @{ Name = 'Neon Gaming';     Accent = '#00E676'; Light = 0; Colors = @('#030806', '#062A17', '#0B3D2A'); Glow = '#00FF95'; TbAccent = 0; TitleAccent = 1 },
    @{ Name = 'Sunset Drive';    Accent = '#F97316'; Light = 0; Colors = @('#1A0B2E', '#7A1F5C', '#F2643A'); Glow = '#FDBA74'; TbAccent = 0; TitleAccent = 1 },
    @{ Name = 'Blood Moon';      Accent = '#E11D48'; Light = 0; Colors = @('#050000', '#2B0509', '#6B0F1A'); Glow = '#FB7185'; TbAccent = 1; TitleAccent = 1 },
    @{ Name = 'Cyber Teal';      Accent = '#14B8A6'; Light = 0; Colors = @('#020617', '#0F172A', '#134E4A'); Glow = '#2DD4BF'; TbAccent = 0; TitleAccent = 1 },
    @{ Name = 'Gold Rush';       Accent = '#EAB308'; Light = 0; Colors = @('#0C0A05', '#2A2109', '#4A3A0B'); Glow = '#FDE047'; TbAccent = 0; TitleAccent = 0 },
    @{ Name = 'Mono Black';      Accent = '#A1A1AA'; Light = 0; Colors = @('#000000', '#0A0A0A', '#18181B'); Glow = '#52525B'; TbAccent = 0; TitleAccent = 0 },
    @{ Name = 'Arctic Light';    Accent = '#2563EB'; Light = 1; Colors = @('#F8FAFC', '#DBEAFE', '#BFDBFE'); Glow = '#FFFFFF'; TbAccent = 0; TitleAccent = 0 },
    @{ Name = 'Rose Quartz';     Accent = '#DB2777'; Light = 1; Colors = @('#FFF1F2', '#FBCFE8', '#E9D5FF'); Glow = '#FFFFFF'; TbAccent = 0; TitleAccent = 0 }
)

$Swatches = @('#FFB900', '#FF8C00', '#F7630C', '#E81123', '#E11D48', '#EA005E', '#E3008C', '#BF0077',
              '#9A0089', '#881798', '#744DA9', '#8B5CF6', '#0063B1', '#0078D4', '#0EA5E9', '#0099BC',
              '#00B7C3', '#14B8A6', '#00B294', '#00CC6A', '#00E676', '#10893E', '#A3E635', '#EAB308',
              '#7A7574', '#5D5A58', '#A1A1AA', '#F43F5E')

# =====================================================================
#  Oberfläche (XAML)
# =====================================================================
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Win11 Customizer" Width="1200" Height="800" MinWidth="1000" MinHeight="640"
        WindowStartupLocation="CenterScreen" Background="#0E0F14" Foreground="#F2F3F7"
        FontFamily="Segoe UI Variable Text, Segoe UI" UseLayoutRounding="True">
  <WindowChrome.WindowChrome>
    <WindowChrome CaptionHeight="44" ResizeBorderThickness="6" GlassFrameThickness="0" CornerRadius="0" UseAeroCaptionButtons="False"/>
  </WindowChrome.WindowChrome>
  <Window.Resources>
    <SolidColorBrush x:Key="Accent" Color="#8B5CF6"/>
    <SolidColorBrush x:Key="AccentSoft" Color="#268B5CF6"/>
    <LinearGradientBrush x:Key="HeroBrush" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#8B5CF6" Offset="0"/><GradientStop Color="#1A1C25" Offset="1"/>
    </LinearGradientBrush>
    <SolidColorBrush x:Key="Muted" Color="#9AA0B4"/>

    <Style x:Key="H1" TargetType="TextBlock">
      <Setter Property="FontSize" Value="28"/><Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="FontFamily" Value="Segoe UI Variable Display, Segoe UI"/>
      <Setter Property="Margin" Value="0,8,0,4"/>
    </Style>
    <Style x:Key="Sub" TargetType="TextBlock">
      <Setter Property="FontSize" Value="14"/><Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="Margin" Value="0,0,0,18"/><Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="Section" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12"/><Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Foreground" Value="{StaticResource Muted}"/><Setter Property="Margin" Value="4,20,0,10"/>
    </Style>
    <Style x:Key="RowTitle" TargetType="TextBlock">
      <Setter Property="FontSize" Value="14"/><Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="RowDesc" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12.5"/><Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="TextWrapping" Value="Wrap"/><Setter Property="Margin" Value="0,2,0,0"/>
    </Style>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#181A22"/><Setter Property="BorderBrush" Value="#252836"/>
      <Setter Property="BorderThickness" Value="1"/><Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="16,12"/><Setter Property="Margin" Value="0,0,0,8"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#1E2029"/><Setter Property="BorderBrush" Value="#33374A"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="CardStatic" TargetType="Border">
      <Setter Property="Background" Value="#181A22"/><Setter Property="BorderBrush" Value="#252836"/>
      <Setter Property="BorderThickness" Value="1"/><Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="18,16"/>
    </Style>
    <Style x:Key="Chip" TargetType="Border">
      <Setter Property="Background" Value="#2EFFFFFF"/><Setter Property="CornerRadius" Value="8"/>
      <Setter Property="Padding" Value="12,6"/>
    </Style>

    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Background" Value="#262A37"/><Setter Property="Foreground" Value="#F2F3F7"/>
      <Setter Property="FontSize" Value="13"/><Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="16,8"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Border Background="{TemplateBinding Background}" CornerRadius="8"/>
              <Border x:Name="Ov" Background="White" Opacity="0" CornerRadius="8"/>
              <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Ov" Property="Opacity" Value="0.09"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="Ov" Property="Opacity" Value="0.18"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="BtnAccent" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="{DynamicResource Accent}"/><Setter Property="Foreground" Value="White"/>
    </Style>
    <Style x:Key="BtnLight" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="White"/><Setter Property="Foreground" Value="#111318"/>
    </Style>
    <Style x:Key="BtnGlass" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#33FFFFFF"/><Setter Property="Foreground" Value="White"/>
    </Style>
    <Style x:Key="BtnDanger" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#C42B1C"/><Setter Property="Foreground" Value="White"/>
    </Style>

    <Style x:Key="Cap" TargetType="Button">
      <Setter Property="Width" Value="46"/><Setter Property="Height" Value="44"/>
      <Setter Property="Background" Value="Transparent"/><Setter Property="Foreground" Value="#C9CDD9"/>
      <Setter Property="FontFamily" Value="Segoe Fluent Icons, Segoe MDL2 Assets"/><Setter Property="FontSize" Value="10"/>
      <Setter Property="WindowChrome.IsHitTestVisibleInChrome" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="{TemplateBinding Background}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#262A37"/></Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="CapClose" TargetType="Button" BasedOn="{StaticResource Cap}">
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#E81123"/><Setter Property="Foreground" Value="White"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style x:Key="Nav" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#B8BDCC"/><Setter Property="FontSize" Value="14"/>
      <Setter Property="Margin" Value="0,2"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="GroupName" Value="nav"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="Bd" Background="Transparent" CornerRadius="8" Padding="14,10">
              <Grid>
                <Border x:Name="Pill" Width="3" Height="18" CornerRadius="2" Background="{DynamicResource Accent}"
                        HorizontalAlignment="Left" Margin="-12,0,0,0" Visibility="Collapsed"/>
                <StackPanel Orientation="Horizontal">
                  <TextBlock x:Name="Ico" Text="{Binding Tag, RelativeSource={RelativeSource TemplatedParent}}"
                             FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="16"
                             VerticalAlignment="Center" Margin="0,0,12,0"/>
                  <ContentPresenter VerticalAlignment="Center"/>
                </StackPanel>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#1C1F29"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#23262F"/>
                <Setter TargetName="Pill" Property="Visibility" Value="Visible"/>
                <Setter Property="Foreground" Value="White"/>
                <Setter TargetName="Ico" Property="Foreground" Value="{DynamicResource Accent}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Width="44" Height="22" Background="Transparent">
              <Border x:Name="Track" CornerRadius="11" Background="#2A2D3A" BorderBrush="#4A4F63" BorderThickness="1"/>
              <Ellipse x:Name="Knob" Width="14" Height="14" Fill="#C9CDD9" HorizontalAlignment="Left" Margin="4,0,0,0">
                <Ellipse.RenderTransform><TranslateTransform x:Name="Tx" X="0"/></Ellipse.RenderTransform>
              </Ellipse>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Trigger.EnterActions>
                  <BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="Tx" Storyboard.TargetProperty="X" To="22" Duration="0:0:0.14"/></Storyboard></BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="Tx" Storyboard.TargetProperty="X" To="0" Duration="0:0:0.14"/></Storyboard></BeginStoryboard>
                </Trigger.ExitActions>
                <Setter TargetName="Track" Property="Background" Value="{DynamicResource Accent}"/>
                <Setter TargetName="Track" Property="BorderBrush" Value="{DynamicResource Accent}"/>
                <Setter TargetName="Knob" Property="Fill" Value="White"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Track" Property="Opacity" Value="0.9"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Seg" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#C9CDD9"/><Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/><Setter Property="Margin" Value="6,0,0,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="Bd" CornerRadius="8" Padding="13,7" Background="#232633" BorderBrush="#303446" BorderThickness="1">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#2B2F3E"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource Accent}"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource Accent}"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="MetricChip" TargetType="CheckBox">
      <Setter Property="Foreground" Value="#C9CDD9"/><Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/><Setter Property="Margin" Value="6,3,0,3"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Border x:Name="Bd" CornerRadius="15" Padding="12,6" Background="#232633" BorderBrush="#303446" BorderThickness="1">
              <StackPanel Orientation="Horizontal">
                <TextBlock x:Name="Tick" Text="&#xE73E;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="11"
                           VerticalAlignment="Center" Margin="0,0,6,0" Visibility="Collapsed"/>
                <ContentPresenter VerticalAlignment="Center"/>
              </StackPanel>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#2B2F3E"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource AccentSoft}"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource Accent}"/>
                <Setter TargetName="Tick" Property="Visibility" Value="Visible"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Swatch" TargetType="Button">
      <Setter Property="Width" Value="36"/><Setter Property="Height" Value="36"/>
      <Setter Property="Margin" Value="0,0,8,8"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Ring" CornerRadius="18" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="2" Padding="3">
              <Border CornerRadius="14" Background="{TemplateBinding Background}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Ring" Property="Opacity" Value="0.8"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Input" TargetType="TextBox">
      <Setter Property="Background" Value="#232633"/><Setter Property="Foreground" Value="#F2F3F7"/>
      <Setter Property="BorderBrush" Value="#303446"/><Setter Property="CaretBrush" Value="White"/>
      <Setter Property="Padding" Value="8,6"/><Setter Property="FontSize" Value="13"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>

    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="10"/><Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Border Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True" Orientation="{TemplateBinding Orientation}">
                <Track.Thumb>
                  <Thumb>
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Border CornerRadius="4" Background="#3A3E4E" Margin="2,0"/>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid x:Name="Root">
    <Grid.ColumnDefinitions><ColumnDefinition Width="250"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
    <Grid.RowDefinitions><RowDefinition Height="44"/><RowDefinition Height="*"/></Grid.RowDefinitions>

    <Border Grid.RowSpan="2" Background="#12141B" BorderBrush="#20232E" BorderThickness="0,0,1,0"/>

    <!-- Titelleiste -->
    <StackPanel Orientation="Horizontal" Margin="18,0,0,0" VerticalAlignment="Center">
      <Border Width="24" Height="24" CornerRadius="7" Background="{DynamicResource Accent}">
        <TextBlock Text="&#xE771;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="12" Foreground="White"
                   HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
      <TextBlock Text="Win11 Customizer" FontWeight="SemiBold" FontSize="13" Margin="10,0,0,0" VerticalAlignment="Center"/>
    </StackPanel>
    <StackPanel Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top">
      <Button x:Name="BtnMin" Style="{StaticResource Cap}" Content="&#xE921;"/>
      <Button x:Name="BtnMax" Style="{StaticResource Cap}" Content="&#xE922;"/>
      <Button x:Name="BtnClose" Style="{StaticResource CapClose}" Content="&#xE8BB;"/>
    </StackPanel>

    <!-- Navigation -->
    <DockPanel Grid.Row="1" Margin="12,6,12,14">
      <Border DockPanel.Dock="Bottom" Background="#181A22" CornerRadius="12" Padding="12" BorderBrush="#252836" BorderThickness="1">
        <StackPanel>
          <Button x:Name="BtnRestartSide" Style="{StaticResource Btn}" HorizontalAlignment="Stretch">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="&#xE72C;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" VerticalAlignment="Center" Margin="0,0,8,0"/>
              <TextBlock Text="Explorer neu starten"/>
            </StackPanel>
          </Button>
          <TextBlock x:Name="TxtVersion" Text="v1.0" Foreground="{StaticResource Muted}" FontSize="11" Margin="0,10,0,0" HorizontalAlignment="Center"/>
        </StackPanel>
      </Border>
      <StackPanel>
        <TextBlock Text="MENÜ" FontSize="11" Foreground="{StaticResource Muted}" Margin="14,4,0,8" FontWeight="Bold"/>
        <RadioButton x:Name="NavHome"     Style="{StaticResource Nav}" Tag="&#xE80F;" Content="Start" IsChecked="True"/>
        <RadioButton x:Name="NavColors"   Style="{StaticResource Nav}" Tag="&#xE790;" Content="Farben &amp; Design"/>
        <RadioButton x:Name="NavTaskbar"  Style="{StaticResource Nav}" Tag="&#xE7F4;" Content="Taskleiste"/>
        <RadioButton x:Name="NavStart"    Style="{StaticResource Nav}" Tag="&#xE71D;" Content="Startmenü &amp; Suche"/>
        <RadioButton x:Name="NavExplorer" Style="{StaticResource Nav}" Tag="&#xE8B7;" Content="Explorer &amp; Desktop"/>
        <RadioButton x:Name="NavTiles"    Style="{StaticResource Nav}" Tag="&#xECA5;" Content="Desktop-Kacheln"/>
        <RadioButton x:Name="NavFx"       Style="{StaticResource Nav}" Tag="&#xE945;" Content="Effekte, Maus &amp; Sound"/>
        <RadioButton x:Name="NavAds"      Style="{StaticResource Nav}" Tag="&#xEA18;" Content="Werbung &amp; Tipps"/>
        <RadioButton x:Name="NavBackup"   Style="{StaticResource Nav}" Tag="&#xE777;" Content="Backup &amp; Profile"/>
      </StackPanel>
    </DockPanel>

    <!-- Inhalt -->
    <Grid Grid.Row="1" Grid.Column="1">
      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>

      <Border x:Name="RestartBanner" Visibility="Collapsed" Margin="32,4,32,6" CornerRadius="10"
              Background="{DynamicResource AccentSoft}" BorderBrush="{DynamicResource Accent}" BorderThickness="1" Padding="16,10">
        <DockPanel>
          <Button x:Name="BtnRestartBanner" DockPanel.Dock="Right" Style="{StaticResource BtnAccent}" Content="Jetzt neu starten" Margin="12,0,0,0"/>
          <TextBlock Text="&#xE946;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="16" VerticalAlignment="Center" Margin="0,0,10,0"/>
          <TextBlock VerticalAlignment="Center" TextWrapping="Wrap"
                     Text="Einige Änderungen werden erst nach einem Explorer-Neustart sichtbar (Taskleiste ist dabei kurz weg)."/>
        </DockPanel>
      </Border>

      <Grid Grid.Row="1">
        <!-- START -->
        <ScrollViewer x:Name="PageHome" VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="32,6,32,32">
            <Border CornerRadius="16" Padding="28,24" Background="{DynamicResource HeroBrush}" Margin="0,4,0,8">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <StackPanel>
                  <TextBlock Text="WIN11 CUSTOMIZER" FontSize="12" FontWeight="Bold" Foreground="#CCFFFFFF"/>
                  <TextBlock Text="Mach Windows 11 zu deinem Windows." FontSize="30" FontWeight="Bold" Foreground="White"
                             FontFamily="Segoe UI Variable Display, Segoe UI" Margin="0,6,0,6" TextWrapping="Wrap"/>
                  <TextBlock Foreground="#DDFFFFFF" FontSize="14" TextWrapping="Wrap" MaxWidth="600" HorizontalAlignment="Left"
                             Text="Themes mit einem Klick, Farben, Taskleiste, Startmenü, Explorer und Effekte - alles an einem Ort. Jeder Originalwert wird automatisch gesichert."/>
                  <WrapPanel Margin="0,18,0,0">
                    <Button x:Name="BtnRandom" Style="{StaticResource BtnLight}" Margin="0,0,10,0">
                      <StackPanel Orientation="Horizontal">
                        <TextBlock Text="&#xE8B1;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" VerticalAlignment="Center" Margin="0,0,8,0"/>
                        <TextBlock Text="Zufälliges Theme"/>
                      </StackPanel>
                    </Button>
                    <Button x:Name="BtnGoColors" Style="{StaticResource BtnGlass}" Content="Eigene Farben"/>
                  </WrapPanel>
                </StackPanel>
                <StackPanel Grid.Column="1" VerticalAlignment="Top" Margin="20,0,0,0">
                  <Border Style="{StaticResource Chip}">
                    <StackPanel Orientation="Horizontal">
                      <TextBlock Text="Modus" Foreground="#CCFFFFFF"/>
                      <TextBlock x:Name="TxtMode" Margin="8,0,0,0" FontWeight="SemiBold" Foreground="White"/>
                    </StackPanel>
                  </Border>
                  <Border Style="{StaticResource Chip}" Margin="0,8,0,0">
                    <StackPanel Orientation="Horizontal">
                      <TextBlock Text="Akzent" Foreground="#CCFFFFFF"/>
                      <Ellipse Width="10" Height="10" Fill="{DynamicResource Accent}" Margin="8,0,0,0" VerticalAlignment="Center" Stroke="White" StrokeThickness="1"/>
                      <TextBlock x:Name="TxtAccent" Margin="6,0,0,0" FontWeight="SemiBold" Foreground="White"/>
                    </StackPanel>
                  </Border>
                  <Border Style="{StaticResource Chip}" Margin="0,8,0,0">
                    <StackPanel Orientation="Horizontal">
                      <TextBlock Text="Build" Foreground="#CCFFFFFF"/>
                      <TextBlock x:Name="TxtBuild" Margin="8,0,0,0" FontWeight="SemiBold" Foreground="White"/>
                    </StackPanel>
                  </Border>
                </StackPanel>
              </Grid>
            </Border>
            <TextBlock Text="THEMES MIT EINEM KLICK" Style="{StaticResource Section}"/>
            <TextBlock Style="{StaticResource RowDesc}" Margin="4,-6,0,12"
                       Text="Setzt Akzentfarbe, Hell/Dunkel, Transparenz und ein eigens erzeugtes 4K-Hintergrundbild - danach startet der Explorer kurz neu."/>
            <WrapPanel x:Name="PresetPanel"/>
            <TextBlock Text="BELIEBTE TWEAKS" Style="{StaticResource Section}"/>
            <StackPanel x:Name="ListHome"/>
          </StackPanel>
        </ScrollViewer>

        <!-- FARBEN -->
        <ScrollViewer x:Name="PageColors" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="32,6,32,32">
            <TextBlock Text="Farben &amp; Design" Style="{StaticResource H1}"/>
            <TextBlock Text="Akzentfarbe, Hell/Dunkel und Transparenz - mit Live-Vorschau." Style="{StaticResource Sub}"/>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="16"/><ColumnDefinition Width="320"/></Grid.ColumnDefinitions>
              <Border Style="{StaticResource CardStatic}">
                <StackPanel>
                  <TextBlock Text="Akzentfarbe" Style="{StaticResource RowTitle}"/>
                  <TextBlock Text="Für Startmenü, Buttons, Links, Auswahl - und diese App." Style="{StaticResource RowDesc}" Margin="0,2,0,14"/>
                  <WrapPanel x:Name="SwatchPanel"/>
                  <WrapPanel Margin="0,8,0,0">
                    <Border Width="36" Height="36" CornerRadius="8" Background="{DynamicResource Accent}" Margin="0,0,10,8"/>
                    <TextBox x:Name="HexBox" Width="110" Height="36" Style="{StaticResource Input}" Text="#8B5CF6" Margin="0,0,8,8"/>
                    <Button x:Name="BtnHexApply" Content="Übernehmen" Style="{StaticResource Btn}" Margin="0,0,8,8"/>
                    <Button x:Name="BtnPickColor" Content="Farbe wählen..." Style="{StaticResource BtnAccent}" Margin="0,0,8,8"/>
                  </WrapPanel>
                </StackPanel>
              </Border>
              <Border Grid.Column="2" Style="{StaticResource CardStatic}" Padding="14">
                <StackPanel>
                  <TextBlock Text="Live-Vorschau" Style="{StaticResource RowTitle}" Margin="2,0,0,10"/>
                  <Border x:Name="PvDesktop" Height="200" CornerRadius="10" ClipToBounds="True">
                    <Grid>
                      <Border x:Name="PvWindow" Width="210" Height="118" CornerRadius="6" HorizontalAlignment="Center"
                              VerticalAlignment="Top" Margin="0,18,0,0" BorderThickness="1">
                        <DockPanel>
                          <Border x:Name="PvTitle" DockPanel.Dock="Top" Height="20" CornerRadius="6,6,0,0">
                            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,8,0">
                              <Ellipse Width="6" Height="6" Fill="#99FFFFFF" Margin="3,0"/>
                              <Ellipse Width="6" Height="6" Fill="#99FFFFFF" Margin="3,0"/>
                              <Ellipse Width="6" Height="6" Fill="#99FFFFFF" Margin="3,0"/>
                            </StackPanel>
                          </Border>
                          <Border x:Name="PvBody" CornerRadius="0,0,6,6">
                            <StackPanel Margin="12,10">
                              <Border x:Name="PvLine1" Height="7" Width="130" CornerRadius="3" HorizontalAlignment="Left"/>
                              <Border x:Name="PvLine2" Height="7" Width="90" CornerRadius="3" HorizontalAlignment="Left" Margin="0,7,0,0"/>
                              <Border Height="20" Width="70" CornerRadius="5" Background="{DynamicResource Accent}" HorizontalAlignment="Left" Margin="0,14,0,0"/>
                            </StackPanel>
                          </Border>
                        </DockPanel>
                      </Border>
                      <Border x:Name="PvTaskbar" Height="28" VerticalAlignment="Bottom">
                        <StackPanel x:Name="PvIcons" Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="10,0">
                          <Border Width="13" Height="13" CornerRadius="3" Background="{DynamicResource Accent}" Margin="3,0"/>
                          <Border Width="13" Height="13" CornerRadius="3" Background="#8890A0" Margin="3,0"/>
                          <Border Width="13" Height="13" CornerRadius="3" Background="#8890A0" Margin="3,0"/>
                          <Border Width="13" Height="13" CornerRadius="3" Background="#8890A0" Margin="3,0"/>
                          <Border Width="13" Height="13" CornerRadius="3" Background="#8890A0" Margin="3,0"/>
                        </StackPanel>
                      </Border>
                    </Grid>
                  </Border>
                </StackPanel>
              </Border>
            </Grid>
            <StackPanel x:Name="ListColors"/>
          </StackPanel>
        </ScrollViewer>

        <ScrollViewer x:Name="PageTaskbar" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="32,6,32,32">
            <TextBlock Text="Taskleiste" Style="{StaticResource H1}"/>
            <TextBlock Text="Position, Buttons, Uhr und Verhalten der Taskleiste." Style="{StaticResource Sub}"/>
            <StackPanel x:Name="ListTaskbar"/>
          </StackPanel>
        </ScrollViewer>

        <ScrollViewer x:Name="PageStart" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="32,6,32,32">
            <TextBlock Text="Startmenü &amp; Suche" Style="{StaticResource H1}"/>
            <TextBlock Text="Layout, Empfehlungen und Websuche im Startmenü." Style="{StaticResource Sub}"/>
            <StackPanel x:Name="ListStart"/>
          </StackPanel>
        </ScrollViewer>

        <ScrollViewer x:Name="PageExplorer" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="32,6,32,32">
            <TextBlock Text="Explorer &amp; Desktop" Style="{StaticResource H1}"/>
            <TextBlock Text="Rechtsklick-Menü, Dateiansicht, Desktop-Symbole und Hintergrundbild." Style="{StaticResource Sub}"/>
            <StackPanel x:Name="ListExplorer"/>
          </StackPanel>
        </ScrollViewer>

        <ScrollViewer x:Name="PageTiles" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="32,6,32,32">
            <TextBlock Text="Desktop-Kacheln" Style="{StaticResource H1}"/>
            <TextBlock Style="{StaticResource Sub}"
                       Text="Live-Widgets direkt auf deinem Desktop - im Mac-Look oder klassisch. Auf dem Desktop: Klick öffnet, Ziehen verschiebt (rastet ein), Rechtsklick zeigt das Menü."/>
            <StackPanel x:Name="ListTiles"/>
            <TextBlock Text="NEUE KACHEL" Style="{StaticResource Section}"/>
            <Border Style="{StaticResource CardStatic}">
              <StackPanel>
                <TextBlock Text="Typ" Style="{StaticResource RowTitle}"/>
                <WrapPanel x:Name="TileTypePanel" Margin="-6,8,0,0"/>
                <TextBlock x:Name="TileHint" Style="{StaticResource RowDesc}" Margin="0,8,0,14"/>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="220"/><ColumnDefinition Width="16"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <StackPanel>
                    <TextBlock Text="Name (optional)" Style="{StaticResource RowDesc}" Margin="0,0,0,4"/>
                    <TextBox x:Name="TileName" Style="{StaticResource Input}" Height="36"/>
                  </StackPanel>
                  <StackPanel Grid.Column="2" x:Name="TileTargetRow">
                    <TextBlock x:Name="TileTargetLabel" Text="Ziel" Style="{StaticResource RowDesc}" Margin="0,0,0,4"/>
                    <DockPanel>
                      <Button x:Name="BtnTileBrowse" DockPanel.Dock="Right" Style="{StaticResource Btn}" Content="Durchsuchen ..." Margin="8,0,0,0"/>
                      <TextBox x:Name="TileTarget" Style="{StaticResource Input}" Height="36"/>
                    </DockPanel>
                  </StackPanel>
                  <StackPanel Grid.Column="2" x:Name="TileActionRow" Visibility="Collapsed">
                    <TextBlock Text="Aktion" Style="{StaticResource RowDesc}" Margin="0,0,0,4"/>
                    <WrapPanel x:Name="TileActionPanel" Margin="-6,0,0,0"/>
                  </StackPanel>
                </Grid>
                <StackPanel x:Name="TileMetricsRow" Visibility="Collapsed" Margin="0,14,0,0">
                  <TextBlock Text="Was soll angezeigt werden? (Reihenfolge = Reihenfolge deiner Klicks)" Style="{StaticResource RowDesc}" Margin="0,0,0,4"/>
                  <WrapPanel x:Name="TileMetricsPanel" Margin="-6,0,0,0"/>
                  <TextBlock x:Name="TileMetricsInfo" Style="{StaticResource RowDesc}" Margin="0,6,0,0"/>
                </StackPanel>
                <Grid Margin="0,16,0,0">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="28"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <StackPanel>
                    <TextBlock Text="Größe" Style="{StaticResource RowDesc}" Margin="0,0,0,4"/>
                    <WrapPanel x:Name="TileSizePanel" Margin="-6,0,0,0"/>
                  </StackPanel>
                  <StackPanel Grid.Column="2">
                    <TextBlock Text="Farbe (Automatisch = Stil von oben)" Style="{StaticResource RowDesc}" Margin="0,0,0,4"/>
                    <WrapPanel x:Name="TileColorPanel"/>
                  </StackPanel>
                </Grid>
                <WrapPanel Margin="0,16,0,0">
                  <Button x:Name="BtnTileAdd" Style="{StaticResource BtnAccent}" Content="Kachel hinzufügen" Margin="0,0,10,8"/>
                  <Button x:Name="BtnTileStarter" Style="{StaticResource Btn}" Content="Starter-Set hinzufügen" Margin="0,0,10,8"/>
                  <Button x:Name="BtnTileCancel" Style="{StaticResource Btn}" Content="Bearbeiten abbrechen" Margin="0,0,10,8" Visibility="Collapsed"/>
                </WrapPanel>
              </StackPanel>
            </Border>
            <DockPanel Margin="0,20,0,10">
              <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                <Button x:Name="BtnTileArrange" Style="{StaticResource Btn}" Content="Neu anordnen" Margin="0,0,8,0"/>
                <Button x:Name="BtnTileClear" Style="{StaticResource Btn}" Content="Alle löschen"/>
              </StackPanel>
              <TextBlock Text="DEINE KACHELN" Style="{StaticResource Section}" Margin="4,0,0,0" VerticalAlignment="Center"/>
            </DockPanel>
            <StackPanel x:Name="TileListPanel"/>
          </StackPanel>
        </ScrollViewer>

        <ScrollViewer x:Name="PageFx" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="32,6,32,32">
            <TextBlock Text="Effekte, Maus &amp; Sound" Style="{StaticResource H1}"/>
            <TextBlock Text="Animationen, Fenster-Features, Mauszeiger und Systemsounds." Style="{StaticResource Sub}"/>
            <StackPanel x:Name="ListFx"/>
          </StackPanel>
        </ScrollViewer>

        <ScrollViewer x:Name="PageAds" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="32,6,32,32">
            <TextBlock Text="Werbung &amp; Tipps" Style="{StaticResource H1}"/>
            <TextBlock Text="Schalte Werbung, Popups und Vorschläge von Windows ab - für ein cleanes System." Style="{StaticResource Sub}"/>
            <StackPanel x:Name="ListAds"/>
          </StackPanel>
        </ScrollViewer>

        <ScrollViewer x:Name="PageBackup" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="32,6,32,32">
            <TextBlock Text="Backup &amp; Profile" Style="{StaticResource H1}"/>
            <TextBlock Text="Alles zurücksetzen oder deinen Look als Profil speichern und an Freunde weitergeben." Style="{StaticResource Sub}"/>
            <Border Style="{StaticResource CardStatic}" Margin="0,0,0,8">
              <StackPanel>
                <TextBlock Text="Automatisches Original-Backup" Style="{StaticResource RowTitle}"/>
                <TextBlock x:Name="TxtBackupInfo" Style="{StaticResource RowDesc}"/>
              </StackPanel>
            </Border>
            <StackPanel x:Name="ListBackup"/>
          </StackPanel>
        </ScrollViewer>
      </Grid>

      <!-- Toast -->
      <Border x:Name="Toast" Grid.Row="1" HorizontalAlignment="Center" VerticalAlignment="Bottom" Margin="0,0,0,24"
              Padding="16,10" CornerRadius="10" Background="#262A37" BorderBrush="#3A3F52" BorderThickness="1"
              Opacity="0" IsHitTestVisible="False">
        <StackPanel Orientation="Horizontal">
          <TextBlock x:Name="ToastIcon" Text="&#xE73E;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets"
                     Foreground="{DynamicResource Accent}" Margin="0,0,10,0" VerticalAlignment="Center"/>
          <TextBlock x:Name="ToastText" VerticalAlignment="Center" FontSize="13"/>
        </StackPanel>
      </Border>
    </Grid>
  </Grid>
</Window>
'@

# =====================================================================
#  Fenster laden
# =====================================================================
$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($node in $xaml.SelectNodes("//*[@*[local-name()='Name']]")) {
    $n = $node.Attributes | Where-Object { $_.LocalName -eq 'Name' } | Select-Object -First 1
    if ($n) { $el = $window.FindName($n.Value); if ($el) { $ui[$n.Value] = $el } }
}

$script:Bindings = New-Object System.Collections.ArrayList

# ---------- Toast ----------
$script:ToastTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:ToastTimer.Interval = [TimeSpan]::FromMilliseconds(2800)
$script:ToastTimer.add_Tick({
    $script:ToastTimer.Stop()
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation(0.0, (New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(250))))
    $ui.Toast.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $a)
})
function Show-Toast([string]$msg, [switch]$IsError) {
    $ui.ToastText.Text = $msg
    if ($IsError) { $ui.ToastIcon.Text = [string][char]0xE7BA; $ui.ToastIcon.Foreground = (Brush '#FF6B6B') }
    else { $ui.ToastIcon.Text = [string][char]0xE73E; $ui.ToastIcon.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Accent') }
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation(1.0, (New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(180))))
    $ui.Toast.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $a)
    $script:ToastTimer.Stop(); $script:ToastTimer.Start()
    if ($IsError) { Write-Log $msg }
}

function Get-ErrorText($err) {
    $ex = $err.Exception
    while ($ex.InnerException) { $ex = $ex.InnerException }
    if ($ex -is [System.UnauthorizedAccessException] -or $ex -is [System.Security.SecurityException]) {
        return 'Windows sperrt diese Einstellung für Apps - bitte direkt in den Windows-Einstellungen ändern.'
    }
    return $ex.Message
}

# ---------- Akzent in der App ----------
function Set-AppAccent([string]$hex) {
    $c = ConvertFrom-Hex $hex
    $window.Resources['Accent'] = [System.Windows.Media.SolidColorBrush](Brush $hex).psobject.BaseObject
    $window.Resources['AccentSoft'] = [System.Windows.Media.SolidColorBrush](Brush ('#26{0:X2}{1:X2}{2:X2}' -f $c.R, $c.G, $c.B)).psobject.BaseObject
    $dark = Format-Hex (Mix-Color $c 14 15 20 0.82)
    $lg = New-Object System.Windows.Media.LinearGradientBrush
    $lg.StartPoint = '0,0'; $lg.EndPoint = '1,1'
    $lg.GradientStops.Add((New-Object System.Windows.Media.GradientStop((WColor (Format-Hex (Mix-Color $c 0 0 0 0.05))), 0.0)))
    $lg.GradientStops.Add((New-Object System.Windows.Media.GradientStop((WColor (Format-Hex (Mix-Color $c 20 20 30 0.55))), 0.55)))
    $lg.GradientStops.Add((New-Object System.Windows.Media.GradientStop((WColor $dark), 1.0)))
    $lg.Freeze()
    $window.Resources['HeroBrush'] = [System.Windows.Media.LinearGradientBrush]$lg.psobject.BaseObject
}

# =====================================================================
#  UI-Bausteine
# =====================================================================
function New-TextBlock([string]$text, [string]$style) {
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $text
    if ($style) { $tb.Style = $window.FindResource($style) }
    return $tb
}

function Add-Section($panel, [string]$title, [string]$desc) {
    [void]$panel.Children.Add((New-TextBlock $title.ToUpper() 'Section'))
    if ($desc) { $descTb = New-TextBlock $desc 'RowDesc'; $descTb.Margin = '4,-6,0,10'; [void]$panel.Children.Add($descTb) }
}

function New-RowCard([string]$icon, [string]$title, [string]$desc, $right) {
    $card = New-Object System.Windows.Controls.Border
    $card.Style = $window.FindResource('Card')
    $grid = New-Object System.Windows.Controls.Grid
    $glc = New-Object System.Windows.GridLengthConverter
    foreach ($w in @('Auto', '*', 'Auto')) {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        $cd.Width = $glc.ConvertFromString($w)
        $grid.ColumnDefinitions.Add($cd)
    }
    $ib = New-Object System.Windows.Controls.Border
    $ib.Width = 38; $ib.Height = 38; $ib.CornerRadius = '10'; $ib.Background = (Brush '#232633')
    $ib.Margin = '0,0,14,0'; $ib.VerticalAlignment = 'Center'
    $it = New-Object System.Windows.Controls.TextBlock
    if (-not $icon) { $icon = [string][char]0xE713 }
    $it.Text = $icon; $it.FontFamily = 'Segoe Fluent Icons, Segoe MDL2 Assets'; $it.FontSize = 16
    $it.HorizontalAlignment = 'Center'; $it.VerticalAlignment = 'Center'
    $it.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Accent')
    $ib.Child = $it
    [void]$grid.Children.Add($ib)

    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.VerticalAlignment = 'Center'
    [void]$sp.Children.Add((New-TextBlock $title 'RowTitle'))
    if ($desc) { [void]$sp.Children.Add((New-TextBlock $desc 'RowDesc')) }
    [System.Windows.Controls.Grid]::SetColumn($sp, 1)
    [void]$grid.Children.Add($sp)

    if ($right) {
        $right.VerticalAlignment = 'Center'
        $right.Margin = '16,0,0,0'
        [System.Windows.Controls.Grid]::SetColumn($right, 2)
        [void]$grid.Children.Add($right)
    }
    $card.Child = $grid
    return $card
}

# ---------- Logik für Schalter / Auswahl ----------
function Get-DefState($def) {
    if ($def.Get) { return [bool](& $def.Get) }
    if ($def.Multi) {
        $parts = $def.Multi[0].Split('|')
        return ((Get-Reg $parts[0] $parts[1] $def.Default) -eq $def.On)
    }
    return ((Get-Reg $def.Path $def.Name $def.Default) -eq $def.On)
}

function Get-ChoiceValue($def) {
    if ($def.Get) { return (& $def.Get) }
    return (Get-Reg $def.Path $def.Name $def.Default)
}

function Apply-ToggleDef($def, [bool]$state) {
    $v = $def.Off; if ($state) { $v = $def.On }
    if ($def.Set) { & $def.Set $state }
    elseif ($def.Multi) { foreach ($m in $def.Multi) { $parts = $m.Split('|'); Set-Reg $parts[0] $parts[1] $v } }
    else {
        $kind = 'DWord'; if ($def.Kind) { $kind = $def.Kind }
        Set-Reg $def.Path $def.Name $v $kind
    }
}

function After-Change($def) {
    Send-SettingChange
    if ($def -and $def.Restart) { $ui.RestartBanner.Visibility = 'Visible' }
    Refresh-All
}

function Invoke-Toggle($cb) {
    $def = $cb.Tag
    $state = [bool]$cb.IsChecked
    try {
        Apply-ToggleDef $def $state
        $txt = 'Aus'; if ($state) { $txt = 'An' }
        Show-Toast ("{0}: {1}" -f $def.Title, $txt)
        After-Change $def
    } catch {
        $cb.IsChecked = -not $state
        Show-Toast ("Nicht möglich: " + (Get-ErrorText $_)) -IsError
        Refresh-All
    }
    Save-Backup
}

function Invoke-Choice($rb) {
    $def = $rb.Tag.Def
    $val = $rb.Tag.Value
    try {
        if ($def.Set) { & $def.Set $val }
        else {
            $kind = 'DWord'; if ($def.Kind) { $kind = $def.Kind }
            Set-Reg $def.Path $def.Name $val $kind
        }
        Show-Toast ("{0}: {1}" -f $def.Title, $rb.Content)
        After-Change $def
    } catch {
        Show-Toast ("Nicht möglich: " + (Get-ErrorText $_)) -IsError
        Refresh-All
    }
    Save-Backup
}

function Add-Toggle($panel, $def) {
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Style = $window.FindResource('Switch')
    $cb.Tag = $def
    $cb.add_Click({ param($s, $e) Invoke-Toggle $s })
    [void]$script:Bindings.Add(@{ Type = 'toggle'; Def = $def; Ctrl = $cb })
    [void]$panel.Children.Add((New-RowCard $def.Icon $def.Title $def.Desc $cb))
}

function Add-Choice($panel, $def) {
    $sp = New-Object System.Windows.Controls.WrapPanel
    $sp.HorizontalAlignment = 'Right'
    $group = 'g' + [guid]::NewGuid().ToString('N')
    $buttons = New-Object System.Collections.ArrayList
    foreach ($o in $def.Options) {
        $rb = New-Object System.Windows.Controls.RadioButton
        $rb.Style = $window.FindResource('Seg')
        $rb.GroupName = $group
        $rb.Content = $o[0]
        $rb.Tag = @{ Def = $def; Value = $o[1] }
        $rb.Margin = '6,3,0,3'
        $rb.add_Click({ param($s, $e) Invoke-Choice $s })
        [void]$sp.Children.Add($rb)
        [void]$buttons.Add($rb)
    }
    [void]$script:Bindings.Add(@{ Type = 'choice'; Def = $def; Buttons = $buttons })
    [void]$panel.Children.Add((New-RowCard $def.Icon $def.Title $def.Desc $sp))
}

function Add-Action($panel, [string]$icon, [string]$title, [string]$desc, [string]$btnText, [scriptblock]$action, [string]$style = 'Btn') {
    $btn = New-Object System.Windows.Controls.Button
    $btn.Style = $window.FindResource($style)
    $btn.Content = $btnText
    $btn.Tag = $action
    $btn.add_Click({
        param($s, $e)
        try { & $s.Tag } catch { Show-Toast ("Fehler: " + (Get-ErrorText $_)) -IsError }
        Save-Backup
    })
    [void]$panel.Children.Add((New-RowCard $icon $title $desc $btn))
}

# ---------- Anzeige aktualisieren ----------
function Update-Preview {
    try {
        $hex  = Get-AccentHex
        $c    = ConvertFrom-Hex $hex
        $apps = (Get-Reg $PERS 'AppsUseLightTheme' 1) -eq 1
        $sys  = (Get-Reg $PERS 'SystemUsesLightTheme' 0) -eq 1
        $tbAccent    = ((Get-Reg $PERS 'ColorPrevalence' 0) -eq 1) -and (-not $sys)
        $titleAccent = (Get-Reg $DWM 'ColorPrevalence' 0) -eq 1
        $left = (Get-Reg $ADV 'TaskbarAl' 1) -eq 0

        $lg = New-Object System.Windows.Media.LinearGradientBrush
        $lg.StartPoint = '0,0'; $lg.EndPoint = '1,1'
        $lg.GradientStops.Add((New-Object System.Windows.Media.GradientStop((WColor (Format-Hex (Mix-Color $c 10 10 20 0.75))), 0.0)))
        $lg.GradientStops.Add((New-Object System.Windows.Media.GradientStop((WColor (Format-Hex (Mix-Color $c 10 10 20 0.35))), 1.0)))
        $ui.PvDesktop.Background = $lg

        if ($apps) { $body = '#F3F3F3'; $line = '#C8CBD3'; $title = '#FFFFFF'; $border = '#D0D3DA' }
        else       { $body = '#202020'; $line = '#3A3D46'; $title = '#2B2B2B'; $border = '#3A3A3A' }
        if ($titleAccent) { $title = $hex; $border = $hex }
        $ui.PvBody.Background  = Brush $body
        $ui.PvLine1.Background = Brush $line
        $ui.PvLine2.Background = Brush $line
        $ui.PvTitle.Background = Brush $title
        $ui.PvWindow.BorderBrush = Brush $border

        if ($tbAccent) { $tb = Format-Hex (Mix-Color $c 0 0 0 0.35) }
        elseif ($sys)  { $tb = '#EEF0F4' }
        else           { $tb = '#1C1C1C' }
        $ui.PvTaskbar.Background = Brush $tb
        if ($left) { $ui.PvIcons.HorizontalAlignment = 'Left' } else { $ui.PvIcons.HorizontalAlignment = 'Center' }
    } catch { Write-Log "Vorschau: $_" }
}

function Update-Swatches {
    $cur = (Get-AccentHex).ToUpper()
    foreach ($b in $ui.SwatchPanel.Children) {
        if ([string]$b.Tag -eq $cur) { $b.BorderBrush = (Brush '#FFFFFF') } else { $b.BorderBrush = (Brush '#00000000') }
    }
}

function Update-Home {
    $hex  = Get-AccentHex
    $apps = (Get-Reg $PERS 'AppsUseLightTheme' 1) -eq 1
    $sys  = (Get-Reg $PERS 'SystemUsesLightTheme' 0) -eq 1
    if ($apps -and $sys) { $mode = 'Hell' } elseif (-not $apps -and -not $sys) { $mode = 'Dunkel' } else { $mode = 'Gemischt' }
    $ui.TxtMode.Text = $mode
    $ui.TxtAccent.Text = $hex
    $ui.HexBox.Text = $hex
    $ui.TxtBackupInfo.Text = ("Vor jeder Änderung wird der Originalwert gesichert ({0} Werte gespeichert). Datei: {1}" -f $script:Backup.Count, $BackupFile)
    Set-AppAccent $hex
}

function Refresh-All {
    foreach ($b in $script:Bindings) {
        try {
            if ($b.Type -eq 'toggle') { $b.Ctrl.IsChecked = [bool](Get-DefState $b.Def) }
            else {
                $cur = [string](Get-ChoiceValue $b.Def)
                foreach ($rb in $b.Buttons) { $rb.IsChecked = ([string]$rb.Tag.Value -eq $cur) }
            }
        } catch { Write-Log "Refresh $($b.Def.Title): $_" }
    }
    Update-Home
    Update-Preview
    Update-Swatches
}

# ---------- Aktionen ----------
function Apply-Accent([string]$hex) {
    if ($hex -notmatch '^#?[0-9A-Fa-f]{6}$') { Show-Toast 'Bitte einen Hex-Code wie #8B5CF6 eingeben' -IsError; return }
    if (-not $hex.StartsWith('#')) { $hex = '#' + $hex }
    $hex = $hex.ToUpper()
    try {
        Set-AccentColor $hex
        Save-Backup
        $ui.RestartBanner.Visibility = 'Visible'
        Show-Toast "Akzentfarbe $hex gesetzt"
        Refresh-All
    } catch { Show-Toast ("Nicht möglich: " + (Get-ErrorText $_)) -IsError }
}

function Pick-Color([string]$start) {
    $dlg = New-Object System.Windows.Forms.ColorDialog
    $dlg.FullOpen = $true
    try { $c = ConvertFrom-Hex $start; $dlg.Color = [System.Drawing.Color]::FromArgb($c.R, $c.G, $c.B) } catch {}
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return ('#{0:X2}{1:X2}{2:X2}' -f $dlg.Color.R, $dlg.Color.G, $dlg.Color.B)
    }
    return $null
}

function Apply-Preset($p) {
    $window.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        $file = New-GradientWallpaper $p.Name $p.Colors $p.Glow
        Set-Wallpaper $file '10'
        Set-Reg $PERS 'AppsUseLightTheme' $p.Light
        Set-Reg $PERS 'SystemUsesLightTheme' $p.Light
        Set-Reg $PERS 'EnableTransparency' 1
        $tb = 0; if ($p.TbAccent -and -not $p.Light) { $tb = 1 }
        Set-Reg $PERS 'ColorPrevalence' $tb
        Set-Reg $DWM 'ColorPrevalence' ([int]$p.TitleAccent)
        Set-AccentColor $p.Accent
        Save-Backup
        Refresh-All
        Restart-Explorer
        Show-Toast ("Theme '{0}' angewendet" -f $p.Name)
    } catch {
        Show-Toast ("Theme konnte nicht angewendet werden: " + (Get-ErrorText $_)) -IsError
    } finally { $window.Cursor = $null }
}

function Restore-All {
    $r = [System.Windows.MessageBox]::Show("Alle Einstellungen, die der Win11 Customizer je geändert hat, auf deine Originalwerte zurücksetzen?`n`nDer Explorer startet danach kurz neu.", 'Win11 Customizer', 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }
    $script:DeferSave = $true
    $fails = 0
    try {
        foreach ($e in @($script:Backup.Values)) { try { Apply-Entry $e } catch { $fails++; Write-Log "Restore $($e.Path)\$($e.Name): $_" } }
    } finally { $script:DeferSave = $false; Save-Backup }
    Apply-Live
    Refresh-All
    Restart-Explorer
    if ($fails -gt 0) { Show-Toast "Zurückgesetzt ($fails Werte konnten nicht geschrieben werden)" -IsError }
    else { Show-Toast 'Alles auf Original zurückgesetzt' }
}

function Export-Profile {
    if ($script:Backup.Count -eq 0) { Show-Toast 'Noch nichts geändert - es gibt nichts zu exportieren.' -IsError; return }
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = 'Win11-Customizer-Profil (*.w11c.json)|*.w11c.json'
    $dlg.FileName = 'Mein-Windows-Look.w11c.json'
    if (-not $dlg.ShowDialog($window)) { return }
    $entries = foreach ($e in @($script:Backup.Values)) {
        if ($e.Path -eq 'SPI') {
            [pscustomobject]@{ Path = 'SPI'; Name = $e.Name; Exists = $true; KeyExisted = $true; Kind = 'Bool'
                               Value = [W11C.Native]::GetBool([uint32]$e.GetCode); GetCode = $e.GetCode; SetCode = $e.SetCode }
        } else { Get-CurrentEntry $e.Path $e.Name }
    }
    $obj = [pscustomobject]@{ App = 'Win11Customizer'; Version = $AppVersion; Created = (Get-Date -Format 's'); Entries = @($entries) }
    Set-Content -Path $dlg.FileName -Value (ConvertTo-Json -InputObject $obj -Depth 6) -Encoding UTF8
    Show-Toast 'Profil gespeichert'
}

function Import-Profile {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'Win11-Customizer-Profil (*.w11c.json)|*.w11c.json|Alle Dateien (*.*)|*.*'
    if (-not $dlg.ShowDialog($window)) { return }
    $obj = Get-Content $dlg.FileName -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($obj.App -ne 'Win11Customizer') { throw 'Das ist kein Win11-Customizer-Profil.' }
    $script:DeferSave = $true
    $fails = 0
    try {
        foreach ($e in @($obj.Entries)) {
            # Wallpaper-Pfade anderer PCs überspringen, wenn die Datei hier nicht existiert
            if ($e.Path -eq $DESK -and $e.Name -eq 'Wallpaper' -and $e.Value -and -not (Test-Path ([Environment]::ExpandEnvironmentVariables([string]$e.Value)))) { continue }
            try { Apply-Entry $e } catch { $fails++; Write-Log "Import $($e.Path)\$($e.Name): $_" }
        }
    } finally { $script:DeferSave = $false; Save-Backup }
    Apply-Live
    Refresh-All
    Restart-Explorer
    if ($fails -gt 0) { Show-Toast "Profil geladen ($fails Werte übersprungen)" -IsError } else { Show-Toast 'Profil geladen' }
}

function New-DesktopShortcut {
    $deskPath = [Environment]::GetFolderPath('Desktop')
    $lnk  = Join-Path $deskPath 'Win11 Customizer.lnk'
    $sh = New-Object -ComObject WScript.Shell
    $s = $sh.CreateShortcut($lnk)
    if ($env:W11C_EXE -and (Test-Path $env:W11C_EXE)) {
        $s.TargetPath = $env:W11C_EXE
        $s.WorkingDirectory = Split-Path $env:W11C_EXE
        $s.IconLocation = $env:W11C_EXE + ',0'
    } else {
        $s.TargetPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $s.Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$PSCommandPath`""
        $s.WorkingDirectory = Split-Path $PSCommandPath
        $s.IconLocation = (Join-Path $env:WINDIR 'System32\imageres.dll') + ',186'
    }
    $s.Description = 'Win11 Customizer'
    $s.Save()
    Show-Toast 'Verknüpfung auf dem Desktop erstellt'
}


# =====================================================================
#  Desktop-Kacheln
# =====================================================================
$TilesFile   = Join-Path $AppDir 'tiles.json'
$TilesScript = Join-Path $PSScriptRoot 'DesktopTiles.ps1'
$RunKey      = 'Software\Microsoft\Windows\CurrentVersion\Run'
$PsExe       = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

$TileTypes = @(
    @{ Key = 'clock';    Label = 'Uhr';          Icon = 0xE823; Hint = 'Analoge Mac-Uhr oder digital (umstellbar oben bei "Uhr-Stil"). Klick öffnet die Uhr-App.' },
    @{ Key = 'security'; Label = 'Defender & Updates'; Icon = 0xEA18; Hint = 'Zeigt live, ob der Virenschutz an ist, ob Bedrohungen gefunden wurden, ob Updates warten oder ein Neustart nötig ist. Grün = alles gut, Orange = was zu tun, Rot = Problem. Tipp: Größe "Breit" oder "Groß".' },
    @{ Key = 'app';      Label = 'App';          Icon = 0xE71D; Hint = 'Programm oder Verknüpfung auswählen (z. B. aus dem Startmenü-Ordner, der beim Durchsuchen aufgeht).' },
    @{ Key = 'folder';   Label = 'Ordner';       Icon = 0xE8B7; Hint = 'Ein Ordner, der per Klick im Explorer aufgeht.' },
    @{ Key = 'web';      Label = 'Webseite';     Icon = 0xE774; Hint = 'Adresse eingeben, z. B. youtube.com - öffnet im Standard-Browser.' },
    @{ Key = 'system';   Label = 'Systemwerte';  Icon = 0xE9D9; Hint = 'Du wählst selbst, was angezeigt wird: CPU, Temperaturen, RAM, Grafikkarte, Mainboard, Lüfter, Netzwerk ... Klein = 2 Werte, Breit = 4 Werte, Groß = bis zu 7 Werte.' },
    @{ Key = 'network';  Label = 'Netzwerk';     Icon = 0xE839; Hint = 'Download und Upload live mit Verlaufsgraph der letzten Minute. Groß zeigt zusätzlich Adapter und IP.' },
    @{ Key = 'board';    Label = 'Mainboard';    Icon = 0xE950; Hint = 'Alle Temperaturen und Lüfter deines Mainboards (braucht HWiNFO, siehe oben).' },
    @{ Key = 'drive';    Label = 'Laufwerk';     Icon = 0xEDA2; Hint = 'Freier Speicher eines Laufwerks, z. B. C: oder D:' },
    @{ Key = 'note';     Label = 'Notiz';        Icon = 0xE70B; Hint = 'Ein kurzer Text, der immer auf dem Desktop steht.' },
    @{ Key = 'action';   Label = 'Aktion';       Icon = 0xE7E8; Hint = 'Ein Knopf für eine Windows-Aktion.' }
)
$TileActions = @(@('lock', 'Sperren'), @('restart', 'Neustart'), @('shutdown', 'Herunterfahren'), @('recycle', 'Papierkorb'),
                 @('settings', 'Einstellungen'), @('explorer', 'Explorer'), @('taskmgr', 'Task-Manager'))
$TileSizes = @(@('S', 'Klein'), @('W', 'Breit'), @('L', 'Groß'))
$TileColors = @('#0A84FF', '#30D158', '#FF9F0A', '#FF453A', '#BF5AF2', '#FF375F', '#64D2FF', '#FFD60A', '#1C1C1E', '#F5F5F7')
$script:TileForm = @{ Type = 'clock'; Size = 'S'; Color = ''; Action = 'lock'; Metrics = [System.Collections.ArrayList]::new() }
$script:EditTileId = $null
$TileMetricList = @(
    @('cpu_load', 'CPU-Last', $false), @('cpu_temp', 'CPU-Temp (Ø P-Kerne)', $true), @('cpu_clock', 'CPU-Takt', $true), @('cpu_power', 'CPU-Leistung', $true),
    @('ram', 'RAM', $false), @('gpu_load', 'GPU-Last', $true), @('gpu_temp', 'GPU-Temp', $true), @('gpu_vram', 'VRAM', $true),
    @('gpu_power', 'GPU-Leistung', $true), @('gpu_fan', 'GPU-Lüfter', $true), @('gpu_clock', 'GPU-Takt', $true),
    @('board_temp', 'Mainboard-Temp', $true), @('fans', 'Lüfter', $true), @('net_down', 'Download', $false), @('net_up', 'Upload', $false), @('uptime', 'Laufzeit', $false)
)
$DefaultMetrics = @('cpu_load', 'cpu_temp', 'gpu_load', 'gpu_temp')

function Test-HwInfo {
    try {
        $m = [System.IO.MemoryMappedFiles.MemoryMappedFile]::OpenExisting('Global\HWiNFO_SENS_SM2', [System.IO.MemoryMappedFiles.MemoryMappedFileRights]::Read)
        $m.Dispose(); return $true
    } catch { return $false }
}
function Update-MetricChips {
    if ($null -eq $script:TileForm.Metrics) { $script:TileForm.Metrics = [System.Collections.ArrayList]::new() }
    foreach ($cb in $ui.TileMetricsPanel.Children) { $cb.IsChecked = $script:TileForm.Metrics.Contains([string]$cb.Tag) }
    $names = @()
    foreach ($k in $script:TileForm.Metrics) { $e = $TileMetricList | Where-Object { $_[0] -eq $k } | Select-Object -First 1; if ($e) { $names += $e[1] } }
    $txt = 'Reihenfolge: ' + ($names -join '  ›  ')
    $needHw = $false
    foreach ($k in $script:TileForm.Metrics) { $e = $TileMetricList | Where-Object { $_[0] -eq $k } | Select-Object -First 1; if ($e -and $e[2]) { $needHw = $true } }
    if ($needHw -and -not (Test-HwInfo)) { $txt += "`nHinweis: Für Temperaturen/Lüfter muss HWiNFO mit Shared Memory laufen (siehe oben). GPU-Werte gehen bei NVIDIA auch ohne." }
    $ui.TileMetricsInfo.Text = $txt
}
function Toggle-FormMetric([string]$key, [bool]$on) {
    if ($null -eq $script:TileForm.Metrics) { $script:TileForm.Metrics = [System.Collections.ArrayList]::new() }
    if ($on) { if (-not $script:TileForm.Metrics.Contains($key)) { [void]$script:TileForm.Metrics.Add($key) } }
    else { $script:TileForm.Metrics.Remove($key) }
    Update-MetricChips
}
function Set-ObjProp($o, [string]$n, $v) {
    if ($o.PSObject.Properties[$n]) { $o.$n = $v } else { $o | Add-Member -NotePropertyName $n -NotePropertyValue $v }
}
function Exit-TileEdit {
    $script:EditTileId = $null
    $ui.BtnTileAdd.Content = 'Kachel hinzufügen'
    $ui.BtnTileCancel.Visibility = 'Collapsed'
    $ui.TileName.Text = ''
}
function Load-TileIntoForm([string]$id) {
    $cfg = Get-TileConfig
    $t = @($cfg.Tiles) | Where-Object { $_.Id -eq $id } | Select-Object -First 1
    if (-not $t) { return }
    Set-TileFormType ([string]$t.Type)
    $ui.TileName.Text = [string]$t.Name
    if ($t.Type -eq 'action') {
        $script:TileForm.Action = [string]$t.Target
        foreach ($rb in $ui.TileActionPanel.Children) { $rb.IsChecked = ([string]$rb.Tag -eq [string]$t.Target) }
    } else { $ui.TileTarget.Text = [string]$t.Target }
    Set-TileFormSize ([string]$t.Size)
    Set-TileFormColor ([string]$t.Color)
    if ($t.Type -eq 'system') {
        $script:TileForm.Metrics = [System.Collections.ArrayList]::new()
        $ms = @(); if ($t.PSObject.Properties['Metrics'] -and $t.Metrics) { $ms = ([string]$t.Metrics).Split(',') } else { $ms = @('cpu_load', 'ram') }
        foreach ($k in $ms) { if ($k) { [void]$script:TileForm.Metrics.Add($k.Trim()) } }
        Update-MetricChips
    }
    $script:EditTileId = $id
    $ui.BtnTileAdd.Content = 'Änderungen speichern'
    $ui.BtnTileCancel.Visibility = 'Visible'
    $ui.TileTypePanel.BringIntoView()
    Show-Toast "Bearbeite '$($t.Name)' - unten speichern"
}

function Get-TileConfig {
    $cfg = $null
    if (Test-Path $TilesFile) { try { $cfg = Get-Content $TilesFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Write-Log "tiles.json: $_" } }
    if (-not $cfg) { $cfg = [pscustomobject]@{ Enabled = $false; Tiles = @() } }
    $defaults = @(@('Style', 'mac-dark'), @('Opacity', '0.9'), @('Corners', 'mac'), @('Scale', '1'), @('Shadow', 'on'),
                  @('Labels', 'on'), @('ClockStyle', 'analog'), @('NetUnit', 'MBs'), @('Enabled', $false), @('Tiles', @()))
    foreach ($d0 in $defaults) {
        if (-not $cfg.PSObject.Properties[$d0[0]]) { $cfg | Add-Member -NotePropertyName $d0[0] -NotePropertyValue $d0[1] }
    }
    $cfg.Tiles = @(@($cfg.Tiles) | Where-Object { $_ })
    return $cfg
}
function Save-TileConfig($cfg) {
    Set-Content -Path $TilesFile -Value (ConvertTo-Json -InputObject $cfg -Depth 6) -Encoding UTF8
}
function Set-TileOption([string]$name, $value) {
    $cfg = Get-TileConfig
    $cfg.$name = $value
    Save-TileConfig $cfg
}
function Test-TileHost {
    $m = $null
    if ([System.Threading.Mutex]::TryOpenExisting('Local\Win11CustomizerTiles', [ref]$m)) { $m.Dispose(); return $true }
    return $false
}
function Start-TileHost {
    if (-not (Test-Path $TilesScript)) { throw 'DesktopTiles.ps1 fehlt im App-Ordner.' }
    if (Test-TileHost) { return }
    Start-Process -FilePath $PsExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $TilesScript)) -WindowStyle Hidden
}
function Get-TileCommand {
    if ($env:W11C_EXE -and (Test-Path $env:W11C_EXE)) { return ('"{0}" --tiles' -f $env:W11C_EXE) }
    '"{0}" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{1}"' -f $PsExe, $TilesScript
}

function Add-TilesToConfig($tiles) {
    $cfg = Get-TileConfig
    $cfg.Tiles = @(@($cfg.Tiles) + @($tiles))
    $cfg.Enabled = $true
    Save-TileConfig $cfg
    Start-TileHost
    Rebuild-TileList
    Refresh-All
}
function New-TileObject([string]$type, [string]$name, [string]$target, [string]$size, [string]$color, [string]$metrics = '') {
    [pscustomobject]@{ Id = [guid]::NewGuid().ToString('N').Substring(0, 10); Type = $type; Name = $name; Target = $target
                       Size = $size; Color = $color; Metrics = $metrics; X = $null; Y = $null }
}

function Set-TileFormType([string]$key) {
    $script:TileForm.Type = $key
    $info = $TileTypes | Where-Object { $_.Key -eq $key } | Select-Object -First 1
    $ui.TileHint.Text = $info.Hint
    $needsTarget = @('app', 'folder', 'web', 'drive', 'note') -contains $key
    if ($needsTarget) { $ui.TileTargetRow.Visibility = 'Visible' } else { $ui.TileTargetRow.Visibility = 'Collapsed' }
    if ($key -eq 'action') { $ui.TileActionRow.Visibility = 'Visible' } else { $ui.TileActionRow.Visibility = 'Collapsed' }
    if ($key -eq 'system') {
        $ui.TileMetricsRow.Visibility = 'Visible'
        if ($null -eq $script:TileForm.Metrics) { $script:TileForm.Metrics = [System.Collections.ArrayList]::new() }
        if ($script:TileForm.Metrics.Count -eq 0) { foreach ($k in $DefaultMetrics) { [void]$script:TileForm.Metrics.Add($k) } }
        Update-MetricChips
    } else { $ui.TileMetricsRow.Visibility = 'Collapsed' }
    if ($key -eq 'app' -or $key -eq 'folder') { $ui.BtnTileBrowse.Visibility = 'Visible' } else { $ui.BtnTileBrowse.Visibility = 'Collapsed' }
    $labels = @{ app = 'Programm / Verknüpfung'; folder = 'Ordner'; web = 'Webadresse'; drive = 'Laufwerk'; note = 'Text' }
    if ($labels.ContainsKey($key)) { $ui.TileTargetLabel.Text = $labels[$key] }
    $ui.TileTarget.Text = ''
    if ($key -eq 'drive') { $ui.TileTarget.Text = 'C:' }
    foreach ($rb in $ui.TileTypePanel.Children) { $rb.IsChecked = ([string]$rb.Tag -eq $key) }
    if (($key -eq 'security' -or $key -eq 'network' -or $key -eq 'board' -or $key -eq 'system') -and $script:TileForm.Size -eq 'S') { Set-TileFormSize 'W' }
}
function Set-TileFormSize([string]$key) {
    $script:TileForm.Size = $key
    foreach ($rb in $ui.TileSizePanel.Children) { $rb.IsChecked = ([string]$rb.Tag -eq $key) }
}
function Set-TileFormColor([string]$hex) {
    $script:TileForm.Color = $hex
    foreach ($el in $ui.TileColorPanel.Children) {
        if ($el -is [System.Windows.Controls.RadioButton]) { $el.IsChecked = ($hex -eq '') }
        elseif ($el.Tag -is [string] -and $el.Tag.StartsWith('#')) {
            if ($el.Tag -eq $hex) { $el.BorderBrush = Brush '#FFFFFF' } else { $el.BorderBrush = Brush '#00000000' }
        }
    }
}

function Add-TileFromForm {
    $f = $script:TileForm
    $type = $f.Type
    $name = $ui.TileName.Text.Trim()
    $target = $ui.TileTarget.Text.Trim()
    switch ($type) {
        'app' {
            if (-not $target -or -not (Test-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables($target)))) { throw 'Bitte ein Programm auswählen (Durchsuchen ...).' }
            if (-not $name) { $name = [IO.Path]::GetFileNameWithoutExtension($target) }
        }
        'folder' {
            if (-not $target -or -not (Test-Path -LiteralPath $target)) { throw 'Bitte einen Ordner auswählen (Durchsuchen ...).' }
            if (-not $name) { $name = Split-Path $target -Leaf; if (-not $name) { $name = $target } }
        }
        'web' {
            if (-not $target) { throw 'Bitte eine Webadresse eingeben, z. B. youtube.com' }
            if ($target -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') { $target = 'https://' + $target }
            if (-not $name) { try { $name = ([Uri]$target).Host -replace '^www\.', '' } catch { $name = $target } }
        }
        'drive' {
            if (-not $target) { $target = 'C:' }
            $target = $target.Substring(0, 1).ToUpper() + ':'
            if (-not (Test-Path ($target + '\'))) { throw "Laufwerk $target gibt es nicht." }
            if (-not $name) { $name = "Laufwerk $target" }
        }
        'note' {
            if (-not $target) { throw 'Bitte einen Notiztext eingeben.' }
            if (-not $name) { $name = 'Notiz' }
        }
        'action' {
            $target = $f.Action
            if (-not $name) { $name = ($TileActions | Where-Object { $_[0] -eq $target } | Select-Object -First 1)[1] }
        }
        'clock'    { $target = ''; if (-not $name) { $name = 'Uhr' } }
        'system'   { $target = ''; if (-not $name) { $name = 'System' }; if ($f.Metrics.Count -eq 0) { throw 'Bitte mindestens einen Wert auswählen.' } }
        'network'  { $target = ''; if (-not $name) { $name = 'Netzwerk' } }
        'board'    { $target = ''; if (-not $name) { $name = 'Mainboard' } }
        'security' { $target = ''; if (-not $name) { $name = 'Sicherheit' } }
    }
    $metrics = ''
    if ($type -eq 'system') { $metrics = (@($f.Metrics) -join ',') }
    if ($script:EditTileId) {
        $cfg = Get-TileConfig
        $t = @($cfg.Tiles) | Where-Object { $_.Id -eq $script:EditTileId } | Select-Object -First 1
        if (-not $t) { Exit-TileEdit; throw 'Die Kachel gibt es nicht mehr.' }
        if ([string]$t.Size -ne $f.Size) { $t.X = $null; $t.Y = $null }
        $t.Type = $type; $t.Name = $name; $t.Target = $target; $t.Size = $f.Size; $t.Color = $f.Color
        Set-ObjProp $t 'Metrics' $metrics
        $cfg.Enabled = $true
        Save-TileConfig $cfg
        Start-TileHost
        Exit-TileEdit
        Rebuild-TileList
        Show-Toast "Kachel '$name' gespeichert"
        return
    }
    Add-TilesToConfig @(New-TileObject $type $name $target $f.Size $f.Color $metrics)
    $ui.TileName.Text = ''
    if ($type -ne 'drive') { $ui.TileTarget.Text = '' }
    Show-Toast "Kachel '$name' hinzugefügt - schau auf deinen Desktop"
}

function Browse-TileTarget {
    if ($script:TileForm.Type -eq 'folder') {
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Ordner für die Kachel wählen'
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $ui.TileTarget.Text = $dlg.SelectedPath }
    } else {
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Filter = 'Programme & Verknüpfungen|*.exe;*.lnk;*.url;*.bat|Alle Dateien|*.*'
        $dlg.InitialDirectory = [Environment]::GetFolderPath('CommonPrograms')
        $dlg.DereferenceLinks = $false
        if ($dlg.ShowDialog($window)) {
            $ui.TileTarget.Text = $dlg.FileName
            if (-not $ui.TileName.Text) { $ui.TileName.Text = [IO.Path]::GetFileNameWithoutExtension($dlg.FileName) }
        }
    }
}

function Edit-Tile([string]$id, [string]$cmd) {
    if ($cmd -eq 'edit') { Load-TileIntoForm $id; return }
    $cfg = Get-TileConfig
    $t = @($cfg.Tiles) | Where-Object { $_.Id -eq $id } | Select-Object -First 1
    if (-not $t) { return }
    switch ($cmd) {
        'size' {
            $next = @{ S = 'W'; W = 'L'; L = 'S' }
            $t.Size = $next[[string]$t.Size]
            if (-not $t.Size) { $t.Size = 'S' }
            $t.X = $null; $t.Y = $null
        }
        'color' {
            $start = '#0A84FF'; if ($t.Color) { $start = [string]$t.Color }
            $h = Pick-Color $start
            if (-not $h) { return }
            $t.Color = $h
        }
        'auto'   { $t.Color = '' }
        'delete' { $cfg.Tiles = @(@($cfg.Tiles) | Where-Object { $_.Id -ne $id }) }
    }
    Save-TileConfig $cfg
    Rebuild-TileList
}

function New-IconButton([int]$glyph, [string]$tip, [string]$id, [string]$cmd) {
    $b = New-Object System.Windows.Controls.Button
    $b.Style = $window.FindResource('Btn')
    $b.Padding = '11,9'; $b.Margin = '6,0,0,0'
    $b.FontFamily = 'Segoe Fluent Icons, Segoe MDL2 Assets'; $b.FontSize = 13
    $b.Content = [string][char]$glyph
    $b.ToolTip = $tip
    $b.Tag = @{ Id = $id; Cmd = $cmd }
    $b.add_Click({ param($s, $e) try { Edit-Tile $s.Tag.Id $s.Tag.Cmd } catch { Show-Toast ('Fehler: ' + (Get-ErrorText $_)) -IsError } })
    return $b
}

function Rebuild-TileList {
    $ui.TileListPanel.Children.Clear()
    $cfg = Get-TileConfig
    $tiles = @($cfg.Tiles)
    if ($tiles.Count -eq 0) {
        $tb = New-TextBlock 'Noch keine Kacheln. Füge oben eine hinzu oder nimm das Starter-Set.' 'RowDesc'
        $tb.Margin = '4,0,0,0'
        [void]$ui.TileListPanel.Children.Add($tb)
        return
    }
    $sizeNames = @{ S = 'Klein'; W = 'Breit'; L = 'Groß' }
    foreach ($t in $tiles) {
        $info = $TileTypes | Where-Object { $_.Key -eq $t.Type } | Select-Object -First 1
        $icon = [string][char]0xECA5; $typeLabel = [string]$t.Type
        if ($info) { $icon = [string][char]$info.Icon; $typeLabel = $info.Label }
        $desc = "$typeLabel · $($sizeNames[[string]$t.Size])"
        if ($t.Color) { $desc += " · $($t.Color)" }
        if ($t.Type -eq 'system' -and $t.PSObject.Properties['Metrics'] -and $t.Metrics) {
            $mn = @(); foreach ($k in ([string]$t.Metrics).Split(',')) { $e = $TileMetricList | Where-Object { $_[0] -eq $k } | Select-Object -First 1; if ($e) { $mn += $e[1] } }
            $desc += ' · ' + ($mn -join ', ')
        }
        if ($t.Target -and $t.Type -ne 'action') {
            $tg = [string]$t.Target; if ($tg.Length -gt 60) { $tg = $tg.Substring(0, 57) + '...' }
            $desc += " · $tg"
        }
        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Orientation = 'Horizontal'
        if ($t.Color) {
            $sw = New-Object System.Windows.Controls.Border
            $sw.Width = 14; $sw.Height = 14; $sw.CornerRadius = '7'; $sw.Background = Brush ([string]$t.Color); $sw.Margin = '0,0,6,0'
            $sw.VerticalAlignment = 'Center'
            [void]$sp.Children.Add($sw)
        }
        [void]$sp.Children.Add((New-IconButton 0xE70F 'Bearbeiten' $t.Id 'edit'))
        [void]$sp.Children.Add((New-IconButton 0xE740 'Größe ändern (Klein / Breit / Groß)' $t.Id 'size'))
        [void]$sp.Children.Add((New-IconButton 0xE790 'Eigene Farbe' $t.Id 'color'))
        if ($t.Color) { [void]$sp.Children.Add((New-IconButton 0xE72C 'Farbe zurück auf Automatisch' $t.Id 'auto')) }
        [void]$sp.Children.Add((New-IconButton 0xE74D 'Löschen' $t.Id 'delete'))
        [void]$ui.TileListPanel.Children.Add((New-RowCard $icon ([string]$t.Name) $desc $sp))
    }
}

# =====================================================================
#  Seiten aufbauen
# =====================================================================
# --- Start: Themes ---
foreach ($p in $Presets) {
    $card = New-Object System.Windows.Controls.Border
    $card.Style = $window.FindResource('Card')
    $card.Width = 214; $card.Margin = '0,0,12,12'; $card.Padding = '10'; $card.Cursor = 'Hand'; $card.Tag = $p
    $card.ToolTip = "Theme '$($p.Name)' anwenden"
    $sp = New-Object System.Windows.Controls.StackPanel

    $prev = New-Object System.Windows.Controls.Border
    $prev.Height = 116; $prev.CornerRadius = '8'; $prev.ClipToBounds = $true
    $lg = New-Object System.Windows.Media.LinearGradientBrush
    $lg.StartPoint = '0,0'; $lg.EndPoint = '1,1'
    for ($i = 0; $i -lt $p.Colors.Count; $i++) {
        $lg.GradientStops.Add((New-Object System.Windows.Media.GradientStop((WColor $p.Colors[$i]), ($i / ($p.Colors.Count - 1)))))
    }
    $prev.Background = $lg
    $pg = New-Object System.Windows.Controls.Grid
    $glow = New-Object System.Windows.Shapes.Ellipse
    $glow.Width = 160; $glow.Height = 120; $glow.HorizontalAlignment = 'Right'; $glow.VerticalAlignment = 'Bottom'; $glow.Margin = '0,0,-50,-40'
    $rg = New-Object System.Windows.Media.RadialGradientBrush
    $gc = WColor $p.Glow
    $rg.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromArgb(110, $gc.R, $gc.G, $gc.B), 0.0)))
    $rg.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromArgb(0, $gc.R, $gc.G, $gc.B), 1.0)))
    $glow.Fill = $rg
    [void]$pg.Children.Add($glow)
    $win = New-Object System.Windows.Controls.Border
    $win.Width = 96; $win.Height = 54; $win.CornerRadius = '5'; $win.VerticalAlignment = 'Top'; $win.Margin = '0,14,0,0'
    if ($p.Light) { $win.Background = Brush '#F3F3F3' } else { $win.Background = Brush '#E6202020' }
    $wsp = New-Object System.Windows.Controls.StackPanel; $wsp.Margin = '8'
    $l1 = New-Object System.Windows.Controls.Border; $l1.Height = 5; $l1.Width = 60; $l1.CornerRadius = '2'; $l1.HorizontalAlignment = 'Left'
    if ($p.Light) { $l1.Background = Brush '#C8CBD3' } else { $l1.Background = Brush '#45484F' }
    $bt = New-Object System.Windows.Controls.Border; $bt.Height = 12; $bt.Width = 34; $bt.CornerRadius = '3'; $bt.HorizontalAlignment = 'Left'; $bt.Margin = '0,10,0,0'
    $bt.Background = Brush $p.Accent
    [void]$wsp.Children.Add($l1); [void]$wsp.Children.Add($bt)
    $win.Child = $wsp
    [void]$pg.Children.Add($win)
    $bar = New-Object System.Windows.Controls.Border
    $bar.Height = 16; $bar.VerticalAlignment = 'Bottom'
    if ($p.Light) { $bar.Background = Brush '#CCF3F4F7' } elseif ($p.TbAccent) { $bar.Background = Brush $p.Accent } else { $bar.Background = Brush '#CC1C1C1C' }
    $dots = New-Object System.Windows.Controls.StackPanel; $dots.Orientation = 'Horizontal'; $dots.HorizontalAlignment = 'Center'; $dots.VerticalAlignment = 'Center'
    for ($i = 0; $i -lt 4; $i++) {
        $dot = New-Object System.Windows.Controls.Border; $dot.Width = 8; $dot.Height = 8; $dot.CornerRadius = '2'; $dot.Margin = '2,0'
        if ($i -eq 0) { $dot.Background = Brush $p.Accent } else { $dot.Background = Brush '#8890A0' }
        [void]$dots.Children.Add($dot)
    }
    $bar.Child = $dots
    [void]$pg.Children.Add($bar)
    $prev.Child = $pg
    [void]$sp.Children.Add($prev)

    $nm = New-TextBlock $p.Name 'RowTitle'; $nm.Margin = '4,10,0,0'
    [void]$sp.Children.Add($nm)
    $mode = 'Dunkel'; if ($p.Light) { $mode = 'Hell' }
    $ds = New-TextBlock ("{0} - {1}" -f $mode, $p.Accent) 'RowDesc'; $ds.Margin = '4,2,0,2'
    [void]$sp.Children.Add($ds)
    $card.Child = $sp
    $card.add_MouseLeftButtonUp({ param($s, $e) Apply-Preset $s.Tag })
    [void]$ui.PresetPanel.Children.Add($card)
}

# --- Start: beliebte Tweaks ---
Add-Toggle $ui.ListHome $Defs.ExClassic
Add-Choice $ui.ListHome $Defs.TbAlign
Add-Toggle $ui.ListHome $Defs.ExExt
Add-Toggle $ui.ListHome $Defs.StBing
Add-Action $ui.ListHome ([string][char]0xEA18) 'Werbung & Tipps komplett aus' 'Deaktiviert mit einem Klick alle Werbe- und Vorschlags-Optionen von Windows.' 'Alles aus' {
    $script:DeferSave = $true
    try { foreach ($ad in $AdDefs) { try { Apply-ToggleDef $ad $false } catch {} } } finally { $script:DeferSave = $false }
    After-Change $null
    Show-Toast 'Werbung & Tipps deaktiviert'
} 'BtnAccent'

# --- Farben ---
foreach ($hex in $Swatches) {
    $b = New-Object System.Windows.Controls.Button
    $b.Style = $window.FindResource('Swatch')
    $b.Background = Brush $hex
    $b.Tag = $hex.ToUpper()
    $b.ToolTip = $hex
    $b.add_Click({ param($s, $e) Apply-Accent ([string]$s.Tag) })
    [void]$ui.SwatchPanel.Children.Add($b)
}
$ui.BtnHexApply.add_Click({ Apply-Accent $ui.HexBox.Text.Trim() })
$ui.HexBox.add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { Apply-Accent $ui.HexBox.Text.Trim() } })
$ui.BtnPickColor.add_Click({ $h = Pick-Color (Get-AccentHex); if ($h) { Apply-Accent $h } })

Add-Section $ui.ListColors 'Hell & Dunkel'
Add-Choice $ui.ListColors $Defs.SysMode
Add-Choice $ui.ListColors $Defs.AppsMode
Add-Section $ui.ListColors 'Farbe & Effekte'
Add-Toggle $ui.ListColors $Defs.Transparency
Add-Toggle $ui.ListColors $Defs.AccentBar
Add-Toggle $ui.ListColors $Defs.AccentTitle
Add-Toggle $ui.ListColors $Defs.AutoAccent

# --- Taskleiste ---
Add-Section $ui.ListTaskbar 'Aussehen'
Add-Choice $ui.ListTaskbar $Defs.TbAlign
Add-Choice $ui.ListTaskbar $Defs.TbSearch
Add-Choice $ui.ListTaskbar $Defs.TbGlom
Add-Section $ui.ListTaskbar 'Buttons & Elemente'
Add-Toggle $ui.ListTaskbar $Defs.TbTaskView
Add-Toggle $ui.ListTaskbar $Defs.TbWidgets
Add-Toggle $ui.ListTaskbar $Defs.TbBadges
Add-Toggle $ui.ListTaskbar $Defs.TbDesktop
Add-Toggle $ui.ListTaskbar $Defs.TbSeconds
Add-Section $ui.ListTaskbar 'Verhalten'
Add-Toggle $ui.ListTaskbar $Defs.TbAutoHide
Add-Toggle $ui.ListTaskbar $Defs.TbEndTask
Add-Toggle $ui.ListTaskbar $Defs.TbMulti

# --- Startmenü ---
Add-Section $ui.ListStart 'Layout'
Add-Choice $ui.ListStart $Defs.StLayout
Add-Toggle $ui.ListStart $Defs.StProgs
Add-Toggle $ui.ListStart $Defs.StDocs
Add-Section $ui.ListStart 'Empfehlungen & Suche'
Add-Toggle $ui.ListStart $Defs.StIris
Add-Toggle $ui.ListStart $Defs.StAcct
Add-Toggle $ui.ListStart $Defs.StBing
Add-Toggle $ui.ListStart $Defs.StHighlights

# --- Explorer & Desktop ---
Add-Section $ui.ListExplorer 'Datei-Explorer'
Add-Toggle $ui.ListExplorer $Defs.ExClassic
Add-Choice $ui.ListExplorer $Defs.ExLaunch
Add-Toggle $ui.ListExplorer $Defs.ExExt
Add-Toggle $ui.ListExplorer $Defs.ExHidden
Add-Toggle $ui.ListExplorer $Defs.ExSuper
Add-Toggle $ui.ListExplorer $Defs.ExCompact
Add-Toggle $ui.ListExplorer $Defs.ExCheck
Add-Toggle $ui.ListExplorer $Defs.ExPath
Add-Toggle $ui.ListExplorer $Defs.ExRecent
Add-Toggle $ui.ListExplorer $Defs.ExFreq
Add-Section $ui.ListExplorer 'Hintergrundbild'
Add-Action $ui.ListExplorer ([string][char]0xE8B9) 'Eigenes Hintergrundbild' 'Wähle ein Bild von deinem PC (JPG, PNG, BMP).' 'Bild wählen...' {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'Bilder|*.jpg;*.jpeg;*.png;*.bmp;*.jfif;*.webp|Alle Dateien|*.*'
    if ($dlg.ShowDialog($window)) {
        Set-Wallpaper $dlg.FileName ([string](Get-Reg $DESK 'WallpaperStyle' '10'))
        Show-Toast 'Hintergrundbild gesetzt'
        Refresh-All
    }
} 'BtnAccent'
Add-Choice $ui.ListExplorer $Defs.DkStyle
Add-Action $ui.ListExplorer ([string][char]0xE790) 'Einfarbiger Hintergrund' 'Minimalistisch: eine einzige Farbe statt Bild.' 'Farbe wählen...' {
    $h = Pick-Color '#101218'
    if ($h) { Set-SolidBackground $h; Show-Toast "Hintergrund $h gesetzt" }
}
Add-Action $ui.ListExplorer ([string][char]0xE8B7) 'Theme-Hintergründe' 'Ordner mit den erzeugten 4K-Hintergründen der Themes öffnen.' 'Ordner öffnen' {
    $dir = Join-Path $AppDir 'Wallpapers'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Start-Process explorer.exe $dir
}
Add-Section $ui.ListExplorer 'Desktop-Symbole'
Add-Toggle $ui.ListExplorer $Defs.DkIcons
Add-Toggle $ui.ListExplorer $Defs.DkPC
Add-Toggle $ui.ListExplorer $Defs.DkBin
Add-Toggle $ui.ListExplorer $Defs.DkUser
Add-Toggle $ui.ListExplorer $Defs.DkNet
Add-Toggle $ui.ListExplorer $Defs.DkCP

# --- Desktop-Kacheln ---
$Defs.TlOn = @{ Title = 'Kacheln auf dem Desktop anzeigen'; Desc = 'Startet die Kacheln im Hintergrund. Aus = alle Kacheln verschwinden.'; Icon = [string][char]0xECA5
    Get = { [bool](Get-TileConfig).Enabled }
    Set = { param($on) Set-TileOption 'Enabled' ([bool]$on); if ($on) { Start-TileHost } } }
$Defs.TlAuto = @{ Title = 'Kacheln mit Windows starten'; Desc = 'Kacheln erscheinen automatisch nach dem Anmelden.'; Icon = [string][char]0xE7E8
    Get = { $null -ne (Get-Reg $RunKey 'Win11CustomizerTiles' $null) }
    Set = { param($on) if ($on) { Set-Reg $RunKey 'Win11CustomizerTiles' (Get-TileCommand) 'String' } else { Remove-RegValueTracked $RunKey 'Win11CustomizerTiles' } } }
$Defs.TlStyle = @{ Title = 'Stil'; Desc = 'Mac hell/dunkel wie macOS-Widgets, Glas, deine Akzentfarbe oder bunt wie Windows 8.'; Icon = [string][char]0xE771
    Options = @(@('Mac dunkel', 'mac-dark'), @('Mac hell', 'mac-light'), @('Glas', 'glass'), @('Akzent', 'accent'), @('Bunt', 'color'))
    Get = { [string](Get-TileConfig).Style }; Set = { param($v) Set-TileOption 'Style' ([string]$v) } }
$Defs.TlCorners = @{ Title = 'Ecken'; Desc = 'Mac = stark abgerundet, Rund = leicht, Eckig = Windows-8-Look.'; Icon = [string][char]0xE7C4
    Options = @(@('Mac', 'mac'), @('Rund', 'round'), @('Eckig', 'square'))
    Get = { [string](Get-TileConfig).Corners }; Set = { param($v) Set-TileOption 'Corners' ([string]$v) } }
$Defs.TlClock = @{ Title = 'Uhr-Stil'; Desc = 'Analog wie die Mac-Uhr oder digital mit großen Ziffern.'; Icon = [string][char]0xE823
    Options = @(@('Analog', 'analog'), @('Digital', 'digital'))
    Get = { [string](Get-TileConfig).ClockStyle }; Set = { param($v) Set-TileOption 'ClockStyle' ([string]$v) } }
$Defs.TlOpacity = @{ Title = 'Deckkraft'; Desc = 'Wie stark der Hintergrund durchscheint.'; Icon = [string][char]0xE890
    Options = @(@('60 %', '0.6'), @('75 %', '0.75'), @('90 %', '0.9'), @('100 %', '1'))
    Get = { [string](Get-TileConfig).Opacity }; Set = { param($v) Set-TileOption 'Opacity' ([string]$v) } }
$Defs.TlScale = @{ Title = 'Kachelgröße'; Desc = 'Für große oder 4K-Bildschirme einfach hochdrehen.'; Icon = [string][char]0xE740
    Options = @(@('Kompakt', '0.85'), @('Normal', '1'), @('Groß', '1.25'), @('Riesig', '1.5'))
    Get = { [string](Get-TileConfig).Scale }; Set = { param($v) Set-TileOption 'Scale' ([string]$v) } }
$Defs.TlNetUnit = @{ Title = 'Netzwerk-Einheit'; Desc = 'MB/s (wie beim Download im Browser) oder Mbit/s (wie dein Internet-Tarif).'; Icon = [string][char]0xE839
    Options = @(@('MB/s', 'MBs'), @('Mbit/s', 'Mbit'))
    Get = { [string](Get-TileConfig).NetUnit }; Set = { param($v) Set-TileOption 'NetUnit' ([string]$v) } }
$Defs.TlShadow = @{ Title = 'Schatten'; Desc = 'Weicher Schatten unter den Kacheln wie bei macOS.'; Icon = [string][char]0xE81E
    Get = { [string](Get-TileConfig).Shadow -ne 'off' }
    Set = { param($on) $v = 'off'; if ($on) { $v = 'on' }; Set-TileOption 'Shadow' $v } }
$Defs.TlLabels = @{ Title = 'Namen unter App-Symbolen'; Desc = 'Zeigt den Namen bei App-, Ordner-, Web- und Aktions-Kacheln.'; Icon = [string][char]0xE8D2
    Get = { [string](Get-TileConfig).Labels -ne 'off' }
    Set = { param($on) $v = 'off'; if ($on) { $v = 'on' }; Set-TileOption 'Labels' $v } }

Add-Section $ui.ListTiles 'Allgemein'
Add-Toggle $ui.ListTiles $Defs.TlOn
Add-Toggle $ui.ListTiles $Defs.TlAuto
Add-Section $ui.ListTiles 'Aussehen'
Add-Choice $ui.ListTiles $Defs.TlStyle
Add-Choice $ui.ListTiles $Defs.TlCorners
Add-Choice $ui.ListTiles $Defs.TlClock
Add-Choice $ui.ListTiles $Defs.TlOpacity
Add-Choice $ui.ListTiles $Defs.TlScale
Add-Toggle $ui.ListTiles $Defs.TlShadow
Add-Toggle $ui.ListTiles $Defs.TlLabels
Add-Choice $ui.ListTiles $Defs.TlNetUnit
Add-Section $ui.ListTiles 'Sensoren (Temperaturen & Lüfter)' 'Windows lässt normale Apps keine Temperaturen auslesen. Dafür nutzen die Kacheln HWiNFO (kostenlos). Einmal einrichten: HWiNFO installieren > beim Start "Sensors-only" wählen > Einstellungen (Zahnrad) > "Shared Memory Support" anhaken > zusätzlich "Auto Start" und "Minimize Sensors on Startup" anhaken. NVIDIA-Grafikkarten-Werte gehen zur Not auch ohne HWiNFO.'
Add-Action $ui.ListTiles ([string][char]0xE9D9) 'HWiNFO-Verbindung prüfen' 'Prüft, ob die Kacheln gerade Sensordaten von HWiNFO bekommen.' 'Jetzt prüfen' {
    if (Test-HwInfo) { Show-Toast 'HWiNFO verbunden - Temperaturen und Lüfter werden angezeigt' }
    else { Show-Toast 'HWiNFO nicht gefunden: läuft es und ist "Shared Memory Support" an?' -IsError }
}
Add-Action $ui.ListTiles ([string][char]0xE896) 'HWiNFO herunterladen' 'Öffnet die offizielle Download-Seite von HWiNFO.' 'Webseite öffnen' { Start-Process 'https://www.hwinfo.com/download/' }

foreach ($tt in $TileTypes) {
    $rb = New-Object System.Windows.Controls.RadioButton
    $rb.Style = $window.FindResource('Seg'); $rb.GroupName = 'tiletype'; $rb.Margin = '6,3,0,3'
    $rb.Content = $tt.Label; $rb.Tag = $tt.Key
    $rb.add_Click({ param($s, $e) Set-TileFormType ([string]$s.Tag) })
    [void]$ui.TileTypePanel.Children.Add($rb)
}
foreach ($tm in $TileMetricList) {
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Style = $window.FindResource('MetricChip')
    $lbl = $tm[1]; if ($tm[2]) { $lbl += ' *' }
    $cb.Content = $lbl; $cb.Tag = $tm[0]
    if ($tm[2]) { $cb.ToolTip = 'braucht HWiNFO (GPU-Werte bei NVIDIA auch ohne)' }
    $cb.add_Click({ param($s, $e) Toggle-FormMetric ([string]$s.Tag) ([bool]$s.IsChecked) })
    [void]$ui.TileMetricsPanel.Children.Add($cb)
}
$ui.BtnTileCancel.add_Click({ Exit-TileEdit; Show-Toast 'Bearbeiten abgebrochen' })
foreach ($ta in $TileActions) {
    $rb = New-Object System.Windows.Controls.RadioButton
    $rb.Style = $window.FindResource('Seg'); $rb.GroupName = 'tileaction'; $rb.Margin = '6,3,0,3'
    $rb.Content = $ta[1]; $rb.Tag = $ta[0]
    if ($ta[0] -eq 'lock') { $rb.IsChecked = $true }
    $rb.add_Click({ param($s, $e) $script:TileForm.Action = [string]$s.Tag })
    [void]$ui.TileActionPanel.Children.Add($rb)
}
foreach ($ts in $TileSizes) {
    $rb = New-Object System.Windows.Controls.RadioButton
    $rb.Style = $window.FindResource('Seg'); $rb.GroupName = 'tilesize'; $rb.Margin = '6,3,0,3'
    $rb.Content = $ts[1]; $rb.Tag = $ts[0]
    $rb.add_Click({ param($s, $e) Set-TileFormSize ([string]$s.Tag) })
    [void]$ui.TileSizePanel.Children.Add($rb)
}
$autoRb = New-Object System.Windows.Controls.RadioButton
$autoRb.Style = $window.FindResource('Seg'); $autoRb.GroupName = 'tilecolor'; $autoRb.Margin = '0,0,10,8'
$autoRb.Content = 'Automatisch'; $autoRb.Tag = 'auto'; $autoRb.VerticalAlignment = 'Center'
$autoRb.add_Click({ Set-TileFormColor '' })
[void]$ui.TileColorPanel.Children.Add($autoRb)
foreach ($hex in $TileColors) {
    $b = New-Object System.Windows.Controls.Button
    $b.Style = $window.FindResource('Swatch'); $b.Width = 32; $b.Height = 32
    $b.Background = Brush $hex; $b.Tag = $hex; $b.ToolTip = $hex
    $b.add_Click({ param($s, $e) Set-TileFormColor ([string]$s.Tag) })
    [void]$ui.TileColorPanel.Children.Add($b)
}
$ui.BtnTileBrowse.add_Click({ try { Browse-TileTarget } catch { Show-Toast ('Fehler: ' + (Get-ErrorText $_)) -IsError } })
$ui.BtnTileAdd.add_Click({ try { Add-TileFromForm } catch { Show-Toast (Get-ErrorText $_) -IsError } })
$ui.BtnTileStarter.add_Click({
    try {
        $set = @(
            (New-TileObject 'clock' 'Uhr' '' 'L' ''),
            (New-TileObject 'security' 'Sicherheit' '' 'W' ''),
            (New-TileObject 'system' 'System' '' 'W' '' 'cpu_load,cpu_temp,gpu_load,gpu_temp'),
            (New-TileObject 'network' 'Netzwerk' '' 'W' ''),
            (New-TileObject 'drive' 'Laufwerk C:' 'C:' 'W' ''),
            (New-TileObject 'action' 'Explorer' 'explorer' 'S' ''),
            (New-TileObject 'action' 'Einstellungen' 'settings' 'S' ''),
            (New-TileObject 'action' 'Papierkorb' 'recycle' 'S' ''),
            (New-TileObject 'action' 'Sperren' 'lock' 'S' '')
        )
        Add-TilesToConfig $set
        Show-Toast 'Starter-Set hinzugefügt - schau auf deinen Desktop'
    } catch { Show-Toast ('Fehler: ' + (Get-ErrorText $_)) -IsError }
})
$ui.BtnTileArrange.add_Click({
    try {
        $cfg = Get-TileConfig
        foreach ($t in @($cfg.Tiles)) { $t.X = $null; $t.Y = $null }
        Save-TileConfig $cfg
        Show-Toast 'Kacheln werden neu angeordnet'
    } catch { Show-Toast ('Fehler: ' + (Get-ErrorText $_)) -IsError }
})
$ui.BtnTileClear.add_Click({
    if ([System.Windows.MessageBox]::Show('Wirklich alle Kacheln löschen?', 'Win11 Customizer', 'YesNo', 'Question') -ne 'Yes') { return }
    $cfg = Get-TileConfig; $cfg.Tiles = @(); Save-TileConfig $cfg
    Rebuild-TileList
    Show-Toast 'Alle Kacheln gelöscht'
})
Set-TileFormType 'clock'
Set-TileFormSize 'S'
Set-TileFormColor ''
Rebuild-TileList

# --- Effekte ---
Add-Section $ui.ListFx 'Fenster & Animationen'
Add-Toggle $ui.ListFx $Defs.FxAnim
Add-Choice $ui.ListFx $Defs.FxMenu
Add-Toggle $ui.ListFx $Defs.FxSnap
Add-Toggle $ui.ListFx $Defs.FxShake
Add-Section $ui.ListFx 'Maus'
Add-Choice $ui.ListFx $Defs.FxCursor
Add-Toggle $ui.ListFx $Defs.FxShadow
Add-Toggle $ui.ListFx $Defs.FxAccel
Add-Section $ui.ListFx 'Sound'
Add-Toggle $ui.ListFx $Defs.FxSounds

# --- Werbung ---
Add-Action $ui.ListAds ([string][char]0xEA18) 'Alles mit einem Klick deaktivieren' 'Schaltet alle Optionen unten auf einmal ab.' 'Alles aus' {
    $script:DeferSave = $true
    try { foreach ($ad in $AdDefs) { try { Apply-ToggleDef $ad $false } catch {} } } finally { $script:DeferSave = $false }
    After-Change $null
    Show-Toast 'Werbung & Tipps deaktiviert'
} 'BtnAccent'
Add-Section $ui.ListAds 'Einzeln einstellen'
foreach ($ad in $AdDefs) { Add-Toggle $ui.ListAds $ad }

# --- Backup ---
Add-Action $ui.ListBackup ([string][char]0xE777) 'Alles auf Original zurücksetzen' 'Stellt jeden Wert wieder her, den diese App jemals geändert hat.' 'Zurücksetzen' { Restore-All } 'BtnDanger'
Add-Action $ui.ListBackup ([string][char]0xE74E) 'Profil exportieren' 'Speichert deinen aktuellen Look als Datei - z. B. für einen zweiten PC oder Freunde.' 'Exportieren...' { Export-Profile } 'BtnAccent'
Add-Action $ui.ListBackup ([string][char]0xE8E5) 'Profil importieren' 'Lädt einen gespeicherten Look und wendet ihn an.' 'Importieren...' { Import-Profile }
Add-Action $ui.ListBackup ([string][char]0xE8B7) 'Backup-Ordner öffnen' 'Zeigt die Backup-Datei, Logs und erzeugte Hintergründe.' 'Öffnen' { Start-Process explorer.exe $AppDir }
Add-Action $ui.ListBackup ([string][char]0xE7F8) 'Desktop-Verknüpfung' 'Erstellt eine Verknüpfung "Win11 Customizer" auf deinem Desktop.' 'Erstellen' { New-DesktopShortcut }

# =====================================================================
#  Navigation & Fenster-Ereignisse
# =====================================================================
$NavMap = [ordered]@{
    NavHome = 'PageHome'; NavColors = 'PageColors'; NavTaskbar = 'PageTaskbar'; NavStart = 'PageStart'
    NavExplorer = 'PageExplorer'; NavTiles = 'PageTiles'; NavFx = 'PageFx'; NavAds = 'PageAds'; NavBackup = 'PageBackup'
}
function Show-Page([string]$name) {
    foreach ($pg in $NavMap.Values) { $ui[$pg].Visibility = 'Collapsed' }
    $page = $ui[$name]
    $page.Visibility = 'Visible'
    $page.ScrollToTop()
    $page.Opacity = 0
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation(1.0, (New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(200))))
    $page.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $a)
}
foreach ($k in $NavMap.Keys) {
    $ui[$k].add_Checked({ param($s, $e) Show-Page $NavMap[$s.Name] })
}
$ui.BtnGoColors.add_Click({ $ui.NavColors.IsChecked = $true })
$ui.BtnRandom.add_Click({ Apply-Preset ($Presets | Get-Random) })
$ui.BtnRestartSide.add_Click({ Restart-Explorer })
$ui.BtnRestartBanner.add_Click({ Restart-Explorer })

$ui.BtnMin.add_Click({ $window.WindowState = 'Minimized' })
$ui.BtnMax.add_Click({ if ($window.WindowState -eq 'Maximized') { $window.WindowState = 'Normal' } else { $window.WindowState = 'Maximized' } })
$ui.BtnClose.add_Click({ $window.Close() })
$window.add_StateChanged({
    if ($window.WindowState -eq 'Maximized') { $ui.Root.Margin = '7'; $ui.BtnMax.Content = [string][char]0xE923 }
    else { $ui.Root.Margin = '0'; $ui.BtnMax.Content = [string][char]0xE922 }
})
$window.add_SourceInitialized({
    try { [W11C.Native]::StyleWindow((New-Object System.Windows.Interop.WindowInteropHelper $window).Handle) } catch {}
})

# =====================================================================
#  Start
# =====================================================================
Load-Backup
$build = [Environment]::OSVersion.Version.Build
$ui.TxtBuild.Text = "$build"
$ui.TxtVersion.Text = "v$AppVersion  -  nur dein Benutzerkonto"
Refresh-All
try { if ((Get-TileConfig).Enabled) { Start-TileHost } } catch { Write-Log "Kacheln: $_" }
if ($env:W11C_EXE -and (Test-Path $env:W11C_EXE)) {
    try {
        $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($env:W11C_EXE)
        $window.Icon = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($ico.Handle, [System.Windows.Int32Rect]::Empty, [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
    } catch { Write-Log "Icon: $_" }
    try {
        # Autostart der Kacheln auf die .exe umstellen, falls noch der alte Pfad drinsteht
        $old = Get-Reg $RunKey 'Win11CustomizerTiles' $null
        if ($old -and $old -ne (Get-TileCommand)) { Set-Reg $RunKey 'Win11CustomizerTiles' (Get-TileCommand) 'String' }
    } catch { Write-Log "Autostart: $_" }
}
$window.add_ContentRendered({
    if ($build -lt 22000) { Show-Toast 'Hinweis: Diese App ist für Windows 11 gemacht - manches geht unter Windows 10 nicht.' -IsError }
})

$window.Dispatcher.add_UnhandledException({
    param($s, $e)
    $e.Handled = $true
    $ex = $e.Exception
    $pos = ''
    try { if ($ex.ErrorRecord) { $pos = $ex.ErrorRecord.InvocationInfo.PositionMessage } } catch {}
    Write-Log ("Fehler: {0}`n{1}`n{2}" -f $ex.Message, $pos, $ex.StackTrace)
    try { Show-Toast ('Fehler: ' + $ex.Message + ' (Details im error.log)') -IsError } catch {}
})

try {
    [void]$window.ShowDialog()
} catch {
    Write-Log "Absturz: $_"
    [System.Windows.MessageBox]::Show("Unerwarteter Fehler:`n$($_.Exception.Message)`n`nDetails: $LogFile", 'Win11 Customizer', 'OK', 'Error') | Out-Null
}
