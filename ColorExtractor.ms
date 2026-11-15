(
-- Thumbnail viewer + dominant colour extractor
-- Image load/display: MaxScript dotNet bridge (PictureBox)
-- Color extraction: C# class compiled at runtime via CSharpCodeProvider
--   -> blur, pixel sampling and k-means all run inside .NET
--   -> returns a plain int[] (R,G,B triplets) that MaxScript reads safely
-- No file lock. No temp files. No dotNet bridge overload issues.

dotNet.loadAssembly "System.Drawing"
dotNet.loadAssembly "System.Windows.Forms"

global ColorExtractor_rollout -- the main dialog
local ce_Version = "0.2"
local ce_ThumbBitmap    = undefined
local ce_DominantColors = #()
local ce_ColorExtractor = undefined   -- compiled C# instance, created once

-- FStorm 1.5.4b (2023-10-09) added more RandomColor colors; older builds use 4.
-- Source: https://fstormrender.com/forum/forum/releases/12982-fstormrender-for-3ds-max-v1-5-4g
-- Read the renderer class name (e.g. FStormRender_v1_5_3g), not a display label.
-- Unknown version formats default to 4 rather than assuming 8 slots exist.
fn fstormRandomColorLimit rendererClassName = (
    local versionMatch = (dotNetClass "System.Text.RegularExpressions.Regex").Match rendererClassName "^FStormRender_v([0-9]+)_([0-9]+)_([0-9]+)([a-z]?)[0-9]*$" (dotNetClass "System.Text.RegularExpressions.RegexOptions").IgnoreCase
    if not versionMatch.Success do return 4

    local minimumVersion = #(1, 5, 4)
    for i = 1 to 3 do (
        local component = (versionMatch.Groups.Item[i].Value as string) as integer
        if component > minimumVersion[i] do return 8
        if component < minimumVersion[i] do return 4
    )
    -- For 1.5.4 itself, no suffix and suffix 'a' precede the 'b' update.
    local suffix = toLower (versionMatch.Groups.Item[4].Value as string)
    local suffixRank = findString "abcdefghijklmnopqrstuvwxyz" suffix
    if suffix != "" and suffixRank != undefined and suffixRank >= 2 then 8 else 4
)

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- 1.  Compile the C# color extractor (called once on first use)
--     C# source is embedded directly — quotes escaped as \" for MaxScript.
--     Compiled in-memory — no DLL or temp file written to disk.
--------------------------------------------------------------------------------
fn compileColorExtractor = (
    local result = undefined
    try (
        local src = "using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.IO;
using System.Windows.Media.Imaging;
using System.Windows.Media;

public class ColorExtractor
{
    // ==========================================================================
    // LoadThumbnail — three-stage fast path, called from MaxScript instead of
    // the old pure-MaxScript loadThumbBitmap fn.
    //
    // Stage 1: Windows Shell thumbnail cache (instantaneous, no file decode)
    //          Works for any format Explorer has indexed. Uses IShellItemImageFactory
    //          via Shell32 COM interop.
    // Stage 2: WPF BitmapDecoder with scale hint (fast for JPEG/TIFF/PNG/BMP)
    //          Never fully decodes the image — the JPEG decoder skips DCT blocks
    //          that fall outside the target resolution, making a 100 MB file
    //          decode in roughly the same time as a 1 MB file at thumb size.
    // Stage 3: GDI+ full decode fallback (EXR, HDR, TGA via Max codecs)
    //          Same as before — reads via non-locking FileStream.
    // ==========================================================================
    public Bitmap LoadThumbnail(string filePath, int maxW, int maxH)
    {
        // ---- Stage 1: Shell cache ------------------------------------------
        try
        {
            Bitmap shell = LoadFromShellCache(filePath, maxW, maxH);
            if (shell != null) return shell;
        }
        catch { }

        // ---- Stage 2: WPF BitmapDecoder with scale hint --------------------
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
    // This never touches the file on disk if the cache is warm.
    // --------------------------------------------------------------------------
    [ComImport]
    [Guid(\"43826d1e-e718-42ee-bc55-a1e261c37bfe\")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellItem
    {
        void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
        void GetParent(out IShellItem ppsi);
        void GetDisplayName(uint sigdnName, out IntPtr ppszName);
        void GetAttributes(uint sfgaoMask, out uint psfgaoAttribs);
        void Compare(IShellItem psi, uint hint, out int piOrder);
    }

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
    // Stage 2 — WPF BitmapDecoder
    // DecodePixelWidth/Height tells the codec the target size. JPEG decoders
    // honour this by skipping unnecessary DCT coefficient blocks — a 50 MP JPEG
    // decoded to 256 px takes roughly the same time as a 1 MP JPEG.
    // --------------------------------------------------------------------------
    private static Bitmap LoadWithBitmapDecoder(string filePath, int maxW, int maxH)
    {
        Uri uri = new Uri(filePath, UriKind.Absolute);

        BitmapDecoder decoder = BitmapDecoder.Create(
            uri,
            BitmapCreateOptions.DelayCreation,
            BitmapCacheOption.None);

        BitmapFrame frame = decoder.Frames[0];

        // Compute aspect-correct decode size
        double scaleX = (double)maxW / frame.PixelWidth;
        double scaleY = (double)maxH / frame.PixelHeight;
        double scale  = Math.Min(scaleX, scaleY);
        int tw = Math.Max(1, (int)(frame.PixelWidth  * scale));
        int th = Math.Max(1, (int)(frame.PixelHeight * scale));

        // ScaledBitmapSource hints the decoder to the target size
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

    // ==========================================================================
    // ExtractColors — unchanged, operates on the already-loaded thumbnail Bitmap
    // ==========================================================================
    public int[] ExtractColors(Bitmap bmp, int numColors, int blurStrength, int maxSamples, bool toLinear)
    {
        // --- 1. Copy into a fresh same-size Bitmap --------------------------
        Bitmap work = new Bitmap(bmp.Width, bmp.Height);
        using (Graphics g = Graphics.FromImage(work))
        {
            g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
            g.DrawImage(bmp, new Rectangle(0, 0, bmp.Width, bmp.Height));
        }

        // --- 2. Blur via downscale -> upscale (GDI bicubic acts as low-pass) -
        for (int pass = 0; pass < blurStrength; pass++)
        {
            int hw = Math.Max(1, work.Width  / 4);
            int hh = Math.Max(1, work.Height / 4);

            Bitmap small = new Bitmap(hw, hh);
            using (Graphics g = Graphics.FromImage(small))
            {
                g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                g.DrawImage(work, new Rectangle(0, 0, hw, hh));
            }

            Bitmap up = new Bitmap(work.Width, work.Height);
            using (Graphics g = Graphics.FromImage(up))
            {
                g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                g.DrawImage(small, new Rectangle(0, 0, work.Width, work.Height));
            }
            small.Dispose();
            work.Dispose();
            work = up;
        }

        // --- 3. Sample pixels via LockBits ----------------------------------
        int W = work.Width, H = work.Height;
        int total = W * H;
        int step  = Math.Max(1, total / maxSamples);

        BitmapData bd = work.LockBits(
            new Rectangle(0, 0, W, H),
            ImageLockMode.ReadOnly,
            System.Drawing.Imaging.PixelFormat.Format32bppArgb);

        int stride  = bd.Stride;
        byte[] data = new byte[Math.Abs(stride) * H];
        Marshal.Copy(bd.Scan0, data, 0, data.Length);
        work.UnlockBits(bd);
        work.Dispose();

        float[][] samples = new float[total / step + 1][];
        int sCount = 0;
        for (int idx = 0; idx < total; idx += step)
        {
            int px = idx % W;
            int py = idx / W;
            int off = py * stride + px * 4;
            samples[sCount++] = new float[] {
                data[off + 2],
                data[off + 1],
                data[off    ]
            };
        }

        // --- 4. K-means -----------------------------------------------------
        int k = Math.Min(numColors, sCount);
        float[][] centroids = new float[k][];
        int seedStep = sCount / k;
        for (int j = 0; j < k; j++)
            centroids[j] = (float[])samples[j * seedStep].Clone();

        int[] assign = new int[sCount];

        for (int iter = 0; iter < 20; iter++)
        {
            bool changed = false;
            for (int i = 0; i < sCount; i++)
            {
                float bestD = float.MaxValue; int bestJ = 0;
                for (int j = 0; j < k; j++)
                {
                    float dr = samples[i][0] - centroids[j][0];
                    float dg = samples[i][1] - centroids[j][1];
                    float db = samples[i][2] - centroids[j][2];
                    float d  = dr*dr + dg*dg + db*db;
                    if (d < bestD) { bestD = d; bestJ = j; }
                }
                if (assign[i] != bestJ) { assign[i] = bestJ; changed = true; }
            }
            if (!changed) break;

            float[] sumR = new float[k], sumG = new float[k], sumB = new float[k];
            int[]   cnt  = new int[k];
            for (int i = 0; i < sCount; i++)
            {
                int j = assign[i];
                sumR[j] += samples[i][0]; sumG[j] += samples[i][1]; sumB[j] += samples[i][2];
                cnt[j]++;
            }
            for (int j = 0; j < k; j++)
                if (cnt[j] > 0)
                    centroids[j] = new float[] { sumR[j]/cnt[j], sumG[j]/cnt[j], sumB[j]/cnt[j] };
        }

        // --- 5. Sort by cluster size ----------------------------------------
        int[] counts = new int[k];
        for (int i = 0; i < sCount; i++) counts[assign[i]]++;
        int[] order = new int[k];
        for (int j = 0; j < k; j++) order[j] = j;
        Array.Sort(order, (a, b2) => counts[b2].CompareTo(counts[a]));

        // --- 6. sRGB -> linear (optional), return flat int[] ----------------
        int[] result = new int[k * 3];
        for (int j = 0; j < k; j++)
        {
            float[] c = centroids[order[j]];
            float r = c[0], g = c[1], b = c[2];
            if (toLinear)
            {
                r = SrgbToLinear(r / 255f) * 255f;
                g = SrgbToLinear(g / 255f) * 255f;
                b = SrgbToLinear(b / 255f) * 255f;
            }
            result[j*3    ] = (int)Math.Round(Math.Max(0, Math.Min(255, r)));
            result[j*3 + 1] = (int)Math.Round(Math.Max(0, Math.Min(255, g)));
            result[j*3 + 2] = (int)Math.Round(Math.Max(0, Math.Min(255, b)));
        }
        return result;
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

        -- Resolve WPF assembly paths via a real Type instance
        local typeClass = dotNetClass "System.Type"
        local pcType = typeClass.GetType "System.Windows.Media.Imaging.BitmapDecoder, PresentationCore, Version=4.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35"
        local wbType = typeClass.GetType "System.Windows.DependencyObject, WindowsBase, Version=4.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35"
        local xamlType = typeClass.GetType "System.Xaml.XamlReader, System.Xaml, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089"
        params.ReferencedAssemblies.Add pcType.Assembly.Location
        params.ReferencedAssemblies.Add wbType.Assembly.Location
        params.ReferencedAssemblies.Add xamlType.Assembly.Location

        -- Write to temp .cs, compile from file, delete temp
        -- (CompileAssemblyFromSource takes string[] which MaxScript can't construct)
        local tmpBase = (dotNetClass "System.IO.Path").GetTempFileName()
        local csFile  = tmpBase + ".cs"
        (dotNetClass "System.IO.File").WriteAllText csFile src
        (dotNetClass "System.IO.File").Delete tmpBase

        local al       = dotNetObject "System.Collections.ArrayList"
        al.Add csFile
        local strType   = (dotNetObject "System.String" "").GetType()
        local fileArray = al.ToArray strType
        local compResult = provider.CompileAssemblyFromFile params fileArray
        try ((dotNetClass "System.IO.File").Delete csFile) catch()

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
    result
)

--------------------------------------------------------------------------------
-- 2. Load Thumbnail (no file locking because is handled via OS methods
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
fn extractDominantColors bmp numColors:16 blurStrength:2 maxSamples:1000 toLinear:false = (
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
--         format "Dominant colors (%):\n" result.count
--         for i = 1 to result.count do
--             format "  [%] %\n" i result[i]
    ) catch (
        format "extractDominantColors error: %\n" (getCurrentException())
    )
    result
)

--------------------------------------------------------------------------------
-- 4. Rollout
--------------------------------------------------------------------------------
try(destroyDialog ColorExtractor_rollout)catch()
rollout ColorExtractor_rollout ("Color Extractor v" + ce_Version) width:340 height:570 (

    dotNetControl pb "System.Windows.Forms.PictureBox" width:310 height:290 pos:[15,10]

    label  lbl_info    ""               pos:[15,308] width:310 align:#left
    button btn_pick    "Pick image…"    pos:[15,326]  width:148 height:26
    button btn_clear   "Clear"          pos:[177,326] width:148 height:26
    button btn_extract "Extract Colors" pos:[15,358]  width:220 height:26
    checkbox chk_linear "Linear" pos:[242,362] checked:true
    label  lbl_status  ""               pos:[15,390] width:310 align:#left

    -- 16 colour swatches — left = most dominant, right = least
    colorpicker cp1  "" pos:[13, 412] width:22 height:24 modal:false
    colorpicker cp2  "" pos:[32, 412] width:22 height:24 modal:false
    colorpicker cp3  "" pos:[51, 412] width:22 height:24 modal:false
    colorpicker cp4  "" pos:[70, 412] width:22 height:24 modal:false
    colorpicker cp5  "" pos:[89, 412] width:22 height:24 modal:false
    colorpicker cp6  "" pos:[108,412] width:22 height:24 modal:false
    colorpicker cp7  "" pos:[127,412] width:22 height:24 modal:false
    colorpicker cp8  "" pos:[146,412] width:22 height:24 modal:false
    colorpicker cp9  "" pos:[165,412] width:22 height:24 modal:false
    colorpicker cp10 "" pos:[184,412] width:22 height:24 modal:false
    colorpicker cp11 "" pos:[203,412] width:22 height:24 modal:false
    colorpicker cp12 "" pos:[222,412] width:22 height:24 modal:false
    colorpicker cp13 "" pos:[241,412] width:22 height:24 modal:false
    colorpicker cp14 "" pos:[260,412] width:22 height:24 modal:false
    colorpicker cp15 "" pos:[279,412] width:22 height:24 modal:false
    colorpicker cp16 "" pos:[298,412] width:22 height:24 modal:false

    mapbutton map_fstorm "<drag to slot>" pos:[15,442] width:310 height:26 tooltip:"FStorm Random Color map — drag into any map slot"

    on ro_ThumbViewer open do (
        pb.SizeMode    = (dotNetClass "System.Windows.Forms.PictureBoxSizeMode").Zoom
        pb.BackColor   = (dotNetClass "System.Drawing.Color").FromArgb 45 45 48
        pb.BorderStyle = (dotNetClass "System.Windows.Forms.BorderStyle").FixedSingle
    )

    on ro_ThumbViewer close do (
        pb.Image = undefined
        if ce_ThumbBitmap != undefined do ( ce_ThumbBitmap.Dispose(); ce_ThumbBitmap = undefined )
        ce_ColorExtractor = undefined   -- release compiled assembly
    )

    on btn_pick pressed do (
        local src = getOpenFileName caption:"Pick source image" types:"Images|*.jpg;*.jpeg;*.png;*.tif;*.tga;*.bmp;*.exr|All|*.*"
        if src != undefined do (
            if ce_ThumbBitmap != undefined do ( pb.Image = undefined; ce_ThumbBitmap.Dispose(); ce_ThumbBitmap = undefined )
            ce_ThumbBitmap = loadThumbBitmap src 310 290
            if ce_ThumbBitmap != undefined then (
                pb.Image = ce_ThumbBitmap
                lbl_info.text   = (filenameFromPath src) + "  (" + (ce_ThumbBitmap.Width as string) + "x" + (ce_ThumbBitmap.Height as string) + ")"
                lbl_status.text = "Ready — click Extract Colors"
            ) else lbl_info.text = "Failed to load image."
        )
    )

    on btn_clear pressed do (
        pb.Image = undefined
        if ce_ThumbBitmap != undefined do ( ce_ThumbBitmap.Dispose(); ce_ThumbBitmap = undefined )
        lbl_info.text = ""; lbl_status.text = ""
    )

    on btn_extract pressed do (
        if ce_ThumbBitmap == undefined then (
            lbl_status.text = "Load an image first."
        ) else (
            lbl_status.text = "Extracting… (compiling C# on first run)"
            windows.processPostedMessages()

            ce_DominantColors = extractDominantColors ce_ThumbBitmap numColors:16 blurStrength:2 maxSamples:1000 toLinear:chk_linear.checked

            local cpList = #(cp1,cp2,cp3,cp4,cp5,cp6,cp7,cp8,cp9,cp10,cp11,cp12,cp13,cp14,cp15,cp16)
            for i = 1 to 16 do
                cpList[i].color = if i <= ce_DominantColors.count then ce_DominantColors[i] else (color 20 20 20)
			
			local RENDERER_FSTORM = matchPattern (renderers.current as string) pattern:"FStormRender_*"

			if ce_DominantColors.count == 0 then
			(
				lbl_status.text = "No colors extracted."
			)
			else if RENDERER_FSTORM then
			(
				-- Build FStormRandomColor map and assign to the mapbutton
				local m = FStormRandomColor()
				local colorLimit = fstormRandomColorLimit ((classOf renderers.current) as string)
				-- Assigning an 8-element array to an older 4-slot map raises:
				-- "Array parameter size fixed, cannot dynamically alter: colors".
				-- Update slots individually and also clamp to the actual parameter sizes,
				-- since the version check alone cannot guarantee the installed map layout.
				local n = amin #(colorLimit, m.colors.count, m.chances.count, ce_DominantColors.count)
				for i = 1 to n do m.colors[i] = ce_DominantColors[i]
				for i = 1 to m.chances.count do
					m.chances[i] = if i <= n then (1.0 / n) else 0.0
				m.id_source  = 0
				m.mix_value  = 1.0
				m.random_seed = 42
				map_fstorm.map  = m
				map_fstorm.text = m.name
				lbl_status.text = ("Done (" + (if chk_linear.checked then "linear" else "sRGB") + ") — ce_DominantColors[1..16] ready")
			)
			else(
				lbl_status.text = ("Fstorm is not set as renderer.")
			)
        )
    )

    on map_fstorm picked theMap do ()

    on map_fstorm rightclick do (
        if map_fstorm.map != undefined do (
            map_fstorm.map = undefined
            lbl_status.text = "Map cleared."
        )
    )
)

-- Launch
createDialog ColorExtractor_rollout style:#(#style_titlebar, #style_sysmenu, #style_resizing)
)
