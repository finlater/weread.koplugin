#!/usr/bin/env python3
"""
WeRead KOReader Plugin - 自动认证配置脚本
============================================

一键获取微信读书的 cookie 和 x-wrpa-0 认证头，生成 config.lua。

解决的问题：
  1. 微信读书会检测 F12 开发者工具并强制报错，无法手动 "Copy as cURL"
  2. wr_skey 等关键 cookie 是 HttpOnly 的，JavaScript 无法访问
  3. session cookie 会过期，需要反复手动配置

方案：
  - 使用 Playwright 的 launch_persistent_context 持久化浏览器会话
  - 通过 CDP (Chrome DevTools Protocol) 直接读取所有 cookie（含 HttpOnly）
  - 拦截浏览器请求获取 x-wrpa-0 头
  - 浏览器配置保存在本地，下次运行自动恢复登录态，无需重复扫码

前置条件：
  pip install playwright
  playwright install chromium

用法：
  python setup_auth.py [插件目录路径]

  默认插件目录：当前目录下的 weread.koplugin/
"""

import asyncio, json, os, sys
from pathlib import Path
from playwright.async_api import async_playwright

# ─── 配置 ───────────────────────────────────────────────

# 持久化浏览器用户数据目录（保存 cookie、localStorage 等）
USER_DATA_DIR = Path.home() / ".weread_koplugin_browser"

# 微信读书 API Key（需从微信读书 App 获取）
# App → 我 → 设置 → 微信读书Skill → API Key
DEFAULT_API_KEY = "wrk-AMRlBJMsQ92u58oOx2oJOAAA"

# 超时设置
LOGIN_TIMEOUT_MS = 120_000
PAGE_LOAD_WAIT_MS = 5_000

# ─── 工具函数 ───────────────────────────────────────────

def find_plugin_dir():
    """自动查找插件目录"""
    if len(sys.argv) > 1:
        return Path(sys.argv[1])
    
    candidates = [
        Path.cwd() / "weread.koplugin",
        Path.cwd(),
    ]
    
    for candidate in candidates:
        main_lua = candidate / "main.lua" if candidate.name == "weread.koplugin" else candidate / "main.lua"
        if main_lua.exists() and "_meta.lua" in os.listdir(str(candidate)):
            return candidate
    
    # Fallback: use cwd
    return Path.cwd()


def extract_weread_cookies(cdp_cookies):
    """从 CDP cookie 列表中提取微信读书相关 cookie，返回排序后的 cookie 字符串"""
    parts = {}
    for c in cdp_cookies.get("cookies", []):
        if "weread" in c.get("domain", ""):
            parts[c["name"]] = c["value"]
    return "; ".join([f"{k}={v}" for k, v in sorted(parts.items())])


def build_config_lua(api_key, cookie_str, xwrpa_header):
    """生成 config.lua 内容"""
    # 构造阅读上报的默认 payload
    payload = '{"appId":"wb182564874657h13827777192001536","b":"0","c":"0","ci":27,"co":389,"sm":"","pr":74,"ps":"1736496000000","pc":"1736496001000"}'

    return f"""-- config.lua - 由 setup_auth.py 自动生成
-- 下次运行 setup_auth.py 可自动刷新 cookie（无需重新扫码）

return {{
    -- 从微信读书 App 获取：我 → 设置 → 微信读书Skill → API Key
    api_key = "{api_key}",

    -- 书籍阅读 cURL（含 cookie 和阅读上报 payload）
    curl = [[
curl 'https://weread.qq.com/web/book/read' \\
  -H 'cookie: {cookie_str}' \\
  -H 'content-type: application/json;charset=UTF-8' \\
  --data-raw '{payload}'
]],

    -- 公众号文章 cURL（含 cookie 和 x-wrpa-0 验证头）
    -- 插件会自动从此处提取 x-wrpa-0 用于所有 API 请求
    mp_curl = [[
curl 'https://weread.qq.com/web/mp/articles?bookId=MpBookIdHere' \\
  -H 'cookie: {cookie_str}' \\
  -H 'x-wrpa-0: {xwrpa_header}'
]],

    -- 可直接设置的认证字段（优先级高于从 cURL 中提取）
    wr_wrpa = "{xwrpa_header}",

    -- 备用 Cookie（仅在 curl 为空时使用）
    cookie = [[
{cookie_str}
]],

    sync = {{
        pull_on_open = true,       -- 打开书籍时拉取远端进度
        upload_on_close = true,    -- 关闭书籍时上传本地进度
        ask_on_conflict = true,    -- 进度冲突时询问
        upload_interval_minutes = 0,
    }},

    cache = {{
        download_book_images = true,           -- 下载书籍图片
        download_mp_images = false,            -- 不下载公众号图片
        download_underlines_and_thoughts = false, -- 不下载划线和想法
        max_size_mb = 1024,
    }},

    read_report = {{
        interval_seconds = 30,    -- 阅读时间上报间隔
    }},
}}
"""


