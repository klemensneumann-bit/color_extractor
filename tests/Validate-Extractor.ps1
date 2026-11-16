$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml

$scriptPath = Join-Path $PSScriptRoot '..\ColorExtractor.ms'
$text = [IO.File]::ReadAllText($scriptPath)
$match = [regex]::Match($text, '(?s)local src = "(.*?)"\s+local provider =')
if (-not $match.Success) { throw 'Embedded C# source not found' }
$source = $match.Groups[1].Value.Replace('\"', '"')
$source += @'

// A hidden native window verifies guarded and forwarded input without opening UI.
public class SwatchInputProbe : System.Windows.Forms.NativeWindow
{
    public int LastMessage;
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern System.IntPtr SendMessage(System.IntPtr hwnd, int msg, System.IntPtr w, System.IntPtr l);
    public SwatchInputProbe() { CreateHandle(new System.Windows.Forms.CreateParams()); }
    protected override void WndProc(ref System.Windows.Forms.Message message)
    {
        if ((message.Msg >= 0x0201 && message.Msg <= 0x0205) ||
            (message.Msg >= 0x0100 && message.Msg <= 0x0102) || message.Msg == 0x007B)
        {
            LastMessage = message.Msg;
            message.Result = System.IntPtr.Zero;
            return;
        }
        base.WndProc(ref message);
    }
    public void Send(int message) { SendMessage(Handle, message, System.IntPtr.Zero, System.IntPtr.Zero); }
    public void Close() { DestroyHandle(); }
}
'@
$provider = New-Object Microsoft.CSharp.CSharpCodeProvider
$parameters = New-Object System.CodeDom.Compiler.CompilerParameters
$parameters.GenerateInMemory = $true
foreach ($assembly in @('System.dll', 'System.Drawing.dll', 'System.Windows.Forms.dll',
    [System.Windows.Media.Imaging.BitmapDecoder].Assembly.Location,
    [System.Windows.DependencyObject].Assembly.Location,
    [System.Xaml.XamlReader].Assembly.Location)) {
    [void]$parameters.ReferencedAssemblies.Add($assembly)
}
$compiled = $provider.CompileAssemblyFromSource($parameters, [string[]]@($source))
if ($compiled.Errors.HasErrors) { throw (($compiled.Errors | ForEach-Object { $_.ToString() }) -join "`n") }
$engine = $compiled.CompiledAssembly.CreateInstance('ColorExtractor')
$script:checks = 0
function Assert($condition, $message) {
    if (-not $condition) { throw $message }
    $script:checks++
}
function EqualRgb($actual, $expected) {
    return (($actual -join ',') -eq ($expected -join ','))
}

$probe = $compiled.CompiledAssembly.CreateInstance('SwatchInputProbe')
try {
    $engine.ProtectPaletteSwatch($probe.Handle.ToInt64())
    Assert ($engine.ProtectedPaletteSwatchCount -eq 1) 'Native swatch guard must attach'
    foreach ($message in @(0x0201, 0x0202, 0x0203, 0x0100, 0x0101, 0x0102)) {
        $probe.LastMessage = 0
        $probe.Send($message)
        Assert ($probe.LastMessage -eq 0) 'Palette editor input must be blocked'
    }
    foreach ($message in @(0x0204, 0x0205, 0x007B)) {
        $probe.Send($message)
        Assert ($probe.LastMessage -eq $message) 'Right-click color clipboard input must pass through'
    }
    $engine.ReleasePaletteSwatches()
    $probe.Send(0x0201)
    Assert ($probe.LastMessage -eq 0x0201) 'Releasing guards must restore native input'
} finally {
    $engine.ReleasePaletteSwatches()
    $probe.Close()
}

