-- Run after ColorExtractor.ms in 3ds Max. Uses a temporary synthetic image,
-- exercises actual PictureBox MouseDown delivery, then clears the rollout.
(
    local r = ColorExtractor_rollout
    -- Exercise controls without saving synthetic test settings to the user INI.
    r.preferencesReady = false
    r.chk_background.checked = false
    r.spn_threshold.value = 10
    r.spn_softness.value = 5
    r.spn_colors.value = 16
    r.chk_linear.checked = true
    local originalRenderer = renderers.current
    local originalSupport = r.installedMapSupport
    local savedRandomClass = originalSupport.randomColorClass
    local savedMultiClass = originalSupport.multiTexClass
    local savedRendererName = originalSupport.fstormRendererClassName
    fn check condition message = (if not condition do throw message)
    local path = (getDir #temp) + "/ColorExtractor-validation.png"
    local palettePath = (getDir #temp) + "/ColorExtractor-validation16.png"
    local bmp = dotNetObject "System.Drawing.Bitmap" 310 290
    local graphics = (dotNetClass "System.Drawing.Graphics").FromImage bmp
    graphics.Clear (dotNetClass "System.Drawing.Color").White
    graphics.FillRectangle (dotNetClass "System.Drawing.Brushes").Red 100 70 100 140
    graphics.Dispose()
    bmp.Save path (dotNetClass "System.Drawing.Imaging.ImageFormat").Png
    bmp.Dispose()
    try (
        check (r.loadSource path) "Synthetic image failed to load"
        check (not r.chk_background.checked) "Background exclusion should default to off"
        r.chk_background.checked = true
        r.chk_background.changed true
        check r.cp_background.enabled "Background controls should be enabled"
        local previewPixel = r.pb.Image.GetPixel 10 10
        check (previewPixel.R == 255 and previewPixel.G == 0 and previewPixel.B == 255) "Background overlay should be magenta"

        r.btn_background.checked = true
        r.btn_background.changed true
        local flags = dotNet.combineEnums (dotNetClass "System.Reflection.BindingFlags").Instance (dotNetClass "System.Reflection.BindingFlags").NonPublic
        local method = (r.pb.GetType()).GetMethod "OnMouseDown" flags
        local mouseEvent = dotNetObject "System.Windows.Forms.MouseEventArgs" (dotNetClass "System.Windows.Forms.MouseButtons").Left 1 10 10 0
        local arguments = dotNet.ValueToDotNetObject #(mouseEvent) (dotNetClass "System.Object[]")
        method.Invoke r.pb arguments
        check (r.cp_background.color == color 255 255 255) "Eyedropper should sample source white, not magenta preview"
        check (not r.btn_background.checked) "Valid pick should disarm eyedropper"

        r.chk_linear.checked = false
        r.chk_linear.changed false
        r.btn_extract.pressed()
        check (r.cp1.color == color 255 0 0) "Masked extraction should return red foreground"
        if r.hasMapSupport #randomColor do (
            check (r.map_fstorm.map != undefined) "FStorm map should be created"
            check (r.map_fstorm.map.colors[1] == color 255 0 0) "FStorm map should use extracted foreground"
        )
        if r.hasMapSupport #multiTex do (
            check (r.map_fstorm_multi.map != undefined) "FStorm MultiTex map should be created"
            check (r.map_fstorm_multi.map.num_ids == 1) "MultiTex should use only the retained foreground color"
            check (r.map_fstorm_multi.map.colors[1] == color 255 0 0) "MultiTex should use extracted foreground"
        )
        local existingMap = r.map_fstorm.map
        r.chk_mask.checked = false
        r.chk_mask.changed false
        previewPixel = r.pb.Image.GetPixel 10 10
        check (previewPixel.G == 255) "Hiding mask should restore source image"
        check (r.map_fstorm.map == existingMap) "Preview-only changes should retain palette map"

        r.spn_threshold.value = 250
        r.spn_threshold.changed 250
        check (r.map_fstorm.map == undefined) "Mask changes should invalidate stale map"
        r.btn_extract.pressed()
        check (r.cp1.color == color 20 20 20) "Fully excluded image should clear swatches"
        check (r.map_fstorm.map == undefined) "Fully excluded image should not create a map"
        check (not r.map_fstorm.enabled and not r.map_fstorm_multi.enabled) "Empty palette should disable both map outputs"

        r.chk_background.checked = false
        r.chk_background.changed false
        check (not r.cp_background.enabled) "Disabled exclusion should disable its controls"
        r.btn_extract.pressed()
        check (r.cp1.color.r > 240 and r.cp1.color.g > 240) "Disabled mask should restore white as dominant"

        -- Sixteen broad color regions exercise every MultiTex output slot.
        bmp = dotNetObject "System.Drawing.Bitmap" 310 290
        graphics = (dotNetClass "System.Drawing.Graphics").FromImage bmp
        for row = 0 to 3 do for col = 0 to 3 do (
            local brush = dotNetObject "System.Drawing.SolidBrush" ((dotNetClass "System.Drawing.Color").FromArgb (col*85) (row*85) 128)
            local x1 = (col*310.0/4) as integer
            local x2 = ((col+1)*310.0/4) as integer
            local y1 = (row*290.0/4) as integer
            local y2 = ((row+1)*290.0/4) as integer
            graphics.FillRectangle brush x1 y1 (x2-x1) (y2-y1)
            brush.Dispose()
        )
        graphics.Dispose()
        bmp.Save palettePath (dotNetClass "System.Drawing.Imaging.ImageFormat").Png
        bmp.Dispose()
        check (r.loadSource palettePath) "Sixteen-color source should load"
        r.chk_background.checked = true
        r.chk_background.changed true
        r.spn_threshold.value = 0
        r.spn_threshold.changed 0
        r.spn_softness.value = 0
        r.spn_softness.changed 0
        r.btn_extract.pressed()
        if r.hasMapSupport #multiTex then (
            local multi = r.map_fstorm_multi.map
            check (multi != undefined and multi.num_ids == 16) "MultiTex should activate all 16 extracted colors"
            local swatches = #(r.cp1,r.cp2,r.cp3,r.cp4,r.cp5,r.cp6,r.cp7,r.cp8,r.cp9,r.cp10,r.cp11,r.cp12,r.cp13,r.cp14,r.cp15,r.cp16)
            for i = 1 to 16 do (
                check (multi.colors[i] == swatches[i].color) "MultiTex slot must match corresponding extracted color"
                check (multi.ids[i] == i) "MultiTex IDs should be sequential"
                check (multi.textures[i] == undefined and multi.textures_on[i]) "MultiTex entries should be enabled and use colors without texture overrides"
            )
            check r.map_fstorm_multi.enabled "Installed MultiTex should enable its generated output"
            if r.hasMapSupport #randomColor do (
                local randomMap = r.map_fstorm.map
                check r.map_fstorm.enabled "Installed RandomColor should enable its generated output"
                r.map_fstorm_multi.map = randomMap
                r.map_fstorm_multi.picked randomMap
                check ((classOf r.map_fstorm_multi.map) as string == "FStormMultiTex") "Wrong map type should be rejected and correct output restored"
            )
        ) else (
            check (not r.map_fstorm_multi.enabled) "Unavailable MultiTex must remain disabled"
        )

        -- Map availability is independent of the active production renderer.
        if savedRandomClass != undefined or savedMultiClass != undefined do (
            renderers.current = Default_Scanline_Renderer()
            r.rebuildMapOutputs()
            check (r.map_fstorm.enabled == (savedRandomClass != undefined)) "Installed RandomColor should work with Scanline active"
            check (r.map_fstorm_multi.enabled == (savedMultiClass != undefined)) "Installed MultiTex should work with Scanline active"

            -- Simulate individually missing map classes without unloading plugins.
            originalSupport.multiTexClass = undefined
            r.rebuildMapOutputs()
            check (not r.map_fstorm_multi.enabled and r.map_fstorm_multi.map == undefined) "Missing MultiTex class must disable only its output"
            check (r.map_fstorm.enabled == (savedRandomClass != undefined)) "Missing MultiTex must not disable available RandomColor"
            originalSupport.multiTexClass = savedMultiClass
            originalSupport.randomColorClass = undefined
            r.rebuildMapOutputs()
            check (not r.map_fstorm.enabled and r.map_fstorm.map == undefined) "Missing RandomColor class must disable only its output"
            check (r.map_fstorm_multi.enabled == (savedMultiClass != undefined)) "Missing RandomColor must not disable available MultiTex"
            originalSupport.randomColorClass = savedRandomClass
            originalSupport.fstormRendererClassName = undefined
            r.rebuildMapOutputs()
            check (not r.map_fstorm.enabled and not r.map_fstorm_multi.enabled) "Missing renderer must disable both outputs even if map classes exist"
            originalSupport.fstormRendererClassName = savedRendererName
            renderers.current = originalRenderer
            r.rebuildMapOutputs()
        )
        r.btn_clear.pressed()
        check (r.pb.Image == undefined and r.map_fstorm.map == undefined and r.map_fstorm_multi.map == undefined) "Clear should release image and stale maps"
        check (not r.map_fstorm.enabled and not r.map_fstorm_multi.enabled) "Clear should disable map buttons"
        r.chk_background.checked = false
        r.chk_background.changed false
        r.spn_threshold.value = 10
        r.spn_softness.value = 5
        r.chk_mask.checked = true
        r.chk_linear.checked = true
        check (deleteFile path) "Thumbnail loader must release the source file"
        check (deleteFile palettePath) "Sixteen-color source must also be released"
        r.loadPreferences()
        "PASS: masking, 16 MultiTex colors, installed plugin detection, Scanline-active output, missing map/renderer gating and cleanup."
    ) catch (
        originalSupport.randomColorClass = savedRandomClass
        originalSupport.multiTexClass = savedMultiClass
        originalSupport.fstormRendererClassName = savedRendererName
        renderers.current = originalRenderer
        r.btn_clear.pressed()
        deleteFile path
        deleteFile palettePath
        r.loadPreferences()
        throw()
    )
)
