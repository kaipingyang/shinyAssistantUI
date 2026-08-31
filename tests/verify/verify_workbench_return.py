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
        print(f"[{'PASS' if condition else 'FAIL'}] {name} {detail}".rstrip())
        if not condition:
            failures.append(name)

    async with async_playwright() as playwright:
        browser = await playwright.chromium.launch(
            headless=True,
            executable_path="/usr/bin/google-chrome",
            args=["--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu"],
        )
        try:
            context = await browser.new_context(viewport={"width": 900, "height": 900})
            page = await context.new_page()
            page.on("console", lambda m: console_errors.append(m.text) if m.type == "error" else None)
            page.on("pageerror", lambda e: runtime_errors.append(str(e)))
            page.on("requestfailed", lambda r: network_errors.append(f"{r.method} {r.url}: {r.failure}"))
            page.on("crash", lambda: frame_errors.append("page crashed"))
            await page.route("**/favicon.ico", lambda route: route.fulfill(status=204))

            started = time.monotonic()
            await page.goto(url, wait_until="domcontentloaded", timeout=30000)
            await page.wait_for_selector(".assistantUI-output > .aui-root", state="visible", timeout=2000)
            shell_elapsed = time.monotonic() - started
            await page.evaluate("document.querySelector('.assistantUI-output > .aui-root').dataset.returnProbe = 'preserved'")
            session_item = page.locator('[data-slot="aui_thread-list-item"]', has_text="Delayed history")
            await session_item.wait_for(state="visible", timeout=10000)
            sessions_elapsed = time.monotonic() - started

            other = await context.new_page()
            await other.goto("data:text/html,<title>Other page</title><p>other</p>")
            await other.bring_to_front()
            await asyncio.sleep(2)
            return_started = time.monotonic()
            await page.bring_to_front()
            await page.wait_for_selector(".assistantUI-output > .aui-root", state="visible", timeout=2000)
            return_elapsed = time.monotonic() - return_started

            state = await page.evaluate("""() => ({
              marker: document.querySelector('.assistantUI-output > .aui-root')?.dataset.returnProbe || '',
              outputRoots: document.querySelectorAll('.assistantUI-output > .aui-root').length,
              sessionItems: document.querySelectorAll('[data-slot=aui_thread-list-item]').length,
              socket: window.Shiny?.shinyapp?.$socket?.readyState,
              visibility: document.visibilityState
            })""")

            check("React shell paints before slow session discovery", shell_elapsed < 2.0,
                  f"shell={shell_elapsed:.3f}s sessions={sessions_elapsed:.3f}s")
            check("slow session discovery actually completed later", sessions_elapsed >= 2.5,
                  f"sessions={sessions_elapsed:.3f}s")
            check("return from another page is immediate", return_elapsed < 0.75,
                  f"return={return_elapsed:.3f}s")
            check("mounted widget state is preserved", state["marker"] == "preserved")
            check("one mounted output root remains", state["outputRoots"] == 1, str(state))
            check("session list remains populated", state["sessionItems"] >= 1, str(state))
            check("Shiny WebSocket remains open", state["socket"] == 1, str(state))
            check("page is visible after return", state["visibility"] == "visible", str(state))
            check("no console errors", not console_errors, " | ".join(console_errors[:3]))
            check("no runtime exceptions", not runtime_errors, " | ".join(runtime_errors[:3]))
            check("no network failures", not network_errors, " | ".join(network_errors[:3]))
            check("no frame crashes", not frame_errors, " | ".join(frame_errors[:3]))
        finally:
            await browser.close()

    if failures:
        raise RuntimeError("verification failed: " + ", ".join(failures))
    print("WORKBENCH_RETURN_BROWSER_VERIFY_DONE")


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1]))
