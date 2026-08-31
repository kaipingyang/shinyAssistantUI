import asyncio
import sys
import time
from playwright.async_api import async_playwright


async def main(url: str) -> None:
    failures = []
    console_errors = []
    runtime_errors = []
    network_errors = []
    frame_errors = []

    def check(name: str, condition: bool, detail: str = "") -> None:
        status = "PASS" if condition else "FAIL"
        print(f"[{status}] {name} {detail}".rstrip())
        if not condition:
            failures.append(name)

    async with async_playwright() as playwright:
        browser = await playwright.chromium.launch(
            headless=True,
            executable_path="/usr/bin/google-chrome",
            args=["--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu"],
        )
        try:
            page = await browser.new_page(viewport={"width": 900, "height": 900})
            page.on(
                "console",
                lambda message: console_errors.append(message.text)
                if message.type == "error"
                else None,
            )
            page.on("pageerror", lambda error: runtime_errors.append(str(error)))
            page.on(
                "requestfailed",
                lambda request: network_errors.append(
                    f"{request.method} {request.url}: {request.failure}"
                ),
            )
            page.on("crash", lambda: frame_errors.append("page crashed"))

            await page.goto(url, wait_until="domcontentloaded", timeout=30000)
            await page.wait_for_selector(".aui-root", timeout=20000)
            composer = page.locator(
                ".aui-lexical-input[contenteditable='true']"
            ).first
            await composer.wait_for(state="visible", timeout=15000)

            await composer.click()
            await page.keyboard.insert_text("first-check")
            await page.keyboard.press("Enter")
            try:
                await page.wait_for_function(
                    "document.body.innerText.includes('reply-1')", timeout=10000
                )
            except Exception:
                print(
                    "[DEBUG] first body tail:",
                    (await page.locator("body").inner_text())[-1000:],
                )
                raise
            await page.wait_for_selector(
                ".aui-composer-send", state="visible", timeout=3000
            )

            await composer.click()
            await page.keyboard.insert_text("second-check")
            await page.wait_for_timeout(100)
            print(f"[INFO] second composer text before Enter: {await composer.inner_text()!r}")
            started = time.monotonic()
            await page.keyboard.press("Enter")
            try:
                await page.wait_for_function(
                    "document.body.innerText.includes('reply-2')", timeout=7000
                )
            except Exception:
                body_debug = (await page.locator("body").inner_text())[-1000:]
                print(f"[DEBUG] body tail after second submit: {body_debug!r}")
                print(
                    "[DEBUG] controls send/cancel/composer=",
                    await page.locator(".aui-composer-send").count(),
                    await page.locator(".aui-composer-cancel").count(),
                    await composer.inner_text(),
                )
                raise
            second_elapsed = time.monotonic() - started
            check(
                "second input completes before delayed context response",
                second_elapsed < 6.0,
                f"elapsed={second_elapsed:.3f}s",
            )
            ring_before_probe = await page.locator(
                '[data-slot="context-display-trigger"]'
            ).count()
            check(
                "context ring is still absent when second reply completes",
                ring_before_probe == 0,
                f"count={ring_before_probe}",
            )

            ring = page.locator('[data-slot="context-display-trigger"]').first
            await ring.wait_for(state="visible", timeout=12000)
            await ring.focus()
            await ring.hover()
            popover = page.locator('[data-slot="context-display-popover"]').first
            await popover.wait_for(state="visible", timeout=3000)
            usage_text = await popover.inner_text()
            check(
                "latest async context usage reaches the ring",
                "25%" in usage_text or "25.0%" in usage_text,
                usage_text.replace("\n", " ")[:100],
            )

            body_text = await page.locator("body").inner_text()
            check(
                "both user inputs and replies remain rendered",
                all(
                    item in body_text
                    for item in ("first-check", "second-check", "reply-1", "reply-2")
                ),
            )
            websocket_open = await page.evaluate(
                "Boolean(window.Shiny?.shinyapp?.$socket) && "
                "window.Shiny.shinyapp.$socket.readyState === 1"
            )
            check("Shiny WebSocket remains open", bool(websocket_open))
            check("no console errors", not console_errors, " | ".join(console_errors[:3]))
            check("no runtime exceptions", not runtime_errors, " | ".join(runtime_errors[:3]))
            check("no network request failures", not network_errors, " | ".join(network_errors[:3]))
            check("no frame crashes", not frame_errors, " | ".join(frame_errors[:3]))
        finally:
            await browser.close()

    if failures:
        raise RuntimeError("verification failed: " + ", ".join(failures))
    print("NONBLOCKING_USAGE_BROWSER_VERIFY_DONE")


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1]))
