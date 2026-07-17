local I18n = require("lib.i18n")

local function _(text)
    return I18n.tr(text)
end

return {
    name = "weread",
    fullname = _("WeRead"),
    description = _([[Read WeRead books in KOReader, cache chapters, and sync reading progress.]]),
    version = "0.3.0",
}
