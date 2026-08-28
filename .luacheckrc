std = "luajit"

globals = {
    "G_defaults",
    "G_reader_settings",
    "G_reader_ui",
}

-- KOReader callbacks intentionally leave some arguments unused, and a few
-- compatibility branches are deliberately empty.
ignore = {
    "212", -- unused argument
    "213", -- unused loop variable
    "581", -- preserve explicit boolean expressions used by menu callbacks
}

max_line_length = false

files["weread/lib/client.lua"] = {
    ignore = { "211/_status" },
}

files["weread/lib/content.lua"] = {
    ignore = {
        "211/normalize_void_elements",
    },
}

files["weread/lib/i18n.lua"] = {
    -- Translation catalogs intentionally repeat a key in two grouped sections.
    ignore = { "314" },
}

files["weread/lib/plugin_util.lua"] = {
    ignore = { "143/table" },
}

files["weread/lib/progress_sync.lua"] = {
    ignore = {
        "211/_reason",
        "231/_index",
    },
}

files["weread/lib/protocol.lua"] = {
    ignore = { "311/width" },
}

files["weread/lib/reader_lifecycle.lua"] = {
    ignore = {
        "211/current_ch",
        "211/_started",
        "211/_title",
    },
}

files["weread/ui/annotations_controller.lua"] = {
    ignore = {
        "211/Annotations",
        "211/_current_idx",
    },
}

files["weread/ui/reader_navigation.lua"] = {
    ignore = { "211/current_ch" },
}

files["spec/scan_spec.lua"] = {
    ignore = { "211/d_added" },
}

files["spec/koreader/*.lua"] = {
    globals = {
        "describe",
        "setup",
        "it",
        "disable_plugins",
        "load_plugin",
    },
}
