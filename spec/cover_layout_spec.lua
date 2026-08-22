package.path = "./?.lua;./?/init.lua;" .. package.path

local CoverLayout = require("weread.lib.cover_layout")

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local kindle_touch = CoverLayout.calculate{
    width = 600,
    height = 800,
    size_scale = 1,
}
expect(kindle_touch.columns == 3 and kindle_touch.rows == 2,
    "Kindle Touch layout should remain a 3x2 grid")
expect(kindle_touch.page_size == 6,
    "Kindle Touch page should contain six covers")

local modern_medium = CoverLayout.calculate{
    width = 1080,
    height = 1440,
    size_scale = 1.8,
}
expect(modern_medium.columns == 4 and modern_medium.rows == 3,
    "1080x1440 layout should expand to a 4x3 grid")
expect(modern_medium.page_size == 12,
    "1080x1440 layout should contain more than eight covers")

local modern_large = CoverLayout.calculate{
    width = 1404,
    height = 1872,
    size_scale = 2.34,
}
expect(modern_large.columns == 5 and modern_large.rows == 4,
    "1404x1872 layout should expand to a 5x4 grid")
expect(modern_large.page_size == 20,
    "large modern layout should use all twenty visible cells")

local very_large = CoverLayout.calculate{
    width = 2808,
    height = 3744,
    size_scale = 4.68,
}
expect(very_large.page_size > modern_large.page_size,
    "cover count must not have a hidden fixed upper limit")

local no_reserved_space = CoverLayout.calculate{
    width = 600,
    height = 800,
    size_scale = 1,
    reserved_height = 0,
}
expect(no_reserved_space.content_height == 800,
    "an explicit zero reserved height should be retained")

local tiny = CoverLayout.calculate{
    width = 1,
    height = 1,
    size_scale = 100,
}
expect(tiny.columns == 1 and tiny.rows == 1 and tiny.page_size == 1,
    "tiny screens should degrade to one valid cell")
expect(tiny.cell_width == 1 and tiny.cell_height == 1,
    "tiny-screen cell geometry escaped the screen")

local invalid = CoverLayout.calculate{
    width = 0,
    height = -1,
    size_scale = "invalid",
}
expect(invalid.columns == 3 and invalid.rows == 2,
    "invalid geometry should fall back to Kindle Touch dimensions")

print(("cover_layout_spec: %d checks"):format(checks))
