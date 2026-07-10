-- 将此文件复制为 config.lua 并填入你自己的值。
-- config.lua 已被 git 忽略，插件启动时自动加载。
--
-- 获取方式见 README.md。

return {
    -- API Key：用于书架浏览、搜索、进度同步
    -- 获取方式：微信读书 App → 我 → 设置 → 微信读书Skill 获取 → API Key
    api_key = "",

    -- 书籍阅读 cURL：从浏览器 /web/book/read 请求复制
    -- 插件自动提取 cookie 和上报 payload 字段（appId、ps、pc 等）
    -- 获取方式：浏览器打开 weread.qq.com → 打开任意书籍 → F12 DevTools → Network
    --          → 找到 /web/book/read 请求 → 右键 → Copy as cURL
    curl = [[
]],

    -- 公众号文章 cURL：从浏览器 /web/mp/articles 请求复制
    -- 插件自动提取 cookie 和 x-wrpa-0 验证头
    -- 获取方式：浏览器打开 weread.qq.com → 打开任意公众号 → F12 DevTools → Network
    --          → 找到 /web/mp/articles 请求 → 右键 → Copy as cURL
    mp_curl = [[
]],

    -- 可选：直接粘贴 Cookie header（仅在 curl 为空时使用）
    cookie = [[
]],

    -- 同步设置
    sync = {
        pull_on_open = true,       -- 打开书籍时拉取远端进度
        upload_on_close = true,    -- 关闭书籍时上传本地进度
        ask_on_conflict = true,    -- 进度冲突时询问
        upload_interval_minutes = 0,
    },

    -- 缓存设置
    cache = {
        download_book_images = true, -- 下载书籍章节中的图片
        download_mp_images = false,  -- 下载公众号文章中的图片
        download_underlines_and_thoughts = false, -- 下载章节时注入划线与想法（默认关闭）
        max_size_mb = 1024,
    },

    -- 阅读时间上报（启用/目标书籍通过菜单配置，此处仅设置间隔）
    read_report = {
        interval_seconds = 30,     -- 上报间隔（秒）
    },
}
