-- Language selection must follow KOReader's automatic locale when no override is saved.
package.path = "./?.lua;" .. package.path

local saved_language
G_reader_settings = {
    readSetting = function(_self, key)
        assert(key == "language")
        return saved_language
    end,
}
local gettext = { current_lang = "zh_CN" }
package.loaded["gettext"] = gettext
local I18n = require("weread.lib.i18n")

assert(I18n.tr("Bookshelf") == "书架", "automatic Chinese locale must translate plugin menus")
assert(require("_meta").fullname == "微信读书", "plugin metadata must follow the automatic locale")

gettext.current_lang = "C"
assert(I18n.tr("Bookshelf") == "Bookshelf", "runtime language changes must not be cached")
saved_language = "zh_CN.UTF-8"
assert(I18n.tr("Bookshelf") == "书架", "saved Chinese must take priority over the runtime locale")

gettext.current_lang = "zh_CN"
saved_language = "C"
assert(I18n.tr("Bookshelf") == "Bookshelf", "explicit English must override automatic Chinese")
saved_language = nil
gettext.current_lang = "zh_TW"
assert(I18n.tr("Bookshelf") == "书架", "Chinese variants must keep using the existing dictionary")
assert(I18n.tr("Untranslated test string") == "Untranslated test string")

G_reader_settings = nil
assert(I18n.tr("Bookshelf") == "书架", "the runtime locale must also work without settings")
package.loaded["gettext"] = nil
assert(I18n.language() == "en", "standalone use without gettext must fall back to English")
package.loaded["gettext"] = function(text) return text end
assert(I18n.language() == "en", "identity gettext stubs must remain supported")

print("i18n_spec: automatic locale, saved overrides and English fallback passed")
