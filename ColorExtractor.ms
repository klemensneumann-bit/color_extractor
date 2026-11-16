(
-- Thumbnail viewer + dominant colour extractor
-- Image load/display: MaxScript dotNet bridge (PictureBox)
-- Color extraction: C# class compiled at runtime via CSharpCodeProvider
--   -> blur, pixel sampling and k-means all run inside .NET
--   -> returns a plain int[] (R,G,B triplets) that MaxScript reads safely
-- Mask preview and weighted Lab k-means run inside the C# helper.

dotNet.loadAssembly "System.Drawing"
dotNet.loadAssembly "System.Windows.Forms"

global ColorExtractor_rollout -- the main dialog
local ce_Version = "0.5"
-- Palette capacity matches the fixed swatch row below.
local ce_MinPaletteColors = 2
local ce_MaxPaletteColors = 16
local ce_DefaultIgnoreBackground = false
local ce_DefaultThreshold = 10.0
local ce_DefaultSoftness = 5.0
local ce_DefaultLinear = true
local ce_MaxMaskDistance = 250.0
local ce_MapRandomSeed = 42
local ce_EmptySwatchColor = color 20 20 20
local ce_ExtractionBlurPasses = 2
local ce_ExtractionMaxSamples = 1000
local ce_FStormLegacyRandomSlots = 4
local ce_FStormExpandedRandomSlots = 8
local ce_PreviewBitmap  = undefined
local ce_ThumbBitmap    = undefined
local ce_DominantColors = #()
local ce_ColorExtractor = undefined   -- compiled C# instance, created once

-- FStorm 1.5.4b (2023-10-09) added more RandomColor colors; older builds use 4.
-- Source: https://fstormrender.com/forum/forum/releases/12982-fstormrender-for-3ds-max-v1-5-4g
-- Read the renderer class name (e.g. FStormRender_v1_5_3g), not a display label.
-- Unknown version formats default to 4 rather than assuming 8 slots exist.
fn fstormRandomColorLimit rendererClassName = (
    local versionMatch = (dotNetClass "System.Text.RegularExpressions.Regex").Match rendererClassName "^FStormRender_v([0-9]+)_([0-9]+)_([0-9]+)([a-z]?)[0-9]*$" (dotNetClass "System.Text.RegularExpressions.RegexOptions").IgnoreCase
    if not versionMatch.Success do return ce_FStormLegacyRandomSlots

    local minimumVersion = #(1, 5, 4)
    for i = 1 to 3 do (
        local component = (versionMatch.Groups.Item[i].Value as string) as integer
        if component > minimumVersion[i] do return ce_FStormExpandedRandomSlots
        if component < minimumVersion[i] do return ce_FStormLegacyRandomSlots
    )
    -- For 1.5.4 itself, no suffix and suffix 'a' precede the 'b' update.
    local suffix = toLower (versionMatch.Groups.Item[4].Value as string)
    local suffixRank = findString "abcdefghijklmnopqrstuvwxyz" suffix
    if suffix != "" and suffixRank != undefined and suffixRank >= 2 then ce_FStormExpandedRandomSlots else ce_FStormLegacyRandomSlots
)

-- Discover registered plugin classes without instantiating a renderer or
-- changing renderers.current. Map construction is guarded separately below.
struct CE_PaletteMapResult (texture, colorCount)
struct CE_MapSupport (fstormRendererClassName, randomColorClass, multiTexClass, vrayClass, coronaClass, arnoldClass)

fn findRegisteredClass classList classPattern = (
    for candidate in classList do (
        if matchPattern (candidate as string) pattern:classPattern ignoreCase:true do return candidate
    )
    undefined
)

fn discoverPaletteMapSupport = (
    local support = CE_MapSupport()
    local installedRendererType = findRegisteredClass RendererClass.classes "FStormRender_*"
    if installedRendererType != undefined do (
        support.fstormRendererClassName = installedRendererType as string
        support.randomColorClass = findRegisteredClass textureMap.classes "FStormRandomColor"
        support.multiTexClass = findRegisteredClass textureMap.classes "FStormMultiTex"
    )
    support.vrayClass = findRegisteredClass textureMap.classes "VRayMultiSubTex"
    support.coronaClass = findRegisteredClass textureMap.classes "CoronaMultiMap"
    support.arnoldClass = findRegisteredClass textureMap.classes "ai_switch_rgba"
    support
)

fn paletteMapClass support mapKind = (
    if support == undefined do return undefined
    case mapKind of (
        #randomColor: (if support.fstormRendererClassName != undefined then support.randomColorClass else undefined)
        #multiTex: (if support.fstormRendererClassName != undefined then support.multiTexClass else undefined)
        #vray: support.vrayClass
        #corona: support.coronaClass
        #arnold: support.arnoldClass
        default: undefined
    )
)

fn createPaletteMap support mapKind palette = (
    if palette.count == 0 do return undefined
    local mapClass = paletteMapClass support mapKind
    if mapClass == undefined do return undefined
    -- Use the discovered class value: missing plugin symbols are never invoked.
    local m = mapClass()
    case mapKind of (
        #randomColor: (
            local n = amin #(fstormRandomColorLimit support.fstormRendererClassName, m.colors.count, m.chances.count, palette.count)
            if n < 1 do return undefined
            for i = 1 to n do m.colors[i] = palette[i]
            for i = 1 to m.chances.count do m.chances[i] = if i <= n then (1.0 / n) else 0.0
            m.id_source = 0
            m.mix_value = 1.0
            m.random_seed = ce_MapRandomSeed
            CE_PaletteMapResult texture:m colorCount:n
        )
        #multiTex: (
            -- Set individual slots: plugin arrays have a fixed capacity.
            local n = amin #(ce_MaxPaletteColors, palette.count, m.colors.count, m.ids.count, m.textures.count, m.textures_on.count)
            if n < 1 do return undefined
            m.num_ids = n
            -- Some versions may clamp the requested active slot count.
            n = amin #(n, m.num_ids)
            for i = 1 to n do (
                m.ids[i] = i
                m.colors[i] = palette[i]
                m.textures[i] = undefined
                -- Preserve the enabled default for each active entry.
                m.textures_on[i] = true
            )
            -- Keep the plugin's default ID-source mode.
            m.random_seed = ce_MapRandomSeed
            CE_PaletteMapResult texture:m colorCount:n
        )
        #vray: (
            local n = amin #(ce_MaxPaletteColors, palette.count)
            -- Published interface resizes all parallel slot arrays together.
            m.texmap_num = n
            if m.texmap_color.count != n do throw "V-Ray palette slot count was not accepted"
            for i = 1 to n do (
                m.texmap_color[i] = palette[i]
                m.texmap_id[i] = i
                m.texmap_on[i] = true
                m.texmap[i] = undefined
                m.texmap_mapOn[i] = false
                m.texmap_mult[i] = 100.0
            )
            m.default_color = palette[1]
            m.default_texmap_on = false
            m.random_hue = 0
            m.random_saturation = 0
            m.random_gamma = 0
            m.seed = ce_MapRandomSeed
            -- Preserve the default ID-source mode; do not guess plugin enums.
            CE_PaletteMapResult texture:m colorCount:n
        )
        #corona: (
            local n = amin #(ce_MaxPaletteColors, palette.count, m.colors.count, m.frequency.count, m.texmaps.count, m.texmapsOn.count)
            if n < 1 do return undefined
            m.items = n
            if m.items != n do throw "Corona palette slot count was not accepted"
            for i = 1 to n do (
                m.colors[i] = palette[i]
                m.frequency[i] = 1.0
                m.texmaps[i] = undefined
                m.texmapsOn[i] = false
            )
            m.mixAmount = 0
            m.hueRandom = 0
            m.saturationRandom = 0
            m.gammaRandom = 0
            -- Clear every installed randomization flag, including version additions.
            for p in getPropNames m where matchPattern (p as string) pattern:"randomize*" do setProperty m p false
            m.randomizeInstance = true
            m.seed = ce_MapRandomSeed
            CE_PaletteMapResult texture:m colorCount:n
        )
        #arnold: (
            local capacity = 0
            while isProperty m ("input" + capacity as string) do capacity += 1
            local n = amin #(ce_MaxPaletteColors, palette.count, capacity)
            if n < 1 do return undefined
            for i = 0 to capacity - 1 do (
                local p = "input" + i as string
                -- Unused inputs repeat the first color rather than producing black.
                setProperty m p palette[(if i < n then i + 1 else 1)]
                setProperty m (p + "_shader") undefined
                setProperty m (p + "_connected") false
            )
            m.index = 0
            m.index_shader = undefined
            m.index_connected = false
            CE_PaletteMapResult texture:m colorCount:n
        )
        default: undefined
    )
)

