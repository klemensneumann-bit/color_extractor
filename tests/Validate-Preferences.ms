-- Run after ColorExtractor.ms. Keeps real user preferences untouched.
(
    local r = ColorExtractor_rollout
    local originalPath = r.preferencesFile
    local path = (getDir #temp) + "/ColorExtractor-prefs-" + (timestamp() as string) + ".ini"
    fn check condition message = (if not condition do throw message)
    fn checkDefaults r = (
        check (not r.chk_background.checked) "Default Ignore background should be off"
        check (r.spn_threshold.value == 10.0) "Default threshold should be 10"
        check (r.spn_softness.value == 5.0) "Default softness should be 5"
        check (r.spn_colors.value == 16) "Default colors should be 16"
        check r.chk_linear.checked "Default Linear should be on"
    )
    try (
        r.preferencesFile = path
        r.loadPreferences()
        checkDefaults r
        check (not r.cp_background.enabled and not r.spn_threshold.enabled and not r.spn_softness.enabled) "Default mask controls must be disabled"
        check (not doesFileExist path) "Loading absent preferences must not create a file"

        r.chk_background.checked = true
        r.chk_background.changed true
        r.spn_threshold.value = 21.5
        r.spn_threshold.changed 21.5
        r.spn_softness.value = 7.5
        r.spn_softness.changed 7.5
        r.spn_colors.value = 6
        r.spn_colors.changed 6
        r.chk_linear.checked = false
        r.chk_linear.changed false
        -- Reset controls without firing handlers, then reload the saved values.
        r.chk_background.checked = false
        r.spn_threshold.value = 0
        r.spn_softness.value = 0
        r.spn_colors.value = 16
        r.chk_linear.checked = true
        r.loadPreferences()
        check r.chk_background.checked "Ignore background did not persist"
        check (r.spn_threshold.value == 21.5 and r.spn_softness.value == 7.5) "Fractional mask values did not persist"
        check (r.spn_colors.value == 6 and not r.chk_linear.checked) "Colors or Linear did not persist"
        check (r.cp_background.enabled and r.btn_background.enabled and r.spn_threshold.enabled and r.spn_softness.enabled and r.chk_mask.enabled) "Loaded Ignore background must enable its controls"

        setINISetting path "Preferences" "IgnoreBackground" "invalid"
        setINISetting path "Preferences" "Threshold" "-1"
        setINISetting path "Preferences" "Softness" "not a number"
        setINISetting path "Preferences" "MaxColors" "6.5"
        setINISetting path "Preferences" "Linear" "invalid"
        r.loadPreferences()
        checkDefaults r
        for entry in #(#("Threshold","251"),#("Threshold","NaN"),#("Softness","Infinity"),#("MaxColors","1"),#("MaxColors","17")) do (
            setINISetting path "Preferences" entry[1] entry[2]
            r.loadPreferences()
            checkDefaults r
        )
        -- Valid zero and boundary values must survive loading.
        setINISetting path "Preferences" "Threshold" "0"
        setINISetting path "Preferences" "Softness" "250"
        setINISetting path "Preferences" "MaxColors" "2"
        r.loadPreferences()
        check (r.spn_threshold.value == 0 and r.spn_softness.value == 250 and r.spn_colors.value == 2) "Valid boundaries were not restored"
        deleteFile path
        r.preferencesFile = originalPath
        r.loadPreferences()
        "PASS: preference defaults, immediate saves, fractional values, UI restoration, malformed values and boundaries."
    ) catch (
        deleteFile path
        r.preferencesFile = originalPath
        r.loadPreferences()
        throw()
    )
)