# ─── 主流程 ─────────────────────────────────────────────

async def main():
    plugin_dir = find_plugin_dir()
    config_path = plugin_dir / "config.lua"
    
    print("╔══════════════════════════════════════╗")
    print("║  WeRead KOReader 自动认证配置脚本  ║")
    print("╚══════════════════════════════════════╝")
    print(f"\n插件目录: {plugin_dir}")
    print(f"输出文件: {config_path}")
    print(f"浏览器数据: {USER_DATA_DIR}（持久化，下次可复用）")
    print()

    async with async_playwright() as p:
        # 启动持久化浏览器上下文
        # launch_persistent_context 会将所有 cookie、LocalStorage 等保存到磁盘
        # 下次运行时自动恢复，无需重新扫码登录
        context = await p.chromium.launch_persistent_context(
            str(USER_DATA_DIR),
            headless=False,
            args=["--disable-blink-features=AutomationControlled"],
        )
        
        pages = context.pages or [await context.new_page()]
        page = pages[0]
        
        await page.goto("https://weread.qq.com")
        
        # 检测是否已登录
        try:
            await page.wait_for_selector('a[href*="/web/reader/"]', timeout=5_000)
            print("✓ 检测到已有登录态（持久化会话生效）")
        except:
            print("→ 请在浏览器中扫码登录微信读书...")
            try:
                await page.wait_for_selector('a[href*="/web/reader/"]', timeout=LOGIN_TIMEOUT_MS)
                print("✓ 登录成功！会话已保存到磁盘，下次无需重复登录")
            except:
                print("✗ 登录超时，请重试")
                await context.close()
                sys.exit(1)
        
        # 进入一本书的阅读页面，触发 API 请求以获取 x-wrpa-0
        book_href = await page.get_attribute('a[href*="/web/reader/"]', "href")
        print(f"→ 打开书籍: {book_href}")
        await page.goto(book_href)
        await page.wait_for_timeout(PAGE_LOAD_WAIT_MS)
        
        # 拦截浏览器请求，捕获 x-wrpa-0 头
        wrpa_header = None
        
        async def capture_xwrpa(request):
            nonlocal wrpa_header
            if wrpa_header is None:
                headers = dict(request.headers)
                if "x-wrpa-0" in headers:
                    wrpa_header = headers["x-wrpa-0"]
        
        page.on("request", capture_xwrpa)
        await page.reload()
        await page.wait_for_timeout(3_000)
        
        if wrpa_header:
            print(f"✓ 获取到 x-wrpa-0（{len(wrpa_header)} 字符）")
        else:
            print("⚠ 未能获取 x-wrpa-0，公众号功能可能不可用")
            wrpa_header = ""
        
        # 通过 CDP 获取所有 cookie（包括 HttpOnly）
        cdp = await context.new_cdp_session(page)
        cdp_cookies = await cdp.send("Network.getAllCookies")
        await cdp.detach()
        
        cookie_str = extract_weread_cookies(cdp_cookies)
        
        # 检查关键 cookie
        parts = dict(p.split("=", 1) for p in cookie_str.split("; ") if "=" in p)
        
        print()
        print("─── 获取到的认证信息 ───")
        for key in ["wr_skey", "wr_vid", "wr_gid", "wr_name", "wr_fp"]:
            if key in parts:
                display = parts[key][:40] + ("..." if len(parts[key]) > 40 else "")
                print(f"  {key}: {display}")
        print(f"  x-wrpa-0: {'✓ 已获取' if wrpa_header else '✗ 未获取'}")
        print()
        
        # 生成 config.lua
        config_content = build_config_lua(DEFAULT_API_KEY, cookie_str, wrpa_header)
        config_path.write_text(config_content, encoding="utf-8")
        
        print(f"✓ config.lua 已写入: {config_path}")
        print()
        print("下一步:")
        print("  1. 将整个插件目录同步到 KOReader 设备")
        print("  2. 在 KOReader 中: 工具 → 微信读书 → 设置 → 重新加载 config.lua")
        print()
        print("Cookie 过期后，再次运行本脚本即可自动刷新（无需重新登录）")
        
        await context.close()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n已取消")
    except Exception as e:
        print(f"\n错误: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)