--------------------------------------------------------------------------------
-- 1. Compile the managed image helper and native swatch input guard
--     C# source is embedded directly — quotes escaped as \" for MaxScript.
--     The assembly stays in memory; temporary source is deleted after compilation.
--------------------------------------------------------------------------------
fn compileColorExtractor = (
    local result = undefined
    local tmpBase = undefined
    local csFile = undefined
    try (
        local src = "using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.IO;
using System.Windows.Media.Imaging;
using System.Windows.Media;
using System.Windows.Forms;
using Color = System.Drawing.Color;
using PixelFormat = System.Drawing.Imaging.PixelFormat;

// Keep Max's native right-click color clipboard while blocking the editor.
public class PaletteSwatchWindow : NativeWindow
{
    public PaletteSwatchWindow(long hwnd) { AssignHandle(new IntPtr(hwnd)); }
    protected override void WndProc(ref Message message)
    {
        const int LeftDown = 0x0201, LeftUp = 0x0202, LeftDoubleClick = 0x0203;
        const int KeyDown = 0x0100, KeyUp = 0x0101, Character = 0x0102;
        if (message.Msg == LeftDown || message.Msg == LeftUp || message.Msg == LeftDoubleClick ||
            message.Msg == KeyDown || message.Msg == KeyUp || message.Msg == Character)
        {
            message.Result = IntPtr.Zero;
            return;
        }
        base.WndProc(ref message);
    }
}

public class ColorExtractor
{
    private readonly System.Collections.Generic.List<PaletteSwatchWindow> swatches =
        new System.Collections.Generic.List<PaletteSwatchWindow>();
    public int ProtectedPaletteSwatchCount { get { return swatches.Count; } }
    public void ProtectPaletteSwatch(long hwnd) { swatches.Add(new PaletteSwatchWindow(hwnd)); }
    public void ReleasePaletteSwatches()
    {
        foreach (PaletteSwatchWindow swatch in swatches) swatch.ReleaseHandle();
        swatches.Clear();
    }

    // Try Windows thumbnails, then WPF and GDI+ decoders without retaining file locks.
    public Bitmap LoadThumbnail(string filePath, int maxW, int maxH)
    {
        // ---- Stage 1: Shell cache ------------------------------------------
        try
        {
            Bitmap shell = LoadFromShellCache(filePath, maxW, maxH);
            if (shell != null) return shell;
        }
        catch { }

        // ---- Stage 2: WPF BitmapDecoder ------------------------------------
        try
        {
            Bitmap wpf = LoadWithBitmapDecoder(filePath, maxW, maxH);
            if (wpf != null) return wpf;
        }
        catch { }

        // ---- Stage 3: GDI+ full decode (non-locking stream) ----------------
        return LoadWithGdi(filePath, maxW, maxH);
    }

    // --------------------------------------------------------------------------
    // Stage 1 — Shell thumbnail cache
    // Uses IShellItemImageFactory (Shell32) to get the cached Explorer thumbnail.
    // --------------------------------------------------------------------------
    [ComImport]
    [Guid(\"bcc18b79-ba16-442f-80c4-8a59c30c463b\")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellItemImageFactory
    {
        [PreserveSig]
        int GetImage(SIZE size, SIIGBF flags, out IntPtr phbm);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SIZE { public int cx, cy; }

    [Flags]
    private enum SIIGBF : int
    {
        ResizeToFit  = 0x00,
        BiggerSizeOk = 0x01,
        MemoryOnly   = 0x02,
        IconOnly     = 0x04,
        ThumbnailOnly = 0x08,
        InCacheOnly  = 0x10,
    }

    [DllImport(\"shell32.dll\", CharSet = CharSet.Unicode, PreserveSig = false)]
    private static extern void SHCreateItemFromParsingName(
        string pszPath, IntPtr pbc, ref Guid riid, out IShellItemImageFactory ppv);

    private static Bitmap LoadFromShellCache(string filePath, int maxW, int maxH)
    {
        Guid iid = new Guid(\"bcc18b79-ba16-442f-80c4-8a59c30c463b\");
        IShellItemImageFactory factory;
        SHCreateItemFromParsingName(filePath, IntPtr.Zero, ref iid, out factory);
        if (factory == null) return null;

        var size = new SIZE { cx = maxW, cy = maxH };

        // ---- Pass 1: cache-only, instant ------------------------------------
        // ThumbnailOnly means Shell returns null rather than an icon placeholder
        // if no real photo thumbnail exists in the cache yet.
        IntPtr hbm = IntPtr.Zero;
        int hr = factory.GetImage(size,
            SIIGBF.ResizeToFit | SIIGBF.InCacheOnly | SIIGBF.ThumbnailOnly,
            out hbm);

        if (hr == 0 && hbm != IntPtr.Zero)
        {
            // Cache was warm — validate it looks like a real thumbnail and not
            // a tiny icon that Shell returned despite ThumbnailOnly.
            // A genuine photo thumb will be at least 1/4 of the requested size.
            Bitmap cached = Image.FromHbitmap(hbm);
            DeleteObject(hbm);
            int minDim = Math.Min(maxW, maxH) / 4;
            if (cached.Width >= minDim && cached.Height >= minDim)
            {
                Bitmap fitted = FitBitmap(cached, maxW, maxH);
                cached.Dispose();
                return fitted;
            }
            cached.Dispose();
        }

        // ---- Pass 2: trigger Shell generation (no InCacheOnly) --------------
        // Shell will now generate the thumbnail if it can (uses its own fast
        // pipeline — much faster than GDI+ full decode for JPEG/TIFF/PNG).
        // ThumbnailOnly ensures we get null back for unsupported formats (EXR
        // etc.) rather than an icon, so we can fall through to BitmapDecoder.
        hbm = IntPtr.Zero;
        hr = factory.GetImage(size,
            SIIGBF.ResizeToFit | SIIGBF.ThumbnailOnly,
            out hbm);

        if (hr != 0 || hbm == IntPtr.Zero) return null;

        Bitmap generated = Image.FromHbitmap(hbm);
        DeleteObject(hbm);

        // Final size sanity check — reject if Shell still returned a tiny icon
        int minDim2 = Math.Min(maxW, maxH) / 4;
        if (generated.Width < minDim2 || generated.Height < minDim2)
        {
            generated.Dispose();
            return null;
        }

        Bitmap result = FitBitmap(generated, maxW, maxH);
        generated.Dispose();
        return result;
    }

    [DllImport(\"gdi32.dll\")] private static extern bool DeleteObject(IntPtr hObject);

    // --------------------------------------------------------------------------
    // Stage 2 — WPF BitmapDecoder (eager load releases the source stream)
    // --------------------------------------------------------------------------
    private static Bitmap LoadWithBitmapDecoder(string filePath, int maxW, int maxH)
    {
        BitmapFrame frame;
        using (var fs = File.Open(filePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
        {
            BitmapDecoder decoder = BitmapDecoder.Create(fs,
                BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
            frame = decoder.Frames[0];
            frame.Freeze();
        }

        // Compute aspect-correct decode size
        double scaleX = (double)maxW / frame.PixelWidth;
        double scaleY = (double)maxH / frame.PixelHeight;
        double scale  = Math.Min(scaleX, scaleY);
        int tw = Math.Max(1, (int)(frame.PixelWidth  * scale));
        int th = Math.Max(1, (int)(frame.PixelHeight * scale));

        // Resize the decoded frame
        var scaled = new TransformedBitmap(frame,
            new ScaleTransform((double)tw / frame.PixelWidth,
                               (double)th / frame.PixelHeight));

        // Convert WPF BitmapSource -> GDI Bitmap via MemoryStream + PNG encoder
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(scaled));
        using (var ms = new MemoryStream())
        {
            encoder.Save(ms);
            ms.Position = 0;
            using (var tmp = new Bitmap(ms))
                return new Bitmap(tmp);   // fresh copy — MemoryStream can now be freed
        }
    }

    // --------------------------------------------------------------------------
    // Stage 3 — GDI+ full decode via non-locking FileStream (original fallback)
    // --------------------------------------------------------------------------
    private static Bitmap LoadWithGdi(string filePath, int maxW, int maxH)
    {
        var fileMode   = System.IO.FileMode.Open;
        var fileAccess = System.IO.FileAccess.Read;
        var fileShare  = System.IO.FileShare.ReadWrite;

        using (var fs = File.Open(filePath, fileMode, fileAccess, fileShare))
        {
            using (var src = new Bitmap(fs))
            {
                return FitBitmap(src, maxW, maxH);
            }
        }
    }

    // --------------------------------------------------------------------------
    // Shared: aspect-correct resize into a fresh Bitmap
    // --------------------------------------------------------------------------
    private static Bitmap FitBitmap(Bitmap src, int maxW, int maxH)
    {
        double scale = Math.Min((double)maxW / src.Width, (double)maxH / src.Height);
        int tw = Math.Max(1, (int)(src.Width  * scale));
        int th = Math.Max(1, (int)(src.Height * scale));

        Bitmap dst = new Bitmap(tw, th);
        using (Graphics g = Graphics.FromImage(dst))
        {
            g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
            g.PixelOffsetMode   = System.Drawing.Drawing2D.PixelOffsetMode.HighQuality;
            g.DrawImage(src, new Rectangle(0, 0, tw, th));
        }
        return dst;
    }

    private bool maskEnabled;
    private double[] backgroundLab = new double[3];
    private double threshold = 10, softness = 5;
    private double[] clusterWeights = new double[0];

    public void ConfigureMask(bool enabled, int r, int g, int b, double tolerance, double feather)
    {
        maskEnabled = enabled;
        backgroundLab = ToLab(r, g, b);
        threshold = Math.Max(0, tolerance);
        softness = Math.Max(0, feather);
    }

    public double[] GetClusterWeights() { return (double[])clusterWeights.Clone(); }

    private double Weight(double[] lab, byte alpha)
    {
        double w = alpha / 255.0;
        if (!maskEnabled) return w;
        double d = Math.Sqrt(Distance(lab, backgroundLab));
        if (d <= threshold) return 0;
        if (softness <= 0 || d >= threshold + softness) return w;
        double t = (d - threshold) / softness;
        return w * t * t * (3 - 2 * t);
    }

    // Copy rows individually: negative stride must not produce negative offsets.
    private static byte[] ReadPixels(Bitmap source)
    {
        using (Bitmap copy = new Bitmap(source.Width, source.Height, PixelFormat.Format32bppArgb))
        {
            using (Graphics g = Graphics.FromImage(copy))
            {
                g.CompositingMode = System.Drawing.Drawing2D.CompositingMode.SourceCopy;
                g.DrawImageUnscaled(source, 0, 0);
            }
            BitmapData bits = copy.LockBits(new Rectangle(0, 0, copy.Width, copy.Height),
                ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            try
            {
                byte[] pixels = new byte[copy.Width * copy.Height * 4];
                for (int y = 0; y < copy.Height; y++)
                    Marshal.Copy(IntPtr.Add(bits.Scan0, y * bits.Stride), pixels,
                        y * copy.Width * 4, copy.Width * 4);
                return pixels;
            }
            finally { copy.UnlockBits(bits); }
        }
    }

    public Bitmap CreateMaskPreview(Bitmap source)
    {
        byte[] pixels = ReadPixels(source);
        Bitmap preview = new Bitmap(source.Width, source.Height, PixelFormat.Format32bppArgb);
        BitmapData bits = preview.LockBits(new Rectangle(0, 0, preview.Width, preview.Height),
            ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        try
        {
            for (int i = 0; i < pixels.Length; i += 4)
            {
                double w = Weight(ToLab(pixels[i+2], pixels[i+1], pixels[i]), pixels[i+3]);
                pixels[i] = (byte)Math.Round(pixels[i] * w + 255 * (1 - w));
                pixels[i+1] = (byte)Math.Round(pixels[i+1] * w);
                pixels[i+2] = (byte)Math.Round(pixels[i+2] * w + 255 * (1 - w));
                pixels[i+3] = 255;
            }
            for (int y = 0; y < preview.Height; y++)
                Marshal.Copy(pixels, y * preview.Width * 4,
                    IntPtr.Add(bits.Scan0, y * bits.Stride), preview.Width * 4);
        }
        catch { preview.UnlockBits(bits); preview.Dispose(); throw; }
        preview.UnlockBits(bits);
        return preview;
    }

    // Pixel coordinates for a centered PictureBox Zoom image; margins are invalid.
    public int[] PickPixel(Bitmap source, int clientW, int clientH, int x, int y)
    {
        if (clientW <= 0 || clientH <= 0) return new int[0];
        double scale = Math.Min((double)clientW / source.Width, (double)clientH / source.Height);
        int width = Math.Max(1, (int)(source.Width * scale));
        int height = Math.Max(1, (int)(source.Height * scale));
        int left = (clientW - width) / 2, top = (clientH - height) / 2;
        if (x < left || x >= left + width || y < top || y >= top + height) return new int[0];
        int px = Math.Min(source.Width - 1, (int)((x - left) * (double)source.Width / width));
        int py = Math.Min(source.Height - 1, (int)((y - top) * (double)source.Height / height));
        Color c = source.GetPixel(px, py);
        if (c.A == 0) return new int[0];
        return new int[] { c.R, c.G, c.B };
    }

    private class Sample
    {
        public double[] Lab;
        public double Weight;
        public Sample(double[] lab, double weight) { Lab = lab; Weight = weight; }
    }

    public int[] ExtractColors(Bitmap bmp, int numColors, int blurStrength, int maxSamples, bool toLinear)
    {
        clusterWeights = new double[0];
        if (numColors < 1 || maxSamples < 1) return new int[0];
        byte[] original = ReadPixels(bmp);
        bool hasAlpha = false;
        for (int i = 3; i < original.Length; i += 4) if (original[i] != 255) { hasAlpha = true; break; }
        byte[] colors = original;
        // Masked/transparent sources stay unblurred to prevent background bleed.
        if (!maskEnabled && !hasAlpha && blurStrength > 0)
        {
            using (Bitmap work = new Bitmap(bmp))
            {
                for (int pass = 0; pass < blurStrength; pass++)
                using (Bitmap small = new Bitmap(Math.Max(1, bmp.Width / 4), Math.Max(1, bmp.Height / 4)))
                {
                    using (Graphics g = Graphics.FromImage(small))
                    {
                        g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                        g.DrawImage(work, new Rectangle(0, 0, small.Width, small.Height));
                    }
                    using (Graphics g = Graphics.FromImage(work))
                    {
                        g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                        g.DrawImage(small, new Rectangle(0, 0, work.Width, work.Height));
                    }
                }
                colors = ReadPixels(work);
            }
        }
        // Reservoir sampling among retained pixels: tiny foregrounds are not lost
        // merely because the background occupies most of the thumbnail.
        var samples = new System.Collections.Generic.List<Sample>();
        Random random = new Random(42);
        int seen = 0;
        for (int i = 0; i < original.Length; i += 4)
        {
            double[] originalLab = ToLab(original[i+2], original[i+1], original[i]);
            double weight = Weight(originalLab, original[i+3]);
            if (weight <= 0) continue;
            Sample sample = new Sample(ToLab(colors[i+2], colors[i+1], colors[i]), weight);
            seen++;
            if (samples.Count < maxSamples) samples.Add(sample);
            else { int slot = random.Next(seen); if (slot < maxSamples) samples[slot] = sample; }
        }
        if (samples.Count == 0) return new int[0];
        var centers = new System.Collections.Generic.List<double[]>();
        double[] scores = new double[samples.Count];
        for (int i = 0; i < scores.Length; i++) scores[i] = samples[i].Weight;
        while (centers.Count < Math.Min(numColors, samples.Count))
        {
            double sum = 0;
            for (int i = 0; i < scores.Length; i++) sum += scores[i];
            if (sum <= 1e-12) break;
            double target = random.NextDouble() * sum;
            int chosen = scores.Length - 1;
            for (int i = 0; i < scores.Length; i++) { target -= scores[i]; if (target < 0) { chosen = i; break; } }
            centers.Add((double[])samples[chosen].Lab.Clone());
            for (int i = 0; i < scores.Length; i++)
            {
                double nearest = double.MaxValue;
                foreach (double[] center in centers) nearest = Math.Min(nearest, Distance(samples[i].Lab, center));
                scores[i] = samples[i].Weight * nearest;
            }
        }
        int k = centers.Count;
        int[] assignments = new int[samples.Count];
        for (int i = 0; i < assignments.Length; i++) assignments[i] = -1;
        for (int iteration = 0; iteration < 50; iteration++)
        {
            bool changed = false;
            double[,] sums = new double[k, 3];
            double[] masses = new double[k];
            for (int i = 0; i < samples.Count; i++)
            {
                int j = Nearest(samples[i].Lab, centers);
                if (assignments[i] != j) changed = true;
                assignments[i] = j;
                masses[j] += samples[i].Weight;
                for (int axis = 0; axis < 3; axis++) sums[j, axis] += samples[i].Weight * samples[i].Lab[axis];
            }
            for (int j = 0; j < k; j++)
                if (masses[j] > 0)
                    for (int axis = 0; axis < 3; axis++) centers[j][axis] = sums[j, axis] / masses[j];
            if (!changed) break;
        }
        double[] counts = new double[k];
        foreach (Sample sample in samples) counts[Nearest(sample.Lab, centers)] += sample.Weight;
        var order = new System.Collections.Generic.List<int>();
        for (int j = 0; j < k; j++) if (counts[j] > 0) order.Add(j);
        order.Sort(delegate(int a, int b) { int c = counts[b].CompareTo(counts[a]); return c != 0 ? c : a.CompareTo(b); });
        int[] result = new int[order.Count * 3];
        clusterWeights = new double[order.Count];
        double total = 0;
        foreach (double count in counts) total += count;
        for (int j = 0; j < order.Count; j++)
        {
            double[] rgb = FromLab(centers[order[j]]);
            clusterWeights[j] = counts[order[j]] / total;
            for (int axis = 0; axis < 3; axis++)
            {
                double c = Math.Max(0, Math.Min(1, rgb[axis]));
                if (toLinear) c = SrgbToLinear((float)c);
                result[j*3+axis] = (int)Math.Round(c * 255);
            }
        }
        return result;
    }

    private static int Nearest(double[] lab, System.Collections.Generic.List<double[]> centers)
    {
        int best = 0;
        double distance = double.MaxValue;
        for (int j = 0; j < centers.Count; j++)
        {
            double d = Distance(lab, centers[j]);
            if (d < distance) { distance = d; best = j; }
        }
        return best;
    }

    private static double Distance(double[] a, double[] b)
    {
        double x = a[0]-b[0], y = a[1]-b[1], z = a[2]-b[2];
        return x*x+y*y+z*z;
    }

    private static double LabF(double t) { return t > 216.0/24389 ? Math.Pow(t, 1.0/3) : (24389.0/27*t+16)/116; }
    private static double LabInv(double t) { double cube = t*t*t; return cube > 216.0/24389 ? cube : (116*t-16)*27/24389; }
    private static double[] ToLab(double r, double g, double b)
    {
        r = SrgbToLinear((float)(r/255)); g = SrgbToLinear((float)(g/255)); b = SrgbToLinear((float)(b/255));
        double x = LabF((0.4124564*r+0.3575761*g+0.1804375*b)/0.95047);
        double y = LabF(0.2126729*r+0.7151522*g+0.0721750*b);
        double z = LabF((0.0193339*r+0.1191920*g+0.9503041*b)/1.08883);
        return new double[] { 116*y-16, 500*(x-y), 200*(y-z) };
    }
    private static double Encode(double c) { return c <= 0.0031308 ? 12.92*c : 1.055*Math.Pow(c, 1.0/2.4)-0.055; }
    private static double[] FromLab(double[] lab)
    {
        double fy = (lab[0]+16)/116;
        double x = 0.95047*LabInv(fy+lab[1]/500), y = LabInv(fy), z = 1.08883*LabInv(fy-lab[2]/200);
        return new double[] { Encode(3.2404542*x-1.5371385*y-0.4985314*z),
            Encode(-0.9692660*x+1.8760108*y+0.0415560*z), Encode(0.0556434*x-0.2040259*y+1.0572252*z) };
    }

    private static float SrgbToLinear(float c)
    {
        return (c <= 0.04045f)
            ? c / 12.92f
            : (float)Math.Pow((c + 0.055f) / 1.055f, 2.4);
    }
}"

        local provider = dotNetObject "Microsoft.CSharp.CSharpCodeProvider"
        local params   = dotNetObject "System.CodeDom.Compiler.CompilerParameters"
        params.GenerateInMemory   = true
        params.GenerateExecutable = false
        params.ReferencedAssemblies.Add "System.dll"
        params.ReferencedAssemblies.Add "System.Drawing.dll"
        params.ReferencedAssemblies.Add "System.Windows.Forms.dll"

        -- Resolve WPF assembly paths via a real Type instance
        local typeClass = dotNetClass "System.Type"
        local pcType = typeClass.GetType "System.Windows.Media.Imaging.BitmapDecoder, PresentationCore, Version=4.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35"
        local wbType = typeClass.GetType "System.Windows.DependencyObject, WindowsBase, Version=4.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35"
        local xamlType = typeClass.GetType "System.Xaml.XamlReader, System.Xaml, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089"
        params.ReferencedAssemblies.Add pcType.Assembly.Location
        params.ReferencedAssemblies.Add wbType.Assembly.Location
        params.ReferencedAssemblies.Add xamlType.Assembly.Location

        -- Write to temp .cs, compile from file, delete temp
        -- Use a typed string array for the compiler's source-file overload.
        tmpBase = (dotNetClass "System.IO.Path").GetTempFileName()
        csFile = tmpBase + ".cs"
        (dotNetClass "System.IO.File").WriteAllText csFile src
        (dotNetClass "System.IO.File").Delete tmpBase

        local al       = dotNetObject "System.Collections.ArrayList"
        al.Add csFile
        local strType   = (dotNetObject "System.String" "").GetType()
        local fileArray = al.ToArray strType
        local compResult = provider.CompileAssemblyFromFile params fileArray

        if compResult.Errors.HasErrors then (
            local sb = dotNetObject "System.Text.StringBuilder"
            sb.AppendLine "C# compile errors:"
            local errColl  = compResult.Errors
            local errCount = errColl.Count
            for i = 0 to errCount - 1 do (
                local err = errColl.get_Item i
                sb.Append "  ("
                sb.Append err.Line
                sb.Append "): "
                sb.AppendLine err.ErrorText
            )
            format "%" (sb.ToString())
        ) else (
            local asm = compResult.CompiledAssembly
            result = asm.CreateInstance "ColorExtractor"
            format "ColorExtractor compiled OK\n"
        )
    ) catch (
        format "compileColorExtractor error: %\n" (getCurrentException())
    )
    -- Also release temporary files when compilation or assembly loading fails.
    for path in #(csFile, tmpBase) where path != undefined do try ((dotNetClass "System.IO.File").Delete path) catch()
    result
)

--------------------------------------------------------------------------------
-- 2. Load a thumbnail without retaining a source-file lock
--------------------------------------------------------------------------------
fn loadThumbBitmap filePath maxW maxH = (
    local result = undefined
    try (
        if ce_ColorExtractor == undefined do
            ce_ColorExtractor = compileColorExtractor()
        if ce_ColorExtractor != undefined do
            result = ce_ColorExtractor.LoadThumbnail filePath maxW maxH
    ) catch (
        format "loadThumbBitmap error: %\n" (getCurrentException())
    )
    result
)

--------------------------------------------------------------------------------
-- 3. Call C# extractor, convert flat int[] -> MaxScript color array
--------------------------------------------------------------------------------
fn extractDominantColors bmp numColors:ce_MaxPaletteColors blurStrength:ce_ExtractionBlurPasses maxSamples:ce_ExtractionMaxSamples toLinear:false = (
    local result = #()
    try (
        -- Compile extractor on first use
        if ce_ColorExtractor == undefined do
            ce_ColorExtractor = compileColorExtractor()

        if ce_ColorExtractor == undefined do (
            format "Color extractor failed to compile.\n"
            return #()
        )

        -- Call the C# method — all heavy work happens inside .NET
        local raw = ce_ColorExtractor.ExtractColors bmp numColors blurStrength maxSamples toLinear

        -- raw is auto-converted to a MaxScript array by the bridge -- use .count and 1-based indexing
        local len = raw.count
        local i   = 1
        while i <= len - 2 do (
            append result (color raw[i] raw[i+1] raw[i+2])
            i += 3
        )
    ) catch (
        format "extractDominantColors error: %\n" (getCurrentException())
    )
    result
)

--------------------------------------------------------------------------------
-- 4. Rollout
--------------------------------------------------------------------------------
try(destroyDialog ColorExtractor_rollout)catch()
rollout ColorExtractor_rollout ("Color Extractor v" + ce_Version) width:340 height:762 (

    local installedMapSupport = undefined
    local preferencesFile = (getDir #plugcfg) + "/ColorExtractor.ini"
    local preferencesReady = false

    dotNetControl pb "System.Windows.Forms.PictureBox" width:310 height:290 pos:[15,10]

    label  lbl_info    ""               pos:[15,308] width:310 align:#left
    button btn_pick    "Pick image…"    pos:[15,326]  width:148 height:26
    button btn_clear   "Clear"          pos:[177,326] width:148 height:26
    button btn_extract "Extract Colors" pos:[15,466] width:125 height:26
    spinner spn_colors "Colors:" pos:[148,471] width:85 fieldWidth:32 range:[ce_MinPaletteColors,ce_MaxPaletteColors,ce_MaxPaletteColors] type:#integer tooltip:"Maximum number of dominant colors to extract"
    checkbox chk_linear "Linear" pos:[242,471] checked:ce_DefaultLinear
    label  lbl_status  ""               pos:[15,498] width:310 align:#left

    groupBox grp_background "Background exclusion" pos:[15,358] width:310 height:100
    checkbox chk_background "Ignore background" pos:[25,377] checked:ce_DefaultIgnoreBackground
    checkbox chk_mask "Show mask" pos:[204,377] checked:true enabled:false
    colorpicker cp_background "Color:" pos:[26,400] width:139 height:22 color:(color 255 255 255) modal:false enabled:false tooltip:"Background RGB from the unmodified thumbnail"
    checkbutton btn_background "Pick from image" pos:[25,426] width:140 height:23 enabled:false
    spinner spn_threshold "Threshold:" pos:[180,405] width:135 fieldWidth:48 range:[0,ce_MaxMaskDistance,ce_DefaultThreshold] type:#float scale:0.5 enabled:false tooltip:"Lab distance: colors at or below this value are excluded everywhere"
    spinner spn_softness "Softness:" pos:[181,431] width:133 fieldWidth:48 range:[0,ce_MaxMaskDistance,ce_DefaultSoftness] type:#float scale:0.5 enabled:false tooltip:"Lab transition width; zero gives a hard mask"

    -- 16 colour swatches — left = most dominant, right = least
    colorpicker cp1  "" pos:[13, 522] width:22 height:24 modal:false
    colorpicker cp2  "" pos:[32, 522] width:22 height:24 modal:false
    colorpicker cp3  "" pos:[51, 522] width:22 height:24 modal:false
    colorpicker cp4  "" pos:[70, 522] width:22 height:24 modal:false
    colorpicker cp5  "" pos:[89, 522] width:22 height:24 modal:false
    colorpicker cp6  "" pos:[108,522] width:22 height:24 modal:false
    colorpicker cp7  "" pos:[127,522] width:22 height:24 modal:false
    colorpicker cp8  "" pos:[146,522] width:22 height:24 modal:false
    colorpicker cp9  "" pos:[165,522] width:22 height:24 modal:false
    colorpicker cp10 "" pos:[184,522] width:22 height:24 modal:false
    colorpicker cp11 "" pos:[203,522] width:22 height:24 modal:false
    colorpicker cp12 "" pos:[222,522] width:22 height:24 modal:false
    colorpicker cp13 "" pos:[241,522] width:22 height:24 modal:false
    colorpicker cp14 "" pos:[260,522] width:22 height:24 modal:false
    colorpicker cp15 "" pos:[279,522] width:22 height:24 modal:false
    colorpicker cp16 "" pos:[298,522] width:22 height:24 modal:false

    label lbl_renderer "" pos:[15,553] width:310
    mapbutton map_fstorm "FStorm RandomColor" pos:[15,575] width:310 height:26 enabled:false tooltip:"Requires installed FStorm and its RandomColor map"
    mapbutton map_fstorm_multi "FStorm MultiTex" pos:[15,607] width:310 height:26 enabled:false tooltip:"Requires installed FStorm and its MultiTex map"

    mapbutton map_vray "V-Ray MultiSubTex" pos:[15,639] width:310 height:26 enabled:false
    mapbutton map_corona "Corona MultiMap" pos:[15,671] width:310 height:26 enabled:false
    mapbutton map_arnold "Arnold Switch RGBA" pos:[15,703] width:310 height:26 enabled:false tooltip:"Index selects the palette color (0-based); no random driver"
    label lbl_copyright "© 2026 Klemens Neumann" pos:[15,738] width:310 align:#center

    fn paletteSwatches = #(cp1,cp2,cp3,cp4,cp5,cp6,cp7,cp8,cp9,cp10,cp11,cp12,cp13,cp14,cp15,cp16)

    fn refreshPaletteSwatches = (
        local swatches = paletteSwatches()
        for i = 1 to swatches.count do (
            swatches[i].color = if i <= ce_DominantColors.count then ce_DominantColors[i] else ce_EmptySwatchColor
        )
    )

    fn protectPaletteSwatches = (
        if ce_ColorExtractor == undefined do ce_ColorExtractor = compileColorExtractor()
        if ce_ColorExtractor == undefined do throw "Palette swatch protection could not initialize"
        for swatch in paletteSwatches() do (
            swatch.tooltip = "Extracted color; right-click Copy, then Paste into a destination swatch"
            for hwnd in swatch.hwnd where (UIAccessor.GetWindowClassName hwnd) == "ColorSwatch" do (
                ce_ColorExtractor.ProtectPaletteSwatch (hwnd as integer64)
            )
        )
        if ce_ColorExtractor.ProtectedPaletteSwatchCount != (paletteSwatches()).count do throw "Not all palette swatches were protected"
    )

    fn updateBackgroundControls = (
        local state = chk_background.checked
        cp_background.enabled = state
        btn_background.enabled = state
        spn_threshold.enabled = state
        spn_softness.enabled = state
        chk_mask.enabled = state
    )

    fn readPreference key fallback = (
        local raw = try (getINISetting preferencesFile "Preferences" key) catch ("")
        if raw == "" do return fallback
        if classOf fallback == BooleanClass then (
            case (toLower raw) of (
                "true": true
                "false": false
                default: fallback
            )
        ) else (
            -- Cast numeric text only; never evaluate preferences as MAXScript.
            local value = try (raw as float) catch (undefined)
            local minimum = if key == "MaxColors" then ce_MinPaletteColors else 0.0
            local maximum = if key == "MaxColors" then ce_MaxPaletteColors else ce_MaxMaskDistance
            if value == undefined do return fallback
            if (dotNetClass "System.Double").IsNaN value or (dotNetClass "System.Double").IsInfinity value do return fallback
            if value < minimum or value > maximum do return fallback
            if key == "MaxColors" then (if value == floor value then value as integer else fallback) else value
        )
    )

    fn loadPreferences = (
        preferencesReady = false
        chk_background.checked = readPreference "IgnoreBackground" ce_DefaultIgnoreBackground
        spn_threshold.value = readPreference "Threshold" ce_DefaultThreshold
        spn_softness.value = readPreference "Softness" ce_DefaultSoftness
        spn_colors.value = readPreference "MaxColors" ce_MaxPaletteColors
        chk_linear.checked = readPreference "Linear" ce_DefaultLinear
        updateBackgroundControls()
        preferencesReady = true
    )

    fn savePreferences = (
        if not preferencesReady do return false
        try (
            local values = #(
                #("IgnoreBackground", chk_background.checked),
                #("Threshold", spn_threshold.value),
                #("Softness", spn_softness.value),
                #("MaxColors", spn_colors.value),
                #("Linear", chk_linear.checked)
            )
            for entry in values do (
                if not (setINISetting preferencesFile "Preferences" entry[1] (entry[2] as string)) do throw "Could not write preferences file"
            )
            true
        ) catch (
            format "Color Extractor preferences could not be saved: %\n" (getCurrentException())
            false
        )
    )

    -- Shared output descriptors keep discovery, lifecycle and UI in sync.
    fn outputSpecs = #(
        #(map_fstorm, #randomColor, "FStorm RandomColor"),
        #(map_fstorm_multi, #multiTex, "FStorm MultiTex"),
        #(map_vray, #vray, "V-Ray MultiSubTex"),
        #(map_corona, #corona, "Corona MultiMap"),
        #(map_arnold, #arnold, "Arnold Switch RGBA")
    )

    fn cancelBackgroundPick = (
        btn_background.checked = false
        pb.Cursor = (dotNetClass "System.Windows.Forms.Cursors").Default
    )

    fn clearMapOutputs = (
        for spec in outputSpecs() do (
            spec[1].map = undefined
            spec[1].text = spec[3]
            spec[1].enabled = false
        )
    )

    fn hasMapSupport mapKind = (paletteMapClass installedMapSupport mapKind) != undefined

    fn rebuildMapOutputs = (
        clearMapOutputs()
        local available = 0
        local created = 0
        for spec in outputSpecs() do (
            local control = spec[1]
            local kind = spec[2]
            local title = spec[3]
            control.tooltip = title + ": map class is not installed"
            if hasMapSupport kind do (
                available += 1
                control.tooltip = if kind == #arnold then "Extract colors to enable Arnold; Index selects the palette color (0-based)" else "Extract colors to enable " + title
                if ce_DominantColors.count > 0 do try (
                    local output = createPaletteMap installedMapSupport kind ce_DominantColors
                    if output == undefined do throw "No usable palette slots"
                    local m = output.texture
                    local n = output.colorCount
                    control.map = m
                    control.text = title + " (" + n as string + ") - drag to slot"
                    control.tooltip = case kind of (
                        #randomColor: "Palette colors with equal chances"
                        #vray: "Sequential IDs 1..N; default ID selection; equal probabilities in Random mode"
                        #corona: "Random by instance; equal frequencies; no color variation"
                        #arnold: ("Palette in inputs 0.." + (n-1) as string + "; Index selects the color; no random driver")
                        default: "Sequential IDs; palette colors without texture overrides"
                    )
                    control.enabled = true
                    created += 1
                ) catch (
                    control.map = undefined
                    control.tooltip = title + " creation failed; see Listener"
                    format "% output error: %\n" title (getCurrentException())
                )
            )
        )
        lbl_renderer.text = if available > 0 then ("Installed palette map types: " + available as string) else "No supported renderer maps installed"
        if ce_DominantColors.count > 0 do (
            lbl_status.text = if created > 0 then "Palette ready - drag a map below." else if available > 0 then "Palette maps failed. See Listener." else "Palette ready; no supported maps installed."
        )
        true
    )

    fn acceptOutputMap kind theMap = (
        local expectedClass = paletteMapClass installedMapSupport kind
        if expectedClass == undefined or (theMap != undefined and classOf theMap != expectedClass) do (
            rebuildMapOutputs()
            lbl_status.text = "Use the matching map type for this output."
        )
    )

    fn clearOutputMap control title = (
        control.map = undefined
        control.enabled = false
        control.text = title
        lbl_status.text = "Map cleared."
    )

    fn invalidatePalette = (
        ce_DominantColors = #()
        clearMapOutputs()
        refreshPaletteSwatches()
    )

    fn configureBackground = (
        if ce_ColorExtractor != undefined do (
            local c = cp_background.color
            ce_ColorExtractor.ConfigureMask chk_background.checked (c.r as integer) (c.g as integer) (c.b as integer) spn_threshold.value spn_softness.value
        )
    )

    fn disposePreview = (
        pb.Image = undefined
        if ce_PreviewBitmap != undefined do (
            ce_PreviewBitmap.Dispose()
            ce_PreviewBitmap = undefined
        )
    )

    fn refreshPreview = (
        disposePreview()
        if ce_ThumbBitmap != undefined do (
            configureBackground()
            try (
                if chk_background.checked and chk_mask.checked then (
                    ce_PreviewBitmap = ce_ColorExtractor.CreateMaskPreview ce_ThumbBitmap
                    pb.Image = ce_PreviewBitmap
                ) else pb.Image = ce_ThumbBitmap
            ) catch (
                pb.Image = ce_ThumbBitmap
                lbl_status.text = "Mask preview failed; see Listener."
                format "Mask preview error: %\n" (getCurrentException())
            )
        )
    )

    fn backgroundChanged = (
        invalidatePalette()
        refreshPreview()
        if ce_ThumbBitmap != undefined do lbl_status.text = "Settings changed - click Extract Colors."
    )

    fn releaseImage = (
        cancelBackgroundPick()
        disposePreview()
        if ce_ThumbBitmap != undefined do (
            ce_ThumbBitmap.Dispose()
            ce_ThumbBitmap = undefined
        )
        invalidatePalette()
    )

    fn loadSource src = (
        releaseImage()
        lbl_info.text = ""
        ce_ThumbBitmap = loadThumbBitmap src 310 290
        if ce_ThumbBitmap != undefined then (
            refreshPreview()
            lbl_info.text = (filenameFromPath src) + "  (" + (ce_ThumbBitmap.Width as string) + "x" + (ce_ThumbBitmap.Height as string) + ")"
            lbl_status.text = "Ready - click Extract Colors."
        ) else lbl_status.text = "Failed to load image; see Listener."
        ce_ThumbBitmap != undefined
    )

    fn pickBackgroundAt x y = (
        if ce_ThumbBitmap == undefined do return false
        local picked = ce_ColorExtractor.PickPixel ce_ThumbBitmap pb.ClientSize.Width pb.ClientSize.Height x y
        if picked.count == 3 then (
            cp_background.color = color picked[1] picked[2] picked[3]
            cancelBackgroundPick()
            backgroundChanged()
            true
        ) else (
            lbl_status.text = "Click inside the image on a visible pixel."
            false
        )
    )

    on ColorExtractor_rollout open do (
        pb.SizeMode    = (dotNetClass "System.Windows.Forms.PictureBoxSizeMode").Zoom
        pb.BackColor   = (dotNetClass "System.Drawing.Color").FromArgb 45 45 48
        pb.BorderStyle = (dotNetClass "System.Windows.Forms.BorderStyle").FixedSingle
        -- Initialize every output to None before inspecting plugin availability.
        invalidatePalette()
        loadPreferences()
        protectPaletteSwatches()
        -- Discover installed renderer/map classes once per tool session.
        installedMapSupport = discoverPaletteMapSupport()
        rebuildMapOutputs()
    )

    on ColorExtractor_rollout close do (
        savePreferences()
        releaseImage()
        if ce_ColorExtractor != undefined do ce_ColorExtractor.ReleasePaletteSwatches()
        ce_ColorExtractor = undefined -- assembly stays loaded until Max exits
    )


    on chk_background changed state do (
        updateBackgroundControls()
        cancelBackgroundPick()
        backgroundChanged()
        savePreferences()
    )
    on cp_background changed c do backgroundChanged()
    on spn_threshold changed value do (backgroundChanged(); savePreferences())
    on spn_softness changed value do (backgroundChanged(); savePreferences())
    on chk_mask changed state do refreshPreview()
    on chk_linear changed state do (
        invalidatePalette()
        if ce_ThumbBitmap != undefined do lbl_status.text = "Output changed - click Extract Colors."
        savePreferences()
    )
    on spn_colors changed value do (
        invalidatePalette()
        if ce_ThumbBitmap != undefined do lbl_status.text = "Color count changed - click Extract Colors."
        savePreferences()
    )
    on btn_background changed state do (
        if state and ce_ThumbBitmap != undefined then (
            pb.Cursor = (dotNetClass "System.Windows.Forms.Cursors").Cross
            lbl_status.text = "Click background in image; right-click cancels."
        ) else (
            cancelBackgroundPick()
            if ce_ThumbBitmap == undefined do lbl_status.text = "Load an image first."
        )
    )
    on pb MouseDown e do (
        if btn_background.checked and ce_ThumbBitmap != undefined do (
            if e.Button == (dotNetClass "System.Windows.Forms.MouseButtons").Right then (
                cancelBackgroundPick()
                lbl_status.text = "Background picking canceled."
            ) else if e.Button == (dotNetClass "System.Windows.Forms.MouseButtons").Left do (
                pickBackgroundAt e.X e.Y
            )
        )
    )

    on btn_pick pressed do (
        local src = getOpenFileName caption:"Pick source image" types:"Images|*.jpg;*.jpeg;*.png;*.tif;*.tga;*.bmp;*.exr|All|*.*"
        if src != undefined do loadSource src
    )

    on btn_clear pressed do (
        releaseImage()
        lbl_info.text = ""
        lbl_status.text = ""
    )

    on btn_extract pressed do (
        if ce_ThumbBitmap == undefined then (
            lbl_status.text = "Load an image first."
        ) else (
            lbl_status.text = "Extracting… (compiling C# on first run)"
            windows.processPostedMessages()

            cancelBackgroundPick()
            invalidatePalette()
            configureBackground()
            ce_DominantColors = extractDominantColors ce_ThumbBitmap numColors:spn_colors.value blurStrength:ce_ExtractionBlurPasses maxSamples:ce_ExtractionMaxSamples toLinear:chk_linear.checked

            refreshPaletteSwatches()

            if ce_DominantColors.count == 0 then
			(
				lbl_status.text = "No foreground pixels remain, or extraction failed."
			)
            else rebuildMapOutputs()
        )
    )

    -- Incoming paste/drop operations cannot change the extracted palette.
    on cp1 changed c do refreshPaletteSwatches()
    on cp2 changed c do refreshPaletteSwatches()
    on cp3 changed c do refreshPaletteSwatches()
    on cp4 changed c do refreshPaletteSwatches()
    on cp5 changed c do refreshPaletteSwatches()
    on cp6 changed c do refreshPaletteSwatches()
    on cp7 changed c do refreshPaletteSwatches()
    on cp8 changed c do refreshPaletteSwatches()
    on cp9 changed c do refreshPaletteSwatches()
    on cp10 changed c do refreshPaletteSwatches()
    on cp11 changed c do refreshPaletteSwatches()
    on cp12 changed c do refreshPaletteSwatches()
    on cp13 changed c do refreshPaletteSwatches()
    on cp14 changed c do refreshPaletteSwatches()
    on cp15 changed c do refreshPaletteSwatches()
    on cp16 changed c do refreshPaletteSwatches()

    -- Reject incompatible incoming maps; dragging generated maps out still works.
    on map_fstorm picked m do acceptOutputMap #randomColor m
    on map_fstorm_multi picked m do acceptOutputMap #multiTex m
    on map_vray picked m do acceptOutputMap #vray m
    on map_corona picked m do acceptOutputMap #corona m
    on map_arnold picked m do acceptOutputMap #arnold m
    on map_fstorm rightclick do clearOutputMap map_fstorm "FStorm RandomColor"
    on map_fstorm_multi rightclick do clearOutputMap map_fstorm_multi "FStorm MultiTex"
    on map_vray rightclick do clearOutputMap map_vray "V-Ray MultiSubTex"
    on map_corona rightclick do clearOutputMap map_corona "Corona MultiMap"
    on map_arnold rightclick do clearOutputMap map_arnold "Arnold Switch RGBA"

)

-- Launch
createDialog ColorExtractor_rollout style:#(#style_titlebar, #style_sysmenu)
)
