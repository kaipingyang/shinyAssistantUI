import asyncio
import sys
from playwright.async_api import async_playwright


async def main(url: str) -> None:
    failures: list[str] = []
    console_errors: list[str] = []
    runtime_errors: list[str] = []
    network_errors: list[str] = []

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
        try:
            page = await browser.new_page(viewport={"width": 800, "height": 900})
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
            await page.goto(url, wait_until="domcontentloaded", timeout=30000)
            await page.wait_for_selector(".aui-root", timeout=30000)
            await page.wait_for_function(
                "Boolean(window.Shiny?.shinyapp?.$socket) && "
                "window.Shiny.shinyapp.$socket.readyState === 1",
                timeout=30000,
            )
            composer = page.locator(".aui-lexical-input[contenteditable='true']").first
            await composer.click()
            await page.keyboard.insert_text("synthetic tool result marker")
            await page.keyboard.press("Enter")

            result = page.locator('[data-result-view="json"]', has_text="synthetic weather marker").first
            await result.wait_for(state="visible", timeout=30000)
            card = result.locator("xpath=ancestor::*[contains(@class,'aui-shiny-tool')][1]")
            result_text = await result.inner_text()
            check("structured result uses JSON auto renderer", await result.count() == 1)
            check(
                "shared prism JSON highlighter is reused",
                await result.locator('[data-syntax-highlighter="prism-json"]').count() == 1,
            )
            check("JSON tokens are colored", await result.locator(".token").count() > 0)
            check(
                "WebSearch-shaped fields remain visible",
                "Synthetic result" in result_text and "durationSeconds" in result_text,
            )
            check(
                "structured result does not use console fallback",
                await card.locator('[data-result-view="console"]').count() == 0,
            )
            plain = page.locator('[data-result-view="console"]', has_text="[1] 2").first
            check("ordinary text result remains console", await plain.count() == 1)
            websocket_open = await page.evaluate(
                "Boolean(window.Shiny?.shinyapp?.$socket) && "
                "window.Shiny.shinyapp.$socket.readyState === 1"
            )
            check("Shiny WebSocket remains open", bool(websocket_open))
            check("no console errors", not console_errors, " | ".join(console_errors[:3]))
            check("no runtime exceptions", not runtime_errors, " | ".join(runtime_errors[:3]))
            check("no network request failures", not network_errors, " | ".join(network_errors[:3]))
        finally:
            await browser.close()

    if failures:
        raise RuntimeError("verification failed: " + ", ".join(failures))
    print("TOOL_RESULT_AUTO_BROWSER_VERIFY_DONE")


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1]))
