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

    observer_script = r"""
(() => {
  const state = window.__prewarmVerify = {
    rootSeenAt: null,
    warmingSeenAt: null,
    indicatorGoneAt: null,
    initializeStartAt: null,
    initializeDoneAt: null,
    indicatorAtInitializeDone: false,
    warmingText: "",
    donePayload: null,
    wasWarming: false,
    handlersReady: false
  };

  const scan = () => {
    const now = performance.now();
    const root = document.querySelector(".aui-root");
    const warming = document.querySelector("[data-slot='aui_warming']");
    if (root && state.rootSeenAt === null) state.rootSeenAt = now;
    if (warming) {
      if (state.warmingSeenAt === null) state.warmingSeenAt = now;
      state.warmingText = warming.textContent || state.warmingText;
      state.wasWarming = true;
    } else if (state.wasWarming) {
      state.indicatorGoneAt = now;
      state.wasWarming = false;
    }
  };

  new MutationObserver(scan).observe(document, {subtree: true, childList: true});
  setInterval(scan, 10);
  scan();

  const register = () => {
    if (!window.Shiny || typeof window.Shiny.addCustomMessageHandler !== "function") {
      setTimeout(register, 5);
      return;
    }
    if (state.handlersReady) return;
    state.handlersReady = true;
    window.Shiny.addCustomMessageHandler("verify:prewarm-start", (data) => {
      state.initializeStartAt = performance.now();
      state.startPayload = data;
      scan();
    });
    window.Shiny.addCustomMessageHandler("verify:prewarm-done", (data) => {
      state.initializeDoneAt = performance.now();
      state.indicatorAtInitializeDone = Boolean(
        document.querySelector("[data-slot='aui_warming']")
      );
      state.donePayload = data;
      scan();
    });
  };
  register();
})();
"""

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
            page.on(
                "response",
                lambda response: http_errors.append(
                    f"{response.status} {response.url}"
                )
                if response.status >= 400
                else None,
            )
            page.on("websocket", lambda websocket: websocket_urls.append(websocket.url))
            await page.add_init_script(observer_script)

            await page.goto(url, wait_until="domcontentloaded", timeout=30000)
            await page.wait_for_selector(".aui-root", timeout=30000)
            await page.wait_for_function(
                "window.__prewarmVerify?.warmingSeenAt !== null", timeout=30000
            )
            try:
                await page.wait_for_function(
                    "window.__prewarmVerify?.initializeDoneAt !== null || "
                    "(window.__prewarmVerify?.indicatorGoneAt !== null && "
                    "!document.querySelector('[data-slot=aui_warming]'))",
                    timeout=45000,
                )
                if await page.evaluate(
                    "window.__prewarmVerify?.initializeDoneAt === null"
                ):
                    raise RuntimeError("initialize marker missing after indicator completed")
            except Exception:
                debug_state = await page.evaluate("window.__prewarmVerify")
                indicator_present = await page.locator(
                    "[data-slot='aui_warming']"
                ).count()
                print(
                    "[DEBUG] synthetic prewarm state:",
                    debug_state,
                    "indicator_count=",
                    indicator_present,
                    "errors=",
                    {
                        "console": console_errors[:3],
                        "runtime": runtime_errors[:3],
                        "network": network_errors[:3],
                        "http": http_errors[:3],
                    },
                )
                raise
            await page.wait_for_function(
                "!document.querySelector('[data-slot=aui_warming]') && "
                "window.__prewarmVerify?.indicatorGoneAt !== null",
                timeout=10000,
            )
            await page.wait_for_function(
                "Boolean(window.Shiny?.shinyapp?.$socket) && "
                "window.Shiny.shinyapp.$socket.readyState === 1",
                timeout=10000,
            )
            await page.wait_for_timeout(250)

            state = await page.evaluate("window.__prewarmVerify")
            marker = await page.locator(
                'meta[name="shinyassistant-verify-package"]'
            ).get_attribute("content")
            initialize_ms = float(state["donePayload"]["initialize_ms"])
            cached_ms = float(state["donePayload"]["cached_ms"])
            visible_ms = state["initializeDoneAt"] - state["warmingSeenAt"]

            check(
                "installed Home package fixture loaded",
                marker == "installed-0.5.6",
                f"marker={marker}",
            )
            check(
                "first screen renders before initialize completes",
                state["rootSeenAt"] is not None
                and state["rootSeenAt"] < state["initializeDoneAt"],
            )
            check(
                "warming indicator appears during real CLI initialize",
                state["warmingSeenAt"] is not None and visible_ms >= 100,
                f"visible_until_initialize={visible_ms:.0f}ms",
            )
            check(
                "warming copy is explicit",
                "Starting Claude Code" in state["warmingText"],
                repr(state["warmingText"]),
            )
            check(
                "indicator remains mounted when initialize completes",
                bool(state["indicatorAtInitializeDone"]),
            )
            check(
                "indicator disappears only after initialize completes",
                state["indicatorGoneAt"] >= state["initializeDoneAt"],
            )
            check(
                "real Claude CLI initialize ran",
                initialize_ms >= 100,
                f"initialize={initialize_ms:.0f}ms",
            )
            check(
                "connected client is cached before first message",
                cached_ms < 500 and cached_ms < initialize_ms,
                f"cached_lookup={cached_ms:.1f}ms initialize={initialize_ms:.0f}ms",
            )
            composer = page.locator(
                ".aui-lexical-input[contenteditable='true']"
            ).first
            check(
                "verification submitted no prompt",
                (await composer.inner_text()).strip() == "",
            )
            websocket_open = await page.evaluate(
                "Boolean(window.Shiny?.shinyapp?.$socket) && "
                "window.Shiny.shinyapp.$socket.readyState === 1"
            )
            check(
                "Shiny WebSocket opened and remains open",
                bool(websocket_urls) and bool(websocket_open),
                f"observed={len(websocket_urls)}",
            )
            check("no console errors", not console_errors, " | ".join(console_errors[:3]))
            check("no runtime exceptions", not runtime_errors, " | ".join(runtime_errors[:3]))
            all_network_errors = network_errors + http_errors
            check(
                "no network errors",
                not all_network_errors,
                " | ".join(all_network_errors[:3]),
            )
        finally:
            await browser.close()

    if failures:
        raise RuntimeError("verification failed: " + ", ".join(failures))
    print("PREWARM_INSTALLED_BROWSER_VERIFY_DONE")


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1]))
