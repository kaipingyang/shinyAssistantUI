#!/usr/bin/env python3
import asyncio
import sys
from playwright.async_api import async_playwright


async def main(url: str) -> None:
    failures: list[str] = []
    console_errors: list[str] = []
    runtime_errors: list[str] = []
    network_errors: list[str] = []
    http_errors: list[str] = []
    websocket_urls: list[str] = []

    def check(name: str, ok: bool, detail: str = "") -> None:
        print(f"[{'PASS' if ok else 'FAIL'}] {name} {detail}".rstrip())
        if not ok:
            failures.append(name)

    async with async_playwright() as playwright:
        browser = await playwright.chromium.launch(
            headless=True,
            executable_path="/usr/bin/google-chrome",
            args=["--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu"],
        )
        context = await browser.new_context(
            viewport={"width": 1000, "height": 850},
            permissions=["clipboard-read", "clipboard-write"],
        )
        try:
            page = await context.new_page()
            page.on(
                "console",
                lambda message: console_errors.append(message.text)
                if message.type == "error" else None,
            )
            page.on("pageerror", lambda error: runtime_errors.append(str(error)))
            page.on(
                "requestfailed",
                lambda request: network_errors.append(
                    f"{request.method} {request.url}: {request.failure}"
                ),
            )
            page.on(
                "response",
                lambda response: http_errors.append(f"{response.status} {response.url}")
                if response.status >= 400 else None,
            )
            page.on("websocket", lambda websocket: websocket_urls.append(websocket.url))

            await page.goto(url, wait_until="domcontentloaded", timeout=30000)
            await page.wait_for_selector(".aui-root", timeout=30000)
            await page.wait_for_function(
                "Boolean(window.Shiny?.shinyapp?.$socket) && "
                "window.Shiny.shinyapp.$socket.readyState === 1",
                timeout=15000,
            )
            marker = await page.locator(
                'meta[name="shinyassistant-terminal-actions-package"]'
            ).get_attribute("content")
            check("installed Home package fixture loaded", marker == "installed-0.5.6", f"marker={marker}")

            composer = page.locator(".aui-lexical-input[contenteditable='true']").first
            await composer.click()
            await page.keyboard.insert_text("synthetic terminal action check")
            await page.keyboard.press("Enter")

            await page.wait_for_function(
                "document.querySelector('#fixture_state')?.textContent?.trim() === 'running'",
                timeout=15000,
            )
            status_line = page.locator('[data-slot="aui_status_line"]')
            await status_line.wait_for(timeout=10000)
            check(
                "active run displays Thinking status",
                "Thinking…" in await status_line.inner_text(),
            )
            await page.wait_for_function(
                "document.body.innerText.includes('SYNTHETIC FINAL ANSWER')",
                timeout=10000,
            )
            await page.locator("#fake_active_requesting").dispatch_event("click")
            await page.wait_for_function(
                "document.querySelector('#fixture_state')?.textContent?.trim() === 'active-requesting-sent'",
                timeout=10000,
            )
            await page.wait_for_function(
                "document.querySelector('[data-slot=aui_status_line]')?.textContent?.includes('requesting')",
                timeout=10000,
            )
            check("active run displays requesting status", "requesting" in await status_line.inner_text())

            roots = page.locator('[data-slot="aui_assistant-message-root"]')
            tool_root = roots.filter(
                has=page.locator(".aui-tool-group-trigger, .aui-shiny-tool")
            ).first
            text_root = roots.filter(has_text="SYNTHETIC FINAL ANSWER").first
            await tool_root.wait_for(timeout=10000)
            await text_root.wait_for(timeout=10000)

            tool_facts = await tool_root.evaluate(
                """el => ({
                  footer: Boolean(el.querySelector('[data-slot=aui_assistant-message-footer]')),
                  copy: Boolean(el.querySelector('button[aria-label=Copy]')),
                  refresh: Boolean(el.querySelector('button[aria-label=Refresh]')),
                  more: Boolean(el.querySelector('button[aria-label=More]')),
                  classes: el.className
                })"""
            )
            check("tool-only assistant message keeps its tool card", await tool_root.count() == 1)
            check("tool-only message has no text action footer", not tool_facts["footer"], str(tool_facts))
            check(
                "tool-only message has no Copy/Refresh/More controls",
                not tool_facts["copy"] and not tool_facts["refresh"] and not tool_facts["more"],
                str(tool_facts),
            )
            check(
                "tool-only message has no footer spacing compensation",
                "pb-7.5" not in tool_facts["classes"] and "-mb-7.5" not in tool_facts["classes"],
                f"classes={tool_facts['classes']}",
            )

            await page.locator("#fake_done").dispatch_event("click")
            await page.wait_for_function(
                "document.querySelector('#fixture_state')?.textContent?.trim() === 'done'",
                timeout=10000,
            )
            await page.wait_for_function(
                "!document.querySelector('[data-slot=aui_status_line]')",
                timeout=10000,
            )
            await page.wait_for_function(
                "!document.querySelector('.aui-composer-cancel')",
                timeout=10000,
            )
            check("done clears Thinking status", await status_line.count() == 0)

            await page.locator("#fake_late_thinking").dispatch_event("click")
            await page.wait_for_function(
                "document.querySelector('#fixture_state')?.textContent?.trim() === 'late-thinking-sent'",
                timeout=10000,
            )
            await page.wait_for_timeout(250)
            check("late thinking_tokens cannot revive terminal status", await status_line.count() == 0)

            await page.locator("#fake_late_requesting").dispatch_event("click")
            await page.wait_for_function(
                "document.querySelector('#fixture_state')?.textContent?.trim() === 'late-requesting-sent'",
                timeout=10000,
            )
            await page.wait_for_timeout(250)
            check("late requesting cannot revive terminal status", await status_line.count() == 0)

            await text_root.hover()
            text_facts = await text_root.evaluate(
                """el => ({
                  footer: Boolean(el.querySelector('[data-slot=aui_assistant-message-footer]')),
                  actionRoot: Boolean(el.querySelector('.aui-assistant-action-bar-root')),
                  classes: el.className
                })"""
            )
            copy_button = text_root.get_by_role("button", name="Copy", exact=True)
            refresh_button = text_root.get_by_role("button", name="Refresh", exact=True)
            more_button = text_root.get_by_role("button", name="More", exact=True)
            check("text assistant message retains action footer", text_facts["footer"], str(text_facts))
            check(
                "text message retains Copy/Refresh/More controls",
                text_facts["actionRoot"] and await copy_button.count() == 1
                and await refresh_button.count() == 1 and await more_button.count() == 1,
                str(text_facts),
            )
            check(
                "text message retains footer spacing compensation",
                "pb-7.5" in text_facts["classes"] and "-mb-7.5" in text_facts["classes"],
                f"classes={text_facts['classes']}",
            )

            await copy_button.click()
            clipboard = await page.evaluate("navigator.clipboard.readText()")
            check("text Copy remains functional", "SYNTHETIC FINAL ANSWER" in clipboard, f"clipboard={clipboard!r}")
            await more_button.click()
            export_item = page.get_by_text("Export as Markdown", exact=True)
            await export_item.wait_for(state="visible", timeout=5000)
            check("text Export menu remains available", await export_item.is_visible())
            await page.keyboard.press("Escape")

            await page.locator("#fake_regular_status").dispatch_event("click")
            await page.wait_for_function(
                "document.querySelector('#fixture_state')?.textContent?.trim() === 'regular-status-sent'",
                timeout=10000,
            )
            await status_line.wait_for(timeout=10000)
            check(
                "ordinary non-transient status remains supported after done",
                "SYNTHETIC BACKGROUND READY" in await status_line.inner_text(),
            )

            websocket_open = await page.evaluate(
                "Boolean(window.Shiny?.shinyapp?.$socket) && "
                "window.Shiny.shinyapp.$socket.readyState === 1"
            )
            check("Shiny WebSocket remains open", bool(websocket_urls) and bool(websocket_open))
            check("no console errors", not console_errors, " | ".join(console_errors[:3]))
            check("no runtime exceptions", not runtime_errors, " | ".join(runtime_errors[:3]))
            check("no failed network requests", not network_errors, " | ".join(network_errors[:3]))
            check("no HTTP errors", not http_errors, " | ".join(http_errors[:3]))
        finally:
            await context.close()
            await browser.close()

    if failures:
        print("FAILED:", ", ".join(failures))
        raise SystemExit(1)
    print("TERMINAL_THINKING_TOOL_ONLY_INSTALLED_VERIFY_OK")


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:9198/"))