$bitmap = New-Object System.Drawing.Bitmap 20, 10
try {
    for ($y = 0; $y -lt 10; $y++) {
        for ($x = 0; $x -lt 20; $x++) {
            $c = if ($x -lt 15) { [Drawing.Color]::Red } else { [Drawing.Color]::Blue }
            $bitmap.SetPixel($x, $y, $c)
        }
    }
    $engine.ConfigureMask($false, 255, 0, 0, 0, 0)
    $palette = $engine.ExtractColors($bitmap, 16, 0, 1000, $false)
    Assert (EqualRgb $palette @(255,0,0,0,0,255)) 'Two distinct colors should produce two ordered clusters'
    $weights = $engine.GetClusterWeights()
    Assert ([Math]::Abs($weights[0] - 0.75) -lt 0.000001) 'Cluster mass should reflect retained pixel weights'
    Assert (EqualRgb $palette ($engine.ExtractColors($bitmap,16,0,1000,$false))) 'Extraction should be deterministic'

    $engine.ConfigureMask($true, 255, 0, 0, 0, 0)
    Assert (EqualRgb ($engine.ExtractColors($bitmap,16,2,1000,$false)) @(0,0,255)) 'Exact background must be excluded before blur'
    $preview = $engine.CreateMaskPreview($bitmap)
    try {
        Assert ($preview.GetPixel(0,0).ToArgb() -eq [Drawing.Color]::Magenta.ToArgb()) 'Excluded pixel should preview as magenta'
        Assert ($preview.GetPixel(19,0).ToArgb() -eq [Drawing.Color]::Blue.ToArgb()) 'Retained pixel should keep its source color'
        Assert ($bitmap.GetPixel(0,0).ToArgb() -eq [Drawing.Color]::Red.ToArgb()) 'Preview must not modify the source'
    } finally { $preview.Dispose() }
    Assert (EqualRgb ($engine.PickPixel($bitmap,200,200,10,50)) @(255,0,0)) 'Zoom pick should map to source pixel'
    Assert ($engine.PickPixel($bitmap,200,200,10,49).Length -eq 0) 'Zoom pick must reject top margin'
    Assert ($engine.PickPixel($bitmap,200,200,10,150).Length -eq 0) 'Zoom pick must reject bottom margin'

    $engine.ConfigureMask($true, 255, 0, 0, 250, 0)
    Assert ($engine.ExtractColors($bitmap,16,0,1000,$false).Length -eq 0) 'Fully masked input must return an empty palette'
    Assert ($engine.GetClusterWeights().Length -eq 0) 'Fully masked input must clear previous masses'
    $bitmap.SetPixel(19,9,[Drawing.Color]::Lime)
    $engine.ConfigureMask($true,255,0,0,0,0)
    Assert ($engine.ExtractColors($bitmap,16,2,1000,$false).Length -eq 6) 'Small retained regions must survive masking'

    $engine.ConfigureMask($false,0,0,0,0,0)
    Assert ($engine.ExtractColors($bitmap,1,0,1000,$false).Length -eq 3) 'Single cluster must calculate its centroid'
    Assert ($engine.ExtractColors($bitmap,16,0,3,$false).Length -le 9) 'Sampling must respect maxSamples'
    Assert ($engine.ExtractColors($bitmap,0,0,1000,$false).Length -eq 0) 'Invalid color count should return empty'
} finally { $bitmap.Dispose() }

$bitmap = New-Object Drawing.Bitmap 2, 1
try {
    $bitmap.SetPixel(0,0,[Drawing.Color]::FromArgb(128,128,128))
    $bitmap.SetPixel(1,0,[Drawing.Color]::Black)
    $engine.ConfigureMask($true,255,255,255,0,0)
    $hard = $engine.ExtractColors($bitmap,1,0,1000,$false)
    $engine.ConfigureMask($true,255,255,255,0,100)
    $soft = $engine.ExtractColors($bitmap,1,0,1000,$false)
    Assert ($soft[0] -lt $hard[0]) 'Soft weights must shift centroid away from background-like samples'
    $preview = $engine.CreateMaskPreview($bitmap)
    try {
        $c = $preview.GetPixel(0,0)
        Assert ($c.R -gt 128 -and $c.G -gt 0 -and $c.G -lt 128) 'Soft weights must create a partial overlay'
    } finally { $preview.Dispose() }
    $bitmap.SetPixel(1,0,[Drawing.Color]::FromArgb(0,255,0,0))
    $engine.ConfigureMask($false,0,0,0,0,0)
    Assert (EqualRgb ($engine.ExtractColors($bitmap,16,2,1000,$false)) @(128,128,128)) 'Transparent RGB must not enter the palette'
    Assert (EqualRgb ($engine.ExtractColors($bitmap,16,0,1000,$true)) @(55,55,55)) 'Linear conversion should happen after clustering'
    Assert ($engine.PickPixel($bitmap,200,100,199,0).Length -eq 0) 'Picking transparent pixels should be rejected'
    $bitmap.SetPixel(0,0,[Drawing.Color]::Transparent)
    Assert ($engine.ExtractColors($bitmap,16,2,1000,$false).Length -eq 0) 'Transparent image should return empty'
} finally { $bitmap.Dispose() }

$bitmap = New-Object Drawing.Bitmap 100, 100
try {
    $g = [Drawing.Graphics]::FromImage($bitmap)
    try { $g.Clear([Drawing.Color]::White) } finally { $g.Dispose() }
    $bitmap.SetPixel(99,99,[Drawing.Color]::Red)
    $engine.ConfigureMask($true,255,255,255,1,0)
    Assert (EqualRgb ($engine.ExtractColors($bitmap,16,2,1,$false)) @(255,0,0)) 'A one-pixel foreground must survive a one-sample budget'
} finally { $bitmap.Dispose() }

# Exercise the WPF fallback directly, even if the shell thumbnail cache is warm.
$path = [IO.Path]::GetTempFileName()
$bitmap = New-Object Drawing.Bitmap 2, 1
$decoded = $null
try {
    $bitmap.SetPixel(0,0,[Drawing.Color]::Red)
    $bitmap.Save($path,[Drawing.Imaging.ImageFormat]::Png)
    $method = $engine.GetType().GetMethod('LoadWithBitmapDecoder', [Reflection.BindingFlags]'Static, NonPublic')
    $decoded = $method.Invoke($null, [object[]]@($path, 2, 1))
    $exclusive = [IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $exclusive.Dispose()
    Assert ($decoded.GetPixel(0,0).R -eq 255) 'WPF fallback should decode without retaining a file lock'
} finally {
    if ($null -ne $decoded) { $decoded.Dispose() }
    $bitmap.Dispose()
    Remove-Item -LiteralPath $path
}
$provider.Dispose()
Write-Output "PASS: embedded C# compiled; $script:checks assertions passed."
