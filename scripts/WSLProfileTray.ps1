#requires -Version 5.1
<#
Creates a tray icon with menu items to switch WSL profiles quickly.
Right-click the tray icon to choose Desktop/Balanced/Dev. Left-click shows the menu.
The script calls Switch-WSLProfile.ps1 under the hood.

To run at login, create a shortcut to powershell.exe with arguments:
  -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%USERPROFILE%\.wslprofiles\scripts\WSLProfileTray.ps1"
and place it in shell:startup
#>

# Init logging to local tray.log and TEMP log as early as possible
try { $BaseDir = Split-Path -Parent $PSCommandPath } catch { $BaseDir = (Get-Location).Path }
# If compiled to EXE, prefer the executable directory for BaseDir
try {
  $exeSelf = [Environment]::GetCommandLineArgs()[0]
  if ($exeSelf -and (Test-Path -LiteralPath $exeSelf)) {
    $ext = [System.IO.Path]::GetExtension($exeSelf)
    if ($ext -and $ext.ToLower() -eq '.exe') {
      $BaseDir = Split-Path -Parent $exeSelf
    }
  }
}
catch {}
$LocalLog = Join-Path $BaseDir 'tray.log'
function Log([string]$m) {
  $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  $line = "[$ts][TRAY] $m"
  try { Add-Content -Path $LocalLog -Value $line } catch {}
  try { Add-Content -Path (Join-Path $env:TEMP 'WSLProfileSwitcher.log') -Value $line } catch {}
}

if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
  Log 'Not STA; relaunching in STA (prefer pwsh)'
  $args = @('-NoLogo', '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "$PSCommandPath")

  $launched = $false
  try {
    $ps7 = $null
    try { $ps7 = Get-Command -Name 'pwsh' -ErrorAction SilentlyContinue } catch {}
    if ($ps7) {
      try {
        Start-Process -FilePath $ps7.Source -ArgumentList $args -WindowStyle Hidden | Out-Null
        $launched = $true
        Log ("Spawned pwsh: " + $ps7.Source)
      }
      catch {
        Log ("Failed to spawn pwsh: " + $_.Exception.Message)
      }
    }
    if (-not $launched) {
      try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $args -WindowStyle Hidden | Out-Null
        $launched = $true
        Log 'Spawned Windows PowerShell as fallback'
      }
      catch {
        Log ("Failed to spawn Windows PowerShell: " + $_.Exception.Message)
        try { Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.MessageBox]::Show("Start fehlgeschlagen: $($_.Exception.Message)", 'WSL Profile Switcher', 'OK', 'Error') | Out-Null } catch {}
      }
    }
  }
  catch {
    Log ("Unexpected error during STA relaunch: " + $_.Exception.Message)
  }
  exit
}

