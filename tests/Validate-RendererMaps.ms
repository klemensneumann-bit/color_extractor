-- Run after ColorExtractor.ms. Tests real installed plugin maps without rendering.
-- Replaces the tool's source image and clears its results on completion.
(
    local r = ColorExtractor_rollout
    -- Exercise controls without saving synthetic test settings to the user INI.
    r.preferencesReady = false
    r.chk_background.checked = false
    r.spn_threshold.value = 10
    r.spn_softness.value = 5
    r.spn_colors.value = 16
    r.chk_linear.checked = true
    local support = r.installedMapSupport
    local saved = #(support.vrayClass, support.coronaClass, support.arnoldClass)
    local renderer = renderers.current
    local savedCount = r.spn_colors.value
    local path = (getDir #temp) + "/ColorExtractor-renderer-validation.png"
    local fields = #(#vrayClass, #coronaClass, #arnoldClass)
    local controls = #(r.map_vray, r.map_corona, r.map_arnold)
    fn check condition message = (if not condition do throw message)
    fn verifyPalette r n = (
        local swatches = #(r.cp1,r.cp2,r.cp3,r.cp4,r.cp5,r.cp6,r.cp7,r.cp8,r.cp9,r.cp10,r.cp11,r.cp12,r.cp13,r.cp14,r.cp15,r.cp16)
        local v = r.map_vray.map
        local c = r.map_corona.map
        local a = r.map_arnold.map
        if r.hasMapSupport #vray do (
            check (v != undefined and r.map_vray.enabled) "V-Ray output missing"
            check (findString r.map_vray.text ("(" + n as string + ")") != undefined) "V-Ray button count differs from populated slots"
            check (v.texmap_num == n and v.texmap_color.count == n) "V-Ray must resize to the extracted palette"
            for i = 1 to n do (
                check (v.texmap_color[i] == swatches[i].color) "V-Ray palette color mismatch"
                check (v.texmap_id[i] == i and v.texmap_on[i]) "V-Ray entries must have sequential enabled IDs"
                check (v.texmap[i] == undefined and not v.texmap_mapOn[i]) "V-Ray texture must not override palette"
                check (v.texmap_mult[i] == 100) "V-Ray entries should have equal probabilities"
            )
            check (v.random_hue == 0 and v.random_saturation == 0 and v.random_gamma == 0) "V-Ray must preserve palette colors"
        )
        if r.hasMapSupport #corona do (
            check (c != undefined and r.map_corona.enabled) "Corona output missing"
            check (findString r.map_corona.text ("(" + n as string + ")") != undefined) "Corona button count differs from populated slots"
            check (c.items == n) "Corona active count must match palette"
            for i = 1 to n do (
                check (c.colors[i] == swatches[i].color) "Corona palette color mismatch"
                check (c.frequency[i] == 1 and c.texmaps[i] == undefined and not c.texmapsOn[i]) "Corona should use colors at equal frequencies"
            )
            check (c.randomizeInstance and not c.randomizePrimitive) "Corona must randomize by instance"
            check (c.mixAmount == 0 and c.hueRandom == 0 and c.saturationRandom == 0 and c.gammaRandom == 0) "Corona must preserve palette colors"
        )
        if r.hasMapSupport #arnold do (
            check (a != undefined and r.map_arnold.enabled) "Arnold output missing"
            check (findString r.map_arnold.text ("(" + n as string + ")") != undefined) "Arnold button count differs from populated slots"
            for i = 1 to n do (
                local p = "input" + (i-1) as string
                check ((getProperty a p) == swatches[i].color) "Arnold zero-based input color mismatch"
                check (not (getProperty a (p + "_connected")) and (getProperty a (p + "_shader")) == undefined) "Arnold input must use palette color"
            )
            check (a.index == 0 and not a.index_connected and a.index_shader == undefined) "Arnold must default to the first palette color without a driver"
            check (a.input19 == swatches[1].color) "Unused Arnold inputs must fall back to first palette color"
        )
    )
    try (
        for spec in r.outputSpecs() do (
            check (spec[1].map == undefined and not spec[1].enabled) "Startup must leave every renderer map empty and disabled"
        )
        r.spn_colors.value = 16
        local bmp = dotNetObject "System.Drawing.Bitmap" 320 320
        local g = (dotNetClass "System.Drawing.Graphics").FromImage bmp
        for row = 0 to 3 do for col = 0 to 3 do (
            local brush = dotNetObject "System.Drawing.SolidBrush" ((dotNetClass "System.Drawing.Color").FromArgb (30+col*60) (20+row*65) 128)
            g.FillRectangle brush (col*80) (row*80) 80 80
            brush.Dispose()
        )
        g.Dispose()
        bmp.Save path (dotNetClass "System.Drawing.Imaging.ImageFormat").Png
        bmp.Dispose()
        check (r.loadSource path) "Renderer test image failed to load"
        -- Enable a zero-width mask of absent white to bypass extraction blur.
        r.cp_background.color = color 255 255 255
        r.spn_threshold.value = 0
        r.spn_softness.value = 0
        r.chk_background.checked = true
        r.chk_background.changed true
        for linear in #(false,true) do (
            r.chk_linear.checked = linear
            r.chk_linear.changed linear
            r.btn_extract.pressed()
            verifyPalette r 16
        )
        local colorBeforePaste = r.cp1.color
        local mapsBeforePaste = for spec in r.outputSpecs() collect spec[1].map
        r.cp1.color = color 1 2 3
        r.cp1.changed (color 1 2 3)
        check (r.cp1.color == colorBeforePaste) "Incoming paste/drop must not edit the palette"
        local specs = r.outputSpecs()
        for i = 1 to specs.count do check (specs[i][1].map == mapsBeforePaste[i]) "Read-only swatch change replaced a generated map"
        -- Reduced clustering targets must propagate to every renderer output.
        for count in #(2,5,16) do (
            r.spn_colors.value = count
            r.spn_colors.changed count
            for spec in r.outputSpecs() do check (spec[1].map == undefined and not spec[1].enabled) "Color count change left a stale map"
            r.btn_extract.pressed()
            verifyPalette r count
            if count < 16 do (
                local swatches = #(r.cp1,r.cp2,r.cp3,r.cp4,r.cp5,r.cp6,r.cp7,r.cp8,r.cp9,r.cp10,r.cp11,r.cp12,r.cp13,r.cp14,r.cp15,r.cp16)
                for i = count+1 to 16 do check (swatches[i].color == color 20 20 20) "Reduced palette left a stale swatch"
            )
            if r.hasMapSupport #multiTex do check (r.map_fstorm_multi.map.num_ids == count) "FStorm MultiTex ignored color limit"
            if r.hasMapSupport #randomColor do (
                local active = 0
                for chance in r.map_fstorm.map.chances where chance > 0 do active += 1
                check (active == amin #(count,r.map_fstorm.map.colors.count)) "FStorm RandomColor ignored color limit"
            )
        )
        -- Missing classes and a constructor failure must affect only that output.
        for i = 1 to 3 do (
            setProperty support fields[i] undefined
            r.rebuildMapOutputs()
            check (not controls[i].enabled and controls[i].map == undefined) "Missing class must disable its output"
            for j = 1 to 3 where j != i do check (controls[j].enabled == (saved[j] != undefined)) "Missing class disabled another renderer"
            setProperty support fields[i] saved[i]
        )
        support.coronaClass = Bitmaptexture
        r.rebuildMapOutputs()
        check (not r.map_corona.enabled and r.map_corona.map == undefined) "Failed Corona construction must leave no output"
        check (r.map_vray.enabled == (saved[1] != undefined) and r.map_arnold.enabled == (saved[3] != undefined)) "Failed construction disabled another renderer"
        support.coronaClass = saved[2]
        r.rebuildMapOutputs()
        for i = 1 to 3 where saved[i] != undefined do (
            controls[i].map = Bitmaptexture()
            case i of (
                1: r.map_vray.picked controls[i].map
                2: r.map_corona.picked controls[i].map
                3: r.map_arnold.picked controls[i].map
            )
            check (classOf controls[i].map == saved[i]) "Incompatible dropped map was not rejected"
        )
        -- Replace the source with one midtone color to catch stale active entries.
        bmp = dotNetObject "System.Drawing.Bitmap" 32 32
        g = (dotNetClass "System.Drawing.Graphics").FromImage bmp
        g.Clear ((dotNetClass "System.Drawing.Color").FromArgb 64 128 192)
        g.Dispose()
        bmp.Save path (dotNetClass "System.Drawing.Imaging.ImageFormat").Png
        bmp.Dispose()
        check (r.loadSource path) "Single-color source failed to load"
        r.btn_extract.pressed()
        verifyPalette r 1
        check (renderers.current == renderer) "Map creation changed the active renderer"
        renderers.current = Default_Scanline_Renderer()
        local scanline = renderers.current
        r.rebuildMapOutputs()
        verifyPalette r 1
        check (renderers.current == scanline) "Map creation changed Scanline renderer"
        renderers.current = renderer
        r.chk_linear.checked = not r.chk_linear.checked
        r.chk_linear.changed r.chk_linear.checked
        for control in controls do check (control.map == undefined and not control.enabled) "Conversion change left a stale renderer map"
        r.btn_extract.pressed()
        verifyPalette r 1
        r.btn_clear.pressed()
        for control in controls do check (control.map == undefined and not control.enabled) "Clear left a stale renderer map"
        r.chk_background.checked = false
        r.chk_background.changed false
        r.spn_threshold.value = 10
        r.spn_softness.value = 5
        r.spn_colors.value = savedCount
        check (deleteFile path) "Source image was not released"
        r.loadPreferences()
        "PASS: new renderer palettes (16 and 1 colors), linear output, missing classes, adapter failure isolation, rejected maps and cleanup."
    ) catch (
        for i = 1 to 3 do setProperty support fields[i] saved[i]
        renderers.current = renderer
        r.btn_clear.pressed()
        r.chk_background.checked = false
        r.chk_background.changed false
        r.spn_colors.value = savedCount
        deleteFile path
        r.loadPreferences()
        throw()
    )
)