try {
  Log 'STA confirmed; initializing tray'

  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  # WPF imaging (for robust ICO decoding incl. PNG-encoded frames)
  try { Add-Type -AssemblyName PresentationCore, WindowsBase } catch { Log ('WPF imaging not available: ' + $_.Exception.Message) }
  # P/Invoke to destroy icon handles (avoid leaking HICONs)
  $sig = @'
using System;
using System.Runtime.InteropServices;
public static class NativeMethods {
  [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
  public static extern bool DestroyIcon(IntPtr hIcon);
}
'@
  Add-Type -TypeDefinition $sig -Language CSharp

  # Hotkey support: hidden form capturing WM_HOTKEY and user32 RegisterHotKey
  $hotkeyCs = @'
using System;
using System.Windows.Forms;
using System.Runtime.InteropServices;

public static class HotkeyNative {
  public const int WM_HOTKEY = 0x0312;
  public const uint MOD_ALT = 0x0001;
  public const uint MOD_CONTROL = 0x0002;
  public const uint MOD_SHIFT = 0x0004;
  public const uint MOD_WIN = 0x0008;
  [DllImport("user32.dll", SetLastError = true)]
  public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
  [DllImport("user32.dll", SetLastError = true)]
  public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
}

public class HotkeyForm : Form {
  public int LastId { get; private set; }
  public event EventHandler HotkeyPressed;
  protected override void WndProc(ref Message m) {
    if (m.Msg == HotkeyNative.WM_HOTKEY) {
      this.LastId = m.WParam.ToInt32();
      var h = HotkeyPressed; if (h != null) h(this, EventArgs.Empty);
    }
    base.WndProc(ref m);
  }
}
'@
  try {
    $refs = @()
    $formsAsm = [System.Windows.Forms.Form].Assembly
    if ($formsAsm -and $formsAsm.Location) { $refs += $formsAsm.Location }
    foreach ($name in @('System.Windows.Forms.Primitives', 'System.ComponentModel.Primitives', 'System.ComponentModel.TypeConverter', 'System.Drawing', 'System.Drawing.Primitives')) {
      try { $a = [System.Reflection.Assembly]::Load($name); if ($a -and $a.Location) { $refs += $a.Location } } catch {}
    }
    $refs = $refs | Where-Object { $_ -and $_ -ne '' } | Select-Object -Unique
    Add-Type -TypeDefinition $hotkeyCs -Language CSharp -ReferencedAssemblies $refs
  }
  catch { Log ("Hotkey Add-Type failed: " + $_.Exception.Message) }

  # Detect Windows app theme (dark/light)
  function Get-IsDarkMode {
    try {
      $key = 'HKCU:Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
      $val = (Get-ItemProperty -Path $key -Name AppsUseLightTheme -ErrorAction SilentlyContinue).AppsUseLightTheme
      if ($null -eq $val) { return $false }
      return ([int]$val) -eq 0
    }
    catch { return $false }
  }

  # Map internal profile keys to friendly display names
  function Get-FriendlyName([string]$key) {
    switch ($key) {
      'dev' { return 'Dev Extreme' }
      'balanced' { return 'Balanced' }
      'desktop' { return 'Meeting' }
      default { return $key }
    }
  }

  # Minimal Windows-like calm renderer (dark/light aware) – C#5 compatible
  $rendererSrc = @'
using System;
using System.Drawing;
using System.Windows.Forms;
using System.Drawing.Drawing2D;

public sealed class CalmColorTable : ProfessionalColorTable {
  private readonly bool _dark;
  public CalmColorTable(bool dark) { this._dark = dark; this.UseSystemColors = false; }
  private Color C(int a,int r,int g,int b) { return Color.FromArgb(a,r,g,b); }
  public bool IsDark { get { return _dark; } }
  public override Color ToolStripDropDownBackground { get { return _dark ? C(255,32,32,32) : C(255,250,250,250); } }
  public override Color ImageMarginGradientBegin { get { return this.ToolStripDropDownBackground; } }
  public override Color ImageMarginGradientMiddle { get { return this.ToolStripDropDownBackground; } }
  public override Color ImageMarginGradientEnd { get { return this.ToolStripDropDownBackground; } }
  public override Color MenuBorder { get { return _dark ? C(255,55,55,55) : C(255,230,230,230); } }
  // Make the hover border effectively invisible for a calmer look
  public override Color MenuItemBorder { get { return C(0,0,0,0); } }
  // No hover/selection fill difference (exactly the background)
  public override Color MenuItemSelected { get { return this.ToolStripDropDownBackground; } }
  public override Color MenuItemSelectedGradientBegin { get { return this.MenuItemSelected; } }
  public override Color MenuItemSelectedGradientEnd { get { return this.MenuItemSelected; } }
  // No pressed state difference either
  public override Color MenuItemPressedGradientBegin { get { return this.ToolStripDropDownBackground; } }
  public override Color MenuItemPressedGradientEnd { get { return this.ToolStripDropDownBackground; } }
  public override Color SeparatorDark { get { return _dark ? C(255,70,70,70) : C(255,224,224,224); } }
  public override Color SeparatorLight { get { return this.SeparatorDark; } }
}

public sealed class CalmRenderer : ToolStripProfessionalRenderer {
  public CalmRenderer(ProfessionalColorTable table) : base(table) { }
  private GraphicsPath MakeRoundRect(Rectangle r, int radius) {
    int d = radius * 2;
    GraphicsPath p = new GraphicsPath();
    p.AddArc(r.X, r.Y, d, d, 180, 90);
    p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
    p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
    p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
    p.CloseFigure();
    return p;
  }
  protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs e) {
    // Flat background for the whole menu
    Color bg = this.ColorTable.ToolStripDropDownBackground;
    using (SolidBrush b = new SolidBrush(bg)) {
      e.Graphics.FillRectangle(b, e.AffectedBounds);
    }
  }
  protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e) {
    // Base flat background
    Color bg = this.ColorTable.ToolStripDropDownBackground;
    using (SolidBrush b = new SolidBrush(bg)) {
      e.Graphics.FillRectangle(b, e.Item.Bounds);
    }
    // Subtle, native-like rounded hover/pressed
    if (e.Item.Selected || e.Item.Pressed) {
      bool dark = false;
      CalmColorTable t = this.ColorTable as CalmColorTable;
      if (t != null) { dark = t.IsDark; }
      Color fill = dark ? Color.FromArgb(255, 48, 48, 48) : Color.FromArgb(255, 235, 235, 235);
      Color border = dark ? Color.FromArgb(255, 64, 64, 64) : Color.FromArgb(255, 220, 220, 220);
      Rectangle r = new Rectangle(e.Item.Bounds.X + 6, e.Item.Bounds.Y + 3, e.Item.Bounds.Width - 12, e.Item.Bounds.Height - 6);
      using (GraphicsPath gp = MakeRoundRect(r, 6)) {
        SmoothingMode prev = e.Graphics.SmoothingMode;
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using (SolidBrush sb = new SolidBrush(fill)) { e.Graphics.FillPath(sb, gp); }
        using (Pen pen = new Pen(border)) { e.Graphics.DrawPath(pen, gp); }
        e.Graphics.SmoothingMode = prev;
      }
    }
    // Do NOT call base to avoid default highlight rendering
  }
  protected override void OnRenderImageMargin(ToolStripRenderEventArgs e) {
    // Keep image margin identical to background
    Color bg = this.ColorTable.ToolStripDropDownBackground;
    using (SolidBrush b = new SolidBrush(bg)) {
      e.Graphics.FillRectangle(b, e.AffectedBounds);
    }
  }
  protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e) {
    bool dark = false;
    CalmColorTable t = this.ColorTable as CalmColorTable;
    if (t != null) { dark = t.IsDark; }
    e.TextColor = dark ? Color.White : Color.Black;
    base.OnRenderItemText(e);
  }
}
'@
  # Ensure the C# compiler sees WinForms/Drawing by referencing their assemblies explicitly
  try {
    $formsAsm = [System.Windows.Forms.ToolStripProfessionalRenderer].Assembly.Location
    $drawingAsm = [System.Drawing.Bitmap].Assembly.Location
    $colorAsm = [System.Drawing.Color].Assembly.Location
    $refs = @($formsAsm, $drawingAsm, $colorAsm) | Where-Object { $_ -and $_ -ne '' } | Select-Object -Unique
    Add-Type -TypeDefinition $rendererSrc -Language CSharp -ReferencedAssemblies $refs
  }
  catch {
    Log ("Renderer Add-Type failed: " + $_.Exception.Message)
    # Continue without custom renderer; we'll fall back to default rendering below
  }

  # Create nicer rounded icons and menu images at runtime (PS 5.1 compatible)
  $script:IconCache = @{}
  $script:MenuImageCache = @{}
  # Only use the local scripts\icons folder
  $script:IconsDir = Join-Path $BaseDir 'icons'

  # Settings persistence (hotkeys on/off)
  $script:SettingsDir = Join-Path $env:APPDATA 'WSLProfileTray'
  $script:SettingsPath = Join-Path $script:SettingsDir 'settings.json'
  $script:HotkeysEnabled = $true
  # Per-action hotkey flags (default all on)
  $script:HotkeyFlags = @{ OpenMenu = $true; Dev = $true; Balanced = $true; Desktop = $true }
  $script:Profiles = @{
    dev      = @{ processors = 8; memoryGB = 22 }
    balanced = @{ processors = 4; memoryGB = 16 }
    desktop  = @{ processors = 2; memoryGB = 8 }
  }

  function Load-Settings {
    try {
      if (Test-Path -LiteralPath $script:SettingsPath) {
        $obj = Get-Content -LiteralPath $script:SettingsPath -Raw | ConvertFrom-Json -ErrorAction Stop
        if ($null -ne $obj.HotkeysEnabled) { $script:HotkeysEnabled = [bool]$obj.HotkeysEnabled }
        if ($null -ne $obj.HotkeyFlags) {
          foreach ($k in @('OpenMenu', 'Dev', 'Balanced', 'Desktop')) { if ($null -ne $obj.HotkeyFlags.$k) { $script:HotkeyFlags[$k] = [bool]$obj.HotkeyFlags.$k } }
        }
        else {
          # Back-compat: mirror master switch if individual flags absent
          $script:HotkeyFlags = @{ OpenMenu = $script:HotkeysEnabled; Dev = $script:HotkeysEnabled; Balanced = $script:HotkeysEnabled; Desktop = $script:HotkeysEnabled }
        }
        if ($null -ne $obj.Profiles) {
          foreach ($k in @('dev', 'balanced', 'desktop')) {
            if ($obj.Profiles.$k) {
              if ($obj.Profiles.$k.processors) { $script:Profiles[$k].processors = [int]$obj.Profiles.$k.processors }
              if ($obj.Profiles.$k.memoryGB) { $script:Profiles[$k].memoryGB = [int]$obj.Profiles.$k.memoryGB }
            }
          }
        }
      }
    }
    catch { Log ("Load-Settings failed: " + $_.Exception.Message) }
  }
  function Save-Settings {
    try {
      if (-not (Test-Path -LiteralPath $script:SettingsDir)) { New-Item -ItemType Directory -Force -Path $script:SettingsDir | Out-Null }
      $out = [ordered]@{ HotkeysEnabled = $script:HotkeysEnabled; HotkeyFlags = $script:HotkeyFlags; Profiles = $script:Profiles }
      $out | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $script:SettingsPath -Encoding UTF8
    }
    catch { Log ("Save-Settings failed: " + $_.Exception.Message) }
  }

  function Update-ProfileFile([string]$name, [int]$procs, [int]$memGB) {
    try {
      $dir = Join-Path $env:USERPROFILE '.wslprofiles'
      if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
      $path = Join-Path $dir ("$name.wslconfig")
      $lines = @()
      if (Test-Path -LiteralPath $path) { $lines = Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue -Encoding UTF8 -TotalCount 100000 -ReadCount 0 -Delimiter "`0" -OutVariable dummy; $lines = (Get-Content -LiteralPath $path) }
      if (-not $lines -or $lines.Count -eq 0) { $lines = @('[wsl2]') }
      # Ensure [wsl2] section exists
      if (-not ($lines | Where-Object { $_ -match '^\s*\[wsl2\]\s*$' })) { $lines = @('[wsl2]') + $lines }
      $inSec = $false
      for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($l -match '^\s*\[') { $inSec = ($l -match '^\s*\[wsl2\]\s*$') }
        if ($inSec -and $l -match '^\s*processors\s*=') { $lines[$i] = "processors=$procs" }
        if ($inSec -and $l -match '^\s*memory\s*=') { $lines[$i] = "memory=${memGB}GB" }
      }
      # Add keys if missing
      if (-not ($lines | Where-Object { $_ -match '^\s*processors\s*=' })) {
        $idx = [Array]::IndexOf($lines, ($lines | Where-Object { $_ -match '^\s*\[wsl2\]\s*$' } | Select-Object -First 1))
        if ($idx -ge 0) { $lines = $lines[0..$idx] + @("processors=$procs", "memory=${memGB}GB") + $lines[($idx + 1)..($lines.Count - 1)] }
      }
      elseif (-not ($lines | Where-Object { $_ -match '^\s*memory\s*=' })) {
        # processors exists but memory missing: insert after processors line
        $pidx = ($lines | ForEach-Object { $_ }) | ForEach-Object { $_ } | Select-Object -Index (($lines | ForEach-Object { $_ }) | ForEach-Object { $_ } | ForEach-Object { $_ })
      }
      # Simpler: ensure both keys present by appending if absent
      if (-not ($lines | Where-Object { $_ -match '^\s*processors\s*=' })) { $lines += "processors=$procs" }
      if (-not ($lines | Where-Object { $_ -match '^\s*memory\s*=' })) { $lines += "memory=${memGB}GB" }
      Set-Content -LiteralPath $path -Value $lines -Encoding UTF8
      return $true
    }
    catch {
      # Use -f formatting to avoid "$name:" being parsed as a scoped variable reference
      Log ("Update-ProfileFile failed for {0}: {1}" -f $name, $_.Exception.Message)
      return $false
    }
  }

  function Write-ProfileFiles {
    try {
      foreach ($k in @('dev', 'balanced', 'desktop')) {
        $cfg = $script:Profiles[$k]
        if (-not $cfg) { continue }
        [void](Update-ProfileFile -name $k -procs ([int]$cfg.processors) -memGB ([int]$cfg.memoryGB))
      }
      Log 'Profile files updated from settings'
    }
    catch { Log ("Write-ProfileFiles failed: " + $_.Exception.Message) }
  }

  # --- Startup link helpers (Start with Windows toggle) ---
  function Get-StartupLinkPath {
    $startup = [Environment]::GetFolderPath('Startup')
    return (Join-Path $startup 'WSL Profile Switcher.lnk')
  }

  function Get-LaunchTarget {
    # Prefer compiled EXE if running compiled
    try {
      $self = [Environment]::GetCommandLineArgs()[0]
      if ($self -and (Test-Path -LiteralPath $self) -and ([IO.Path]::GetFileName($self) -ieq 'WSLProfileTray.exe')) {
        return @{ Path = $self; Args = '' }
      }
    }
    catch {}
    # Otherwise prefer VBS launcher if present (windowless)
    try {
      $vbs = Join-Path $BaseDir 'Start-WSLProfileTray.vbs'
      if (Test-Path -LiteralPath $vbs) { return @{ Path = $vbs; Args = '' } }
    }
    catch {}
    # Fallback: PowerShell script
    $ps = $null
    try { $ps = (Get-Command -Name 'pwsh' -ErrorAction SilentlyContinue).Source } catch {}
    if (-not $ps) { $ps = 'powershell.exe' }
    $args = "-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    return @{ Path = $ps; Args = $args }
  }

  function Is-StartupEnabled {
    return (Test-Path -LiteralPath (Get-StartupLinkPath))
  }

  function Set-Startup([bool]$enable) {
    $lnkPath = Get-StartupLinkPath
    if ($enable) {
      try {
        $t = Get-LaunchTarget
        $wsh = New-Object -ComObject WScript.Shell
        $lnk = $wsh.CreateShortcut($lnkPath)
        $lnk.TargetPath = $t.Path
        if ($t.Args) { $lnk.Arguments = $t.Args }
        try { $lnk.WorkingDirectory = (Split-Path -Parent $t.Path) } catch {}
        try { $lnk.IconLocation = $t.Path } catch {}
        $lnk.Save()
        return $true
      }
      catch {
        Log ("Failed to create startup link: " + $_.Exception.Message)
        return $false
      }
    }
    else {
      try {
        if (Test-Path -LiteralPath $lnkPath) { Remove-Item -LiteralPath $lnkPath -Force }
        return $true
      }
      catch {
        Log ("Failed to remove startup link: " + $_.Exception.Message)
        return $false
      }
    }
  }

  $script:LoggedIconSearch = $false
  function New-IconFromBitmap([System.Drawing.Bitmap]$bmp, [bool]$active) {
    # Optionally draw an active border, then convert bitmap to an Icon
    try {
      if ($active) {
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), ([single]1.5)
        $rectF = New-Object System.Drawing.RectangleF ([single]0.5), ([single]0.5), ([single]15), ([single]15)
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $radius = [single]2.5; $diam = [single]($radius * 2)
        $arc = New-Object System.Drawing.RectangleF $rectF.X, $rectF.Y, $diam, $diam
        $path.AddArc($arc, 180, 90); $arc.X = $rectF.Right - $diam; $arc.Y = $rectF.Y; $path.AddArc($arc, 270, 90)
        $arc.X = $rectF.Right - $diam; $arc.Y = $rectF.Bottom - $diam; $path.AddArc($arc, 0, 90)
        $arc.X = $rectF.X; $arc.Y = $rectF.Bottom - $diam; $path.AddArc($arc, 90, 90); $path.CloseFigure()
        $g.DrawPath($pen, $path); $pen.Dispose(); $path.Dispose(); $g.Dispose()
      }
      $h = $bmp.GetHicon(); $icon = [System.Drawing.Icon]::FromHandle($h); $managed = $icon.Clone(); [NativeMethods]::DestroyIcon($h) | Out-Null
      return $managed
    }
    catch { return $null }
  }

  function Try-DecodeIconViaWpf([string]$path, [bool]$active) {
    try {
      if (-not ("PresentationCore" -in [AppDomain]::CurrentDomain.GetAssemblies().GetName().Name)) { return $null }
      $uri = New-Object System.Uri ($path)
      $decoder = New-Object System.Windows.Media.Imaging.IconBitmapDecoder ($uri, [System.Windows.Media.Imaging.BitmapCreateOptions]::None, [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
      if (-not $decoder -or $decoder.Frames.Count -eq 0) { return $null }
      $target = 16
      $best = $null; $bestDiff = [int]::MaxValue
      foreach ($f in $decoder.Frames) {
        $w = [int]$f.PixelWidth; $h = [int]$f.PixelHeight; $d = [Math]::Abs($w - $target) + [Math]::Abs($h - $target)
        if ($d -lt $bestDiff) { $best = $f; $bestDiff = $d }
        if ($w -eq 16 -and $h -eq 16) { $best = $f; break }
      }
      if (-not $best) { $best = $decoder.Frames[0] }
      $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
      $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($best))
      $ms = New-Object System.IO.MemoryStream
      $enc.Save($ms); $ms.Position = 0
      $bmp = [System.Drawing.Bitmap]::FromStream($ms)
      return (New-IconFromBitmap -bmp $bmp -active $active)
    }
    catch { try { Log ('WPF ICO decode failed: ' + $_.Exception.Message) } catch {}; return $null }
  }
  function Try-LoadCustomIcon([string]$profile, [bool]$active) {
    try {
      if (-not (Test-Path -LiteralPath $script:IconsDir)) { return $null }
      # Allow a nested icons/icons folder in case packaging copied the directory itself
      $altIconsDir = Join-Path $script:IconsDir 'icons'
      $searchDirs = @($script:IconsDir)
      if (Test-Path -LiteralPath $altIconsDir) { $searchDirs += $altIconsDir }
      $candidates = @()
      foreach ($dir in $searchDirs) {
        if ($active) { $candidates += (Join-Path $dir ("$profile-active.ico")) }
        $candidates += (Join-Path $dir ("$profile.ico"))
      }
      if (-not $script:LoggedIconSearch) {
        $script:LoggedIconSearch = $true
        try { Log ("Icon search dirs: " + ($searchDirs -join ', ')) } catch {}
      }
      foreach ($f in $candidates) {
        if (Test-Path -LiteralPath $f) {
          try {
            # Prefer direct resize; some ICOs contain multiple sizes
            $raw = New-Object System.Drawing.Icon $f
            try {
              $resized = New-Object System.Drawing.Icon ($raw, (New-Object System.Drawing.Size 16, 16))
              if ($active -and -not ($f.ToLower().EndsWith('-active.ico'))) {
                # Draw subtle active border onto a bitmap and convert to icon
                $bmp = New-Object System.Drawing.Bitmap 16, 16
                $g = [System.Drawing.Graphics]::FromImage($bmp)
                $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
                $g.Clear([System.Drawing.Color]::Transparent)
                $g.DrawIcon($resized, (New-Object System.Drawing.Rectangle 0, 0, 16, 16))
                $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), ([single]1.5)
                $rectF = New-Object System.Drawing.RectangleF ([single]0.5), ([single]0.5), ([single]15), ([single]15)
                $path = New-Object System.Drawing.Drawing2D.GraphicsPath
                $radius = [single]2.5
                $diam = [single]($radius * 2)
                $arc = New-Object System.Drawing.RectangleF $rectF.X, $rectF.Y, $diam, $diam
                $path.AddArc($arc, 180, 90)
                $arc.X = $rectF.Right - $diam; $arc.Y = $rectF.Y; $path.AddArc($arc, 270, 90)
                $arc.X = $rectF.Right - $diam; $arc.Y = $rectF.Bottom - $diam; $path.AddArc($arc, 0, 90)
                $arc.X = $rectF.X; $arc.Y = $rectF.Bottom - $diam; $path.AddArc($arc, 90, 90)
                $path.CloseFigure(); $g.DrawPath($pen, $path)
                $pen.Dispose(); $path.Dispose(); $g.Dispose()
                $h = $bmp.GetHicon(); $icon = [System.Drawing.Icon]::FromHandle($h); $managed = $icon.Clone(); [NativeMethods]::DestroyIcon($h) | Out-Null
                try { Log ("Loaded custom icon: " + $f + " (WPF border)") } catch {}
                return $managed
              }
              else {
                try { Log ("Loaded custom icon: " + $f + " (resized)") } catch {}
                return $resized
              }
            }
            catch {
              # Fallback: rasterize icon to 16x16 and convert back to an Icon
              $bmp = New-Object System.Drawing.Bitmap 16, 16
              $g = [System.Drawing.Graphics]::FromImage($bmp)
              $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
              $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
              $g.Clear([System.Drawing.Color]::Transparent)
              $g.DrawIcon($raw, (New-Object System.Drawing.Rectangle 0, 0, 16, 16))
              if ($active -and -not ($f.ToLower().EndsWith('-active.ico'))) {
                $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), ([single]1.5)
                $rectF = New-Object System.Drawing.RectangleF ([single]0.5), ([single]0.5), ([single]15), ([single]15)
                $path = New-Object System.Drawing.Drawing2D.GraphicsPath
                $radius = [single]2.5; $diam = [single]($radius * 2)
                $arc = New-Object System.Drawing.RectangleF $rectF.X, $rectF.Y, $diam, $diam
                $path.AddArc($arc, 180, 90); $arc.X = $rectF.Right - $diam; $arc.Y = $rectF.Y; $path.AddArc($arc, 270, 90)
                $arc.X = $rectF.Right - $diam; $arc.Y = $rectF.Bottom - $diam; $path.AddArc($arc, 0, 90)
                $arc.X = $rectF.X; $arc.Y = $rectF.Bottom - $diam; $path.AddArc($arc, 90, 90); $path.CloseFigure()
                $g.DrawPath($pen, $path); $pen.Dispose(); $path.Dispose()
              }
              $g.Dispose(); $h = $bmp.GetHicon(); $icon = [System.Drawing.Icon]::FromHandle($h); $managed = $icon.Clone(); [NativeMethods]::DestroyIcon($h) | Out-Null
              try { Log ("Loaded custom icon: " + $f + " (rasterized)") } catch {}
              return $managed
            }
          }
          catch {
            # GDI path failed, try robust WPF decoder
            $ico = Try-DecodeIconViaWpf -path $f -active $active
            if ($ico) { try { Log ("Loaded custom icon: " + $f + " (WPF decode)") } catch {}; return $ico }
            try { Log ("Icon load failed for '" + $f + "': " + $_.Exception.Message) } catch {}
          }
        }
      }
      return $null
    }
    catch { try { Log ("Try-LoadCustomIcon error: " + $_.Exception.Message) } catch {}; return $null }
  }

  function New-RoundedBitmap([System.Drawing.Color]$bg, [string]$label, [bool]$active) {
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit

    # Rounded rect background
    $radius = [single]3
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $rect = New-Object System.Drawing.RectangleF ([single]0.5), ([single]0.5), ([single]15), ([single]15)
    # Build rounded rectangle path
    $diam = [single]($radius * 2)
    $arc = New-Object System.Drawing.RectangleF $rect.X, $rect.Y, $diam, $diam
    $path.AddArc($arc, 180, 90)
    $arc.X = $rect.Right - $diam; $arc.Y = $rect.Y
    $path.AddArc($arc, 270, 90)
    $arc.X = $rect.Right - $diam; $arc.Y = $rect.Bottom - $diam
    $path.AddArc($arc, 0, 90)
    $arc.X = $rect.X; $arc.Y = $rect.Bottom - $diam
    $path.AddArc($arc, 90, 90)
    $path.CloseFigure()

    $bgBrush = New-Object System.Drawing.SolidBrush $bg
    $g.FillPath($bgBrush, $path)
    $bgBrush.Dispose()

    # Label
    $font = [System.Drawing.Font]::new('Segoe UI', [single]8.0, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Point)
    $sf = New-Object System.Drawing.StringFormat
    $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
    $textRect = New-Object System.Drawing.RectangleF ([single]0), ([single]-0.5), ([single]16), ([single]16)
    $white = [System.Drawing.Brushes]::White
    [void]$g.DrawString($label, $font, $white, $textRect, $sf)

    # Active highlight (subtle border)
    if ($active) {
      $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), ([single]1.5)
      $g.DrawPath($pen, $path)
      $pen.Dispose()
    }

    $g.Dispose(); $path.Dispose()
    return $bmp
  }

  function New-ProfileIcon([string]$key, [System.Drawing.Color]$bg, [string]$label, [bool]$active) {
    $bmp = New-RoundedBitmap $bg $label $active
    $hIcon = $bmp.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($hIcon)
    $managed = $icon.Clone()
    [NativeMethods]::DestroyIcon($hIcon) | Out-Null
    $script:IconCache[$key] = $managed
    return $managed
  }

  function Get-IconForProfile([string]$profile, [bool]$active = $false) {
    $k = if ($active) { "$profile-active" } else { $profile }
    if ($script:IconCache.ContainsKey($k)) { return $script:IconCache[$k] }
    # Try custom .ico files first
    $custom = Try-LoadCustomIcon $profile $active
    if ($custom) { $script:IconCache[$k] = $custom; return $custom }
    switch ($profile) {
      # Meeting => pink M
      'desktop' { return New-ProfileIcon $k ([System.Drawing.Color]::FromArgb(233, 30, 99)) 'M' $active }
      # Balanced => orange B
      'balanced' { return New-ProfileIcon $k ([System.Drawing.Color]::FromArgb(255, 140, 0)) 'B' $active }
      # Dev Extreme => black X (white text is already used)
      'dev' { return New-ProfileIcon $k ([System.Drawing.Color]::FromArgb(0, 0, 0)) 'X' $active }
      default { return [System.Drawing.SystemIcons]::Application }
    }
  }

  function Get-MenuImage([string]$profile, [bool]$active = $false) {
    $k = if ($active) { "$profile-active" } else { $profile }
    if ($script:MenuImageCache.ContainsKey($k)) { return $script:MenuImageCache[$k] }
    # Prefer custom icon rendered to 16x16 bitmap
    $custom = Try-LoadCustomIcon $profile $active
    if ($custom) {
      $bmp = New-Object System.Drawing.Bitmap 16, 16
      $g = [System.Drawing.Graphics]::FromImage($bmp)
      $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
      $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
      $g.Clear([System.Drawing.Color]::Transparent)
      $rectI = New-Object System.Drawing.Rectangle 0, 0, 16, 16
      $g.DrawIcon($custom, $rectI)
      $g.Dispose()
      $script:MenuImageCache[$k] = $bmp
      return $bmp
    }
    switch ($profile) {
      'desktop' { $bmp = New-RoundedBitmap ([System.Drawing.Color]::FromArgb(233, 30, 99)) 'M' $active }
      'balanced' { $bmp = New-RoundedBitmap ([System.Drawing.Color]::FromArgb(255, 140, 0)) 'B' $active }
      'dev' { $bmp = New-RoundedBitmap ([System.Drawing.Color]::FromArgb(0, 0, 0)) 'X' $active }
      default { $bmp = $null }
    }
    if ($bmp) { $script:MenuImageCache[$k] = $bmp }
    return $bmp
  }

  function Detect-ActiveProfile {
    try {
      $dst = Join-Path $env:USERPROFILE '.wslconfig'
      if (-not (Test-Path -LiteralPath $dst)) { return $null }
      $dstText = (Get-Content -LiteralPath $dst -Raw)
      $profiles = 'desktop', 'balanced', 'dev'
      foreach ($p in $profiles) {
        $src = Join-Path $env:USERPROFILE ".wslprofiles\$p.wslconfig"
        if (Test-Path -LiteralPath $src) {
          $srcText = (Get-Content -LiteralPath $src -Raw)
          if ($srcText -eq $dstText) { return $p }
        }
      }
      $cpu = if ($dstText -match '(?im)^\s*processors\s*=\s*(\d+)') { [int]$matches[1] } else { $null }
      $mem = if ($dstText -match '(?im)^\s*memory\s*=\s*([^\r\n]+)') { $matches[1].Trim() } else { $null }
      if ($cpu -eq 2 -and $mem -like '8GB*') { return 'desktop' }
      if ($cpu -eq 4 -and $mem -like '16GB*') { return 'balanced' }
      if ($cpu -eq 8 -and $mem -like '22GB*') { return 'dev' }
      return $null
    }
    catch { return $null }
  }

  $tray = New-Object System.Windows.Forms.NotifyIcon
  $tray.Text = 'WSL Profile Switcher'
  
  function Get-DefaultAppIcon {
    try {
      $icoDir = Join-Path $BaseDir 'icons'
      $icoPath = Join-Path $icoDir 'app.ico'
      if (Test-Path -LiteralPath $icoPath) {
        try {
          $ico = New-Object System.Drawing.Icon $icoPath
          # Prefer 16x16 for tray if multi-size exists
          try { return New-Object System.Drawing.Icon ($ico, (New-Object System.Drawing.Size 16, 16)) } catch { return $ico }
        } catch {}
      }
      # Fallback: extract icon from the EXE if available
      try {
        if ($exeSelf -and (Test-Path -LiteralPath $exeSelf)) {
          $exIco = [System.Drawing.Icon]::ExtractAssociatedIcon($exeSelf)
          if ($exIco) { return $exIco }
        }
      } catch {}
    } catch {}
    return [System.Drawing.SystemIcons]::Application
  }
  $current = Detect-ActiveProfile
  if ($current) {
    $tray.Icon = Get-IconForProfile $current $true
    $tray.Text = "WSL Profile: $(Get-FriendlyName $current)"
  }
  else {
    $tray.Icon = Get-DefaultAppIcon
  }
  $tray.Visible = $true

  # Show a small balloon on startup so the user notices it
  $tray.BalloonTipTitle = 'WSL Profile Switcher'
  $tray.BalloonTipText = 'Aktiv. Rechtsklick/Linksklick für Profile.'
  $tray.ShowBalloonTip(2000)

  $contextMenu = New-Object System.Windows.Forms.ContextMenuStrip
  $contextMenu.ShowImageMargin = $false
  $contextMenu.ShowCheckMargin = $true
  try {
    $isDark = Get-IsDarkMode
    $ct = New-Object CalmColorTable $isDark
    $calm = New-Object CalmRenderer $ct
    [System.Windows.Forms.ToolStripManager]::Renderer = $calm
    $contextMenu.Renderer = $calm
    $contextMenu.RenderMode = [System.Windows.Forms.ToolStripRenderMode]::Professional
    Log 'CalmRenderer applied'
  }
  catch {}
  try { $contextMenu.Font = [System.Drawing.Font]::new('Segoe UI', [single]9.0, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Point) } catch {}

  # --- Global Hotkeys registration ---
  Load-Settings
  $hotForm = $null
  $hotIds = @(1, 2, 3, 4)  # 1=open menu, 2=dev, 3=balanced, 4=desktop
  function Register-Hotkeys {
    if (-not $script:HotkeysEnabled) { return }
    try {
      $global:hotForm = New-Object HotkeyForm
      $global:hotForm.ShowInTaskbar = $false
      $global:hotForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
      $global:hotForm.Opacity = 0
      $global:hotForm.Width = 1; $global:hotForm.Height = 1
      # Force handle creation
      [void]$global:hotForm.Handle
      $mod = [uint32]([HotkeyNative]::MOD_CONTROL + [HotkeyNative]::MOD_ALT)
      # Register based on per-action flags
      if ($script:HotkeyFlags.OpenMenu) { [HotkeyNative]::RegisterHotKey($global:hotForm.Handle, 1, $mod, 0x50) | Out-Null }
      if ($script:HotkeyFlags.Dev) { [HotkeyNative]::RegisterHotKey($global:hotForm.Handle, 2, $mod, 0x44) | Out-Null }
      if ($script:HotkeyFlags.Balanced) { [HotkeyNative]::RegisterHotKey($global:hotForm.Handle, 3, $mod, 0x42) | Out-Null }
      if ($script:HotkeyFlags.Desktop) { [HotkeyNative]::RegisterHotKey($global:hotForm.Handle, 4, $mod, 0x4D) | Out-Null }
      $global:hotForm.add_HotkeyPressed({
          try {
            $id = $global:hotForm.LastId
            switch ($id) {
              1 { if ($script:HotkeyFlags.OpenMenu) { $pos = [System.Windows.Forms.Cursor]::Position; $contextMenu.Show($pos) } }
              2 { if ($script:HotkeyFlags.Dev) { Switch-Profile 'dev' } }
              3 { if ($script:HotkeyFlags.Balanced) { Switch-Profile 'balanced' } }
              4 { if ($script:HotkeyFlags.Desktop) { Switch-Profile 'desktop' } }
            }
          }
          catch { Log ("Hotkey handler failed: " + $_.Exception.Message) }
        })
      Log 'Global hotkeys registered'
    }
    catch { Log ("Register-Hotkeys failed: " + $_.Exception.Message) }
  }
  function Unregister-Hotkeys {
    try {
      if ($global:hotForm -and $global:hotForm.Handle -ne [IntPtr]::Zero) {
        foreach ($id in $hotIds) { try { [HotkeyNative]::UnregisterHotKey($global:hotForm.Handle, [int]$id) | Out-Null } catch {} }
      }
      if ($global:hotForm) { try { $global:hotForm.Close() } catch {}; try { $global:hotForm.Dispose() } catch {}; $global:hotForm = $null }
      Log 'Global hotkeys unregistered'
    }
    catch { Log ("Unregister-Hotkeys failed: " + $_.Exception.Message) }
  }
  if ($script:HotkeysEnabled) { Register-Hotkeys }

  function Update-Checked([string]$active) {
    foreach ($mi in $contextMenu.Items) {
      if ($mi -is [System.Windows.Forms.ToolStripMenuItem] -and $mi.Tag) {
        $mi.Checked = ($mi.Tag -eq $active)
      }
    }
  }

  function Format-Label([string]$title, [int]$p, [int]$m) {
    return ("{0} ({1}C/{2}G)" -f $title, $p, $m)
  }

  function Update-MenuLabels {
    try {
      if ($miDev) { $miDev.Text = '&' + (Format-Label 'Dev Extreme' $script:Profiles.dev.processors $script:Profiles.dev.memoryGB) }
      if ($miBalanced) { $miBalanced.Text = '&' + (Format-Label 'Balanced'    $script:Profiles.balanced.processors $script:Profiles.balanced.memoryGB) }
      if ($miDesktop) { $miDesktop.Text = '&' + (Format-Label 'Meeting'     $script:Profiles.desktop.processors $script:Profiles.desktop.memoryGB) }
    }
    catch { Log ("Update-MenuLabels failed: " + $_.Exception.Message) }
  }

  function Switch-Profile([string]$name) {
    try {
      Log ("Switch requested: " + $name)
      # Use relative path so the project can live anywhere (also works when packaged)
      $scriptPath = Join-Path $BaseDir 'Switch-WSLProfile.ps1'
      $exe = 'powershell.exe'
      try {
        $ps7 = Get-Command -Name 'pwsh' -ErrorAction SilentlyContinue
        if ($ps7) { $exe = $ps7.Source }
      }
      catch {}
      Start-Process -FilePath $exe -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "$scriptPath", '-Profile', "$name") -WindowStyle Hidden | Out-Null
      # Immediate feedback in tray and menu
      try { $tray.Icon = Get-IconForProfile $name $true } catch {}
      try { $tray.Text = "WSL Profile: $(Get-FriendlyName $name)" } catch {}
      try { Update-Checked $name } catch {}
    }
    catch {
      try { [System.Windows.Forms.MessageBox]::Show("Failed to start switch for '" + $name + "': $($_.Exception.Message)", 'WSL Profile Switcher', 'OK', 'Error') | Out-Null } catch {}
      Log ("Switch start failed: " + $_.Exception.Message)
    }
  }

  # Header (calm, bold, disabled)
  $miHeader = New-Object System.Windows.Forms.ToolStripMenuItem
  $miHeader.Text = 'WSL-Profile'
  $miHeader.Enabled = $false
  try { $miHeader.Font = [System.Drawing.Font]::new('Segoe UI Semibold', [single]9.0, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Point) } catch {}
  [void]$contextMenu.Items.Add($miHeader)
  [void]$contextMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

  # Create profile menu items with checkmarks (no images) in requested order
  $miDev = New-Object System.Windows.Forms.ToolStripMenuItem
  $miDev.Text = '&' + (Format-Label 'Dev Extreme' $script:Profiles.dev.processors $script:Profiles.dev.memoryGB)
  $miDev.Tag = 'dev'
  $miDev.add_Click({ Switch-Profile 'dev' })
  [void]$contextMenu.Items.Add($miDev)

  $miBalanced = New-Object System.Windows.Forms.ToolStripMenuItem
  $miBalanced.Text = '&' + (Format-Label 'Balanced' $script:Profiles.balanced.processors $script:Profiles.balanced.memoryGB)
  $miBalanced.Tag = 'balanced'
  $miBalanced.add_Click({ Switch-Profile 'balanced' })
  [void]$contextMenu.Items.Add($miBalanced)

  $miDesktop = New-Object System.Windows.Forms.ToolStripMenuItem
  $miDesktop.Text = '&' + (Format-Label 'Meeting' $script:Profiles.desktop.processors $script:Profiles.desktop.memoryGB)
  $miDesktop.Tag = 'desktop'
  $miDesktop.add_Click({ Switch-Profile 'desktop' })
  [void]$contextMenu.Items.Add($miDesktop)

  # Visual state for current profile
  try { Update-Checked $current } catch {}

  $contextMenu.Items.Add('-') | Out-Null
  # Settings dialog (Profiles + General: hotkeys and startup)
  $miSettings = New-Object System.Windows.Forms.ToolStripMenuItem
  $miSettings.Text = 'Settings…'
  $miSettings.add_Click({
      try {
        $dlg = New-Object System.Windows.Forms.Form
        $dlg.Text = 'WSL Profile Settings'
        $dlg.StartPosition = 'CenterScreen'
        $dlg.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        $dlg.MaximizeBox = $false
        $dlg.MinimizeBox = $false
        # DPI-aware scaling and readable font in a Ditto-like layout
        $dlg.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
        try { $dlg.AutoScaleDimensions = New-Object System.Drawing.SizeF 96, 96 } catch {}
        # Balanced base font similar to Ditto, but a bit larger for readability
        try { $dlg.Font = [System.Drawing.Font]::new('Segoe UI', [single]12.0) } catch {}
        # Make the dialog taller so the General tab doesn't require scrolling
        $dlg.ClientSize = New-Object System.Drawing.Size 800, 660
        try { $dlg.MinimumSize = New-Object System.Drawing.Size 760, 640 } catch {}

        # Bottom button area (robust layout): right-docked FlowLayoutPanel
        $btnPanel = New-Object System.Windows.Forms.FlowLayoutPanel
        $btnPanel.Dock = 'Bottom'
        # Slightly shorter button bar to free a bit more vertical space
        $btnPanel.Height = 72
        $btnPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::RightToLeft
        $btnPanel.WrapContents = $false
        $btnPanel.Padding = (New-Object System.Windows.Forms.Padding 0, 10, 10, 10)
        try { $btnPanel.BackColor = [System.Drawing.SystemColors]::Window } catch {}
        $dlg.Controls.Add($btnPanel)

        $btnOK = New-Object System.Windows.Forms.Button; $btnOK.Text = 'OK'; $btnOK.Width = 120; $btnOK.Height = 44; $btnOK.DialogResult = 'OK'
        $btnCancel = New-Object System.Windows.Forms.Button; $btnCancel.Text = 'Cancel'; $btnCancel.Width = 120; $btnCancel.Height = 44; $btnCancel.DialogResult = 'Cancel'
        $btnPanel.Controls.Add($btnCancel)
        $btnPanel.Controls.Add($btnOK)
        $dlg.AcceptButton = $btnOK; $dlg.CancelButton = $btnCancel

        $tabs = New-Object System.Windows.Forms.TabControl
        $tabs.Dock = 'Fill'
        # Larger, wider tab headers and larger tab font
        $tabs.SizeMode = [System.Windows.Forms.TabSizeMode]::Fixed
        try { $tabs.ItemSize = New-Object System.Drawing.Size 160, 48 } catch {}
        # Reduce vertical padding so the tab label sits closer to the top
        try { $tabs.Padding = New-Object System.Drawing.Point 22, 5 } catch {}
        try { $tabs.Font = [System.Drawing.Font]::new('Segoe UI', [single]14.0) } catch {}
        # Ensure header background exactly matches page background by custom drawing
        try {
          $tabs.DrawMode = [System.Windows.Forms.TabDrawMode]::OwnerDrawFixed
          $tabs.add_DrawItem({ param($sender, $e)
              try {
                $g = $e.Graphics
                $isSelected = ($sender.SelectedIndex -eq $e.Index)
                $rect = $e.Bounds
                # Colors: selected uses Window (lighter tone), others use Control
                $bg = if ($isSelected) { [System.Drawing.SystemColors]::Window } else { [System.Drawing.SystemColors]::Control }
                $fg = [System.Drawing.SystemColors]::ControlText
                $b = New-Object System.Drawing.SolidBrush $bg
                $g.FillRectangle($b, $rect)
                $b.Dispose()
                # Optional subtle border
                $pen = New-Object System.Drawing.Pen ([System.Drawing.SystemColors]::ActiveBorder)
                $g.DrawRectangle($pen, $rect)
                $pen.Dispose()
                # Draw centered text
                $tab = $sender.TabPages[$e.Index]
                [System.Windows.Forms.TextRenderer]::DrawText($g, $tab.Text, $sender.Font, $rect, $fg,
                  [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::SingleLine)
                $e.DrawFocusRectangle()
              }
              catch {}
            })
        }
        catch {}
        $dlg.Controls.Add($tabs)

        # Tab 1: Profiles (table with three rows)
        $tabProfiles = New-Object System.Windows.Forms.TabPage
        try { $tabProfiles.UseVisualStyleBackColor = $false; $tabProfiles.BackColor = [System.Drawing.SystemColors]::Window } catch {}
        try { $tabProfiles.Padding = New-Object System.Windows.Forms.Padding 8, 10, 8, 12 } catch {}
        $tabProfiles.Text = 'Profiles'
        # Profiles container: plain Panel (no headline as requested)
        $grpProfiles = New-Object System.Windows.Forms.Panel
        $grpProfiles.Dock = 'Top'
        $grpProfiles.AutoSize = $true
        $grpProfiles.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
        $grpProfiles.Padding = (New-Object System.Windows.Forms.Padding 16)
        try { $grpProfiles.BackColor = [System.Drawing.SystemColors]::Window } catch {}

        $tbl = New-Object System.Windows.Forms.TableLayoutPanel
        $tbl.Dock = 'Top'
        $tbl.AutoSize = $true
        $tbl.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
        $tbl.Padding = (New-Object System.Windows.Forms.Padding 0)
        $tbl.Margin = (New-Object System.Windows.Forms.Padding 8)
        try { $tbl.BackColor = [System.Drawing.SystemColors]::Window } catch {}
        $tbl.ColumnCount = 3
        # Column 0 autosizes to the longest profile name; numeric columns are fixed for alignment
        # Columns sized to keep content within dialog width even with padding
        [void]$tbl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 260)))  # Profile names
        [void]$tbl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 210)))  # CPU
        [void]$tbl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 210)))  # Memory
        $tbl.RowCount = 4
        foreach ($p in 0..3) { [void]$tbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) }

        # Headers (slightly larger)
        $h1 = New-Object System.Windows.Forms.Label; $h1.Text = 'Profile'; $h1.AutoSize = $true; $h1.Margin = (New-Object System.Windows.Forms.Padding 0, 0, 8, 8); $h1.Font = [System.Drawing.Font]::new('Segoe UI Semibold', [single]16.0)
        $h2 = New-Object System.Windows.Forms.Label; $h2.Text = 'CPU'; $h2.AutoSize = $true; $h2.Margin = (New-Object System.Windows.Forms.Padding 0, 0, 8, 8); $h2.Font = [System.Drawing.Font]::new('Segoe UI Semibold', [single]16.0)
        $h3 = New-Object System.Windows.Forms.Label; $h3.Text = 'Memory (GB)'; $h3.AutoSize = $true; $h3.Margin = (New-Object System.Windows.Forms.Padding 0, 0, 8, 8); $h3.Font = [System.Drawing.Font]::new('Segoe UI Semibold', [single]16.0)
        $tbl.Controls.Add($h1, 0, 0); $tbl.Controls.Add($h2, 1, 0); $tbl.Controls.Add($h3, 2, 0)

        function New-Num([int]$min, [int]$max, [int]$val) {
          $n = New-Object System.Windows.Forms.NumericUpDown
          $n.AutoSize = $false
          $n.Minimum = [decimal]$min
          $n.Maximum = [decimal]$max
          $n.Value   = [decimal]$val
          # Taller but not overly wide; keep within new column widths
          $n.Width   = 210
          $n.Height  = 60
          try { $n.TextAlign = [System.Windows.Forms.HorizontalAlignment]::Right } catch {}
          try { $n.Font = [System.Drawing.Font]::new('Segoe UI', [single]18.0) } catch {}
          try { $n.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle } catch {}
          # Ensure the inner edit and spinner resize with the control height
          $adjust = {
            param($sender, $e)
            try {
              $ctl = $sender
              if (-not $ctl) { return }
              $ctl.AutoSize = $false
              # Re-apply desired height in case layout shrinks it
              if ($ctl.Height -lt 56) { $ctl.Height = 60 }
              $h = $ctl.ClientSize.Height
              if ($ctl.Controls.Count -ge 2) {
                $btns = $ctl.Controls[0]
                $edit = $ctl.Controls[1]
                # Wider spinner buttons and full-height
                $btns.Width = [int]34
                $btns.Height = $h
                $btns.Location = New-Object System.Drawing.Point ($ctl.ClientSize.Width - $btns.Width - 1), 0
                # Fill the remaining area with the edit box and center text vertically as much as possible
                try { $edit.AutoSize = $false } catch {}
                try { $edit.BorderStyle = [System.Windows.Forms.BorderStyle]::None } catch {}
                $edit.Size = New-Object System.Drawing.Size ($ctl.ClientSize.Width - $btns.Width - 4), ($h - 4)
                $pref = $edit.PreferredHeight
                $top = [int][Math]::Max(2, [Math]::Round(($h - $pref) / 2.0))
                $edit.Location = New-Object System.Drawing.Point 2, $top
              }
            } catch {}
          }
          try { $n.add_HandleCreated($adjust) } catch {}
          try { $n.add_SizeChanged($adjust) } catch {}
          return $n
        }

        # Row builder
        $row = 1
        $ui = @{}
        foreach ($info in @(
            @{ key = 'dev'; title = 'Dev Extreme' },
            @{ key = 'balanced'; title = 'Balanced' },
            @{ key = 'desktop'; title = 'Meeting' }
          )) {
          $lbl = New-Object System.Windows.Forms.Label; $lbl.Text = $info.title; $lbl.AutoSize = $true; $lbl.Margin = (New-Object System.Windows.Forms.Padding 2, 6, 6, 6); try { $lbl.Font = [System.Drawing.Font]::new('Segoe UI', [single]12.5) } catch {}
          $numP = New-Num 1 64 ([int]$script:Profiles[$info.key].processors)
          $numM = New-Num 1 256 ([int]$script:Profiles[$info.key].memoryGB)
          $tbl.Controls.Add($lbl, 0, $row)
          $tbl.Controls.Add($numP, 1, $row)
          $tbl.Controls.Add($numM, 2, $row)
          $ui[$info.key] = @{ NumP = $numP; NumM = $numM }
          # Center the label vertically relative to the taller numeric input
          try {
            $prefH = ($lbl.GetPreferredSize([System.Drawing.Size]::Empty)).Height
            $delta = [int][Math]::Max(0, [Math]::Round(($numP.Height - $prefH) / 2.0))
            $lbl.Margin = New-Object System.Windows.Forms.Padding 2, $delta, 6, $delta
          } catch {}
          $row++
        }
        # Place a small note above the table inside the group box
        $note = New-Object System.Windows.Forms.Label; $note.Text = 'Changes apply the next time you switch profiles.'; $note.AutoSize = $true; $note.Margin = (New-Object System.Windows.Forms.Padding 6, 10, 6, 8); $note.Dock = 'Top'; try { $note.Font = [System.Drawing.Font]::new('Segoe UI', [single]11.0) } catch {}
        $grpProfiles.Controls.Add($note)
        $tbl.Dock = 'Top'
        $grpProfiles.Controls.Add($tbl)
        $tabProfiles.AutoScroll = $true
        $tabProfiles.Controls.Add($grpProfiles)
        [void]$tabs.TabPages.Add($tabProfiles)

        # Tab 2: General (hotkeys + startup)
        $tabGeneral = New-Object System.Windows.Forms.TabPage
        $tabGeneral.Text = 'General'
        $tabGeneral.AutoScroll = $true
        try { $tabGeneral.UseVisualStyleBackColor = $false; $tabGeneral.BackColor = [System.Drawing.SystemColors]::Window } catch {}
        try { $tabGeneral.Padding = New-Object System.Windows.Forms.Padding 8, 12, 8, 16 } catch {}
        $panelG = New-Object System.Windows.Forms.Panel
        $panelG.Dock = 'Fill'
        $panelG.Padding = (New-Object System.Windows.Forms.Padding 12)
        # Avoid inner panel scrollbars; the TabPage still provides scrolling if ever needed
        try { $panelG.AutoScroll = $false } catch {}
        try { $panelG.BackColor = [System.Drawing.SystemColors]::Window } catch {}

        # Startup group
        $gbStart = New-Object System.Windows.Forms.GroupBox; $gbStart.Text = 'Startup'; $gbStart.Dock = 'Top'; $gbStart.AutoSize = $true; $gbStart.Padding = (New-Object System.Windows.Forms.Padding 12)
        try { $gbStart.BackColor = [System.Drawing.SystemColors]::Window } catch {}
        $chkStart = New-Object System.Windows.Forms.CheckBox; $chkStart.Text = 'Start with Windows'; $chkStart.AutoSize = $true; $chkStart.Checked = (Is-StartupEnabled); $chkStart.Margin = (New-Object System.Windows.Forms.Padding 4)
        $gbStart.Controls.Add($chkStart)
        $panelG.Controls.Add($gbStart)

        # Hotkeys group
        $gb = New-Object System.Windows.Forms.GroupBox; $gb.Text = 'Hotkeys'; $gb.Dock = 'Top'; $gb.AutoSize = $true; $gb.Padding = (New-Object System.Windows.Forms.Padding 12, 18, 12, 20)
        try { $gb.BackColor = [System.Drawing.SystemColors]::Window } catch {}
        # Root vertical stack for master toggle + per-action table
        $hotRoot = New-Object System.Windows.Forms.TableLayoutPanel
        $hotRoot.Dock = 'Top'; $hotRoot.AutoSize = $true; $hotRoot.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
        $hotRoot.ColumnCount = 1; $hotRoot.RowCount = 2
        [void]$hotRoot.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
        [void]$hotRoot.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
        $hotRoot.Padding = (New-Object System.Windows.Forms.Padding 0)
        $hotRoot.Margin = (New-Object System.Windows.Forms.Padding 4, 6, 4, 8)

        $chkHot = New-Object System.Windows.Forms.CheckBox; $chkHot.Text = 'Enable global hotkeys'; $chkHot.AutoSize = $true; $chkHot.Checked = [bool]$script:HotkeysEnabled; $chkHot.Margin = (New-Object System.Windows.Forms.Padding 4)
        $hotRoot.Controls.Add($chkHot, 0, 0)

        $hotTable = New-Object System.Windows.Forms.TableLayoutPanel
        $hotTable.Dock = 'Top'; $hotTable.AutoSize = $true; $hotTable.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
        $hotTable.Padding = (New-Object System.Windows.Forms.Padding 0, 0, 0, 4)
        $hotTable.Margin = (New-Object System.Windows.Forms.Padding 4, 6, 4, 8)
        $hotTable.ColumnCount = 2; $hotTable.RowCount = 4
        [void]$hotTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
        [void]$hotTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
        foreach ($i in 0..3) { [void]$hotTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) }
        # Helper to vertically center a checkbox next to its label (DPI-safe)
        function Align-HotkeyRow([System.Windows.Forms.CheckBox]$chk, [System.Windows.Forms.Label]$lbl, [bool]$isLast) {
          try {
            $lbl.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
            $lbl.AutoSize = $true
            $lbl.Margin = (New-Object System.Windows.Forms.Padding 3, 6, 6, ($(if ($isLast) { 2 } else { 0 })))

            $chk.AutoSize = $true
            # Compute preferred sizes to align centers regardless of system metrics
            $hLbl = ($lbl.GetPreferredSize([System.Drawing.Size]::Empty)).Height
            $hChk = ($chk.GetPreferredSize([System.Drawing.Size]::Empty)).Height
            $delta = [int][Math]::Max(0, [Math]::Round(($hLbl - $hChk) / 2.0))
            $chk.Margin = (New-Object System.Windows.Forms.Padding 6, (6 + $delta), 6, ($(if ($isLast) { 2 } else { 0 })))
          }
          catch {}
        }
        # Per-action toggles with labels (apply alignment helper)
        $chkOpen = New-Object System.Windows.Forms.CheckBox; $chkOpen.Checked = [bool]$script:HotkeyFlags.OpenMenu
        $l1 = New-Object System.Windows.Forms.Label; $l1.Text = 'Open menu: Ctrl+Alt+P'
        Align-HotkeyRow -chk $chkOpen -lbl $l1 -isLast:$false
        $hotTable.Controls.Add($chkOpen, 0, 0); $hotTable.Controls.Add($l1, 1, 0)

        $chkDev = New-Object System.Windows.Forms.CheckBox; $chkDev.Checked = [bool]$script:HotkeyFlags.Dev
        $l2 = New-Object System.Windows.Forms.Label; $l2.Text = 'Dev Extreme: Ctrl+Alt+D'
        Align-HotkeyRow -chk $chkDev -lbl $l2 -isLast:$false
        $hotTable.Controls.Add($chkDev, 0, 1); $hotTable.Controls.Add($l2, 1, 1)

        $chkBal = New-Object System.Windows.Forms.CheckBox; $chkBal.Checked = [bool]$script:HotkeyFlags.Balanced
        $l3 = New-Object System.Windows.Forms.Label; $l3.Text = 'Balanced: Ctrl+Alt+B'
        Align-HotkeyRow -chk $chkBal -lbl $l3 -isLast:$false
        $hotTable.Controls.Add($chkBal, 0, 2); $hotTable.Controls.Add($l3, 1, 2)

        $chkDesk = New-Object System.Windows.Forms.CheckBox; $chkDesk.Checked = [bool]$script:HotkeyFlags.Desktop
        $l4 = New-Object System.Windows.Forms.Label; $l4.Text = 'Meeting: Ctrl+Alt+M'
        Align-HotkeyRow -chk $chkDesk -lbl $l4 -isLast:$true
        $hotTable.Controls.Add($chkDesk, 0, 3); $hotTable.Controls.Add($l4, 1, 3)
        $hotRoot.Controls.Add($hotTable, 0, 1)
        $gb.Controls.Add($hotRoot)
        # Master toggle drives enabled state of per-action table
        $null = $hotTable.Enabled = [bool]$script:HotkeysEnabled
        $chkHot.add_CheckedChanged({ try { $hotTable.Enabled = [bool]$chkHot.Checked } catch {} })
        $panelG.Controls.Add($gb)
        $tabGeneral.Controls.Add($panelG)
        [void]$tabs.TabPages.Add($tabGeneral)

        # Apply
        $startupBefore = (Is-StartupEnabled)
        $hotBefore = [bool]$script:HotkeysEnabled
        $flagsBefore = $script:HotkeyFlags.Clone()

        if ($dlg.ShowDialog() -eq 'OK') {
          # Apply profile edits
          $script:Profiles.dev.processors = [int]$ui.dev.NumP.Value
          $script:Profiles.dev.memoryGB = [int]$ui.dev.NumM.Value
          $script:Profiles.balanced.processors = [int]$ui.balanced.NumP.Value
          $script:Profiles.balanced.memoryGB = [int]$ui.balanced.NumM.Value
          $script:Profiles.desktop.processors = [int]$ui.desktop.NumP.Value
          $script:Profiles.desktop.memoryGB = [int]$ui.desktop.NumM.Value

          # Apply hotkeys
          $script:HotkeysEnabled = [bool]$chkHot.Checked
          $script:HotkeyFlags.OpenMenu = [bool]$chkOpen.Checked
          $script:HotkeyFlags.Dev = [bool]$chkDev.Checked
          $script:HotkeyFlags.Balanced = [bool]$chkBal.Checked
          $script:HotkeyFlags.Desktop = [bool]$chkDesk.Checked
          # Re-register when the master switch toggles or flags change
          $flagsChanged = $false
          foreach ($k in @('OpenMenu', 'Dev', 'Balanced', 'Desktop')) { if ($script:HotkeyFlags[$k] -ne $flagsBefore[$k]) { $flagsChanged = $true; break } }
          if ($script:HotkeysEnabled) { Unregister-Hotkeys; Register-Hotkeys }
          elseif ($hotBefore) { Unregister-Hotkeys }

          # Apply startup
          $startupAfter = [bool]$chkStart.Checked
          if ($startupAfter -ne $startupBefore) { [void](Set-Startup $startupAfter) }

          Save-Settings
          Write-ProfileFiles
          Update-MenuLabels
        }
      }
      catch { Log ("Settings dialog failed: " + $_.Exception.Message) }
    })
  [void]$contextMenu.Items.Add($miSettings)

  # Settings now contain Startup + Hotkeys; remove separate toggles in menu

  $contextMenu.Items.Add('-') | Out-Null
  $miExit = New-Object System.Windows.Forms.ToolStripMenuItem
  $miExit.Text = 'Exit'
  $miExit.add_Click({ Unregister-Hotkeys; $tray.Visible = $false; $tray.Dispose(); [System.Windows.Forms.Application]::Exit() })
  [void]$contextMenu.Items.Add($miExit)

  $tray.ContextMenuStrip = $contextMenu

  # Left-click opens the menu at cursor position
  $tray.Add_MouseUp({
      param($Src, $Args)
      if ($Args.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $pos = [System.Windows.Forms.Cursor]::Position
        $contextMenu.Show($pos)
      }
    })

  Log 'NotifyIcon visible; tray running'
  [System.Windows.Forms.Application]::Run()
}
catch {
  try { Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.MessageBox]::Show("WSL Profile Tray Fehler: $($_.Exception.Message)", 'WSL Profile Switcher', 'OK', 'Error') | Out-Null } catch {}
  Log ("Tray crashed: " + $_.Exception.Message)
}
