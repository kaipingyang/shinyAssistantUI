#!/usr/bin/env python3
import asyncio
import sys
from playwright.async_api import async_playwright


async def main(url: str, expected_version: str = "") -> None:
    failures: list[str] = []
    console_errors: list[str] = []
    runtime_errors: list[str] = []
    window_errors: list[dict] = []
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
        try:
            page = await browser.new_page(viewport={"width": 1000, "height": 900})
            await page.expose_binding(
                "auiVerificationWindowError",
                lambda _source, detail: window_errors.append(detail),
            )
            await page.add_init_script(
                """window.__auiWindowErrorProbeReady=true;
                window.addEventListener('error', event => {
                  window.auiVerificationWindowError({
                    message: event.message || '',
                    hasErrorObject: Boolean(event.error),
                    stack: String(event.error?.stack || '').slice(0, 2000)
                  });
                });"""
            )
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
                lambda response: http_errors.append(f"{response.status} {response.url}")
                if response.status >= 400
                else None,
            )
            page.on("websocket", lambda websocket: websocket_urls.append(websocket.url))

            await page.goto(url, wait_until="domcontentloaded", timeout=30000)
            await page.wait_for_selector(".aui-root", timeout=30000)
            await page.wait_for_function("window.__auiWindowErrorProbeReady===true")
            await page.wait_for_function(
                "Boolean(window.Shiny?.shinyapp?.$socket) && "
                "window.Shiny.shinyapp.$socket.readyState === 1",
                timeout=15000,
            )
            marker = await page.locator(
                'meta[name="shinyassistant-behavior-package"]'
            ).get_attribute("content")
            expected_marker = f"installed-{expected_version}" if expected_version else marker
            check(
                "installed Home package fixture loaded",
                bool(marker) and marker.startswith("installed-") and marker == expected_marker,
                f"marker={marker}",
            )

            viewport = page.locator('[data-slot="aui_thread-viewport"]').first
            composer = page.locator(".aui-lexical-input[contenteditable='true']").first
            down_arrow = page.locator("button.aui-thread-scroll-to-bottom").first
            fake_chunk = page.locator("#fake_chunk")
            fake_done = page.locator("#fake_done")

            async def send(text: str) -> None:
                await composer.click()
                await page.keyboard.insert_text(text)
                await page.keyboard.press("Enter")

            async def metrics() -> dict:
                return await viewport.evaluate(
                    "el => ({top: el.scrollTop, height: el.scrollHeight, "
                    "client: el.clientHeight, bottom: el.scrollHeight-el.clientHeight-el.scrollTop})"
                )

            async def rendered(marker: str) -> None:
                await page.wait_for_function(
                    "marker => document.body.innerText.includes(marker)",
                    arg=marker,
                    timeout=15000,
                )
                await page.evaluate(
                    "() => new Promise(resolve => requestAnimationFrame(() => "
                    "requestAnimationFrame(() => requestAnimationFrame(resolve))))"
                )

            async def append_chunk(turn: int, number: int) -> None:
                await fake_chunk.dispatch_event("click")
                await page.wait_for_function(
                    "([turn, chunk]) => document.querySelector('#fixture_ready')?.textContent?.trim() "
                    "=== `${turn}:${chunk}`",
                    arg=[turn, number],
                    timeout=10000,
                )
                await rendered(f"SYNTHETIC_CHUNK_END_{turn}_{number}")
            await page.wait_for_function(
                "document.querySelector('#fixture_ready')?.textContent?.trim() === '0:0'",
                timeout=10000,
            )
            await page.wait_for_timeout(200)

            await send("synthetic-behavior-turn-1")
            await page.wait_for_timeout(750)
            first_turn_state = await page.evaluate(
                """() => ({
                  ready: document.querySelector('#fixture_ready')?.textContent?.trim() || '',
                  users: document.querySelectorAll('[data-role="user"]').length,
                  running: Boolean(document.querySelector('.aui-composer-cancel')),
                  editorEmpty: !(document.querySelector('.aui-lexical-input')?.textContent || '').trim()
                })"""
            )
            print(f"[INFO] first synthetic turn state {first_turn_state}")
            await rendered("SYNTHETIC_TURN_1_CONTENT_END")

            agent_cards = page.locator(
                '[data-slot="tool-fallback-trigger"][aria-label^="Used tool: Agent"]'
            )
            scroll_debug = await page.evaluate(
                """() => Array.from(document.querySelectorAll('*'))
                  .filter((el) => el.scrollHeight - el.clientHeight > 100)
                  .slice(0, 12)
                  .map((el) => ({tag: el.tagName, slot: el.getAttribute('data-slot') || '',
                    id: el.id || '', h: el.scrollHeight, c: el.clientHeight,
                    oy: getComputedStyle(el).overflowY}))"""
            )
            print(f"[INFO] synthetic scroll containers {scroll_debug}")
            check("two synthetic Agent cards remain rendered", await agent_cards.count() == 2)
            order_ok = await page.evaluate(
                """() => {
                  const agents = Array.from(document.querySelectorAll(
                    '[data-slot="tool-fallback-trigger"][aria-label^="Used tool: Agent"]'));
                  const summary = Array.from(document.querySelectorAll('[data-slot="aui_assistant-text"]'))
                    .find((el) => (el.textContent || '').includes('SYNTHETIC_TURN_1_SUMMARY'));
                  return Boolean(summary) && agents.length === 2 && agents.every((agent) =>
                    Boolean(agent.compareDocumentPosition(summary) & Node.DOCUMENT_POSITION_FOLLOWING));
                }"""
            )
            check("top-level summary follows Agent cards", bool(order_ok))

            checklist = page.locator('[data-slot="aui_claude_checklist"]').first
            await checklist.wait_for(timeout=10000)
            completed_item = checklist.locator('[data-checklist-status="completed"]').first
            check("mixed-case completed status canonicalized", await completed_item.count() == 1)
            check("completed checklist item keeps check mark", "✓" in await completed_item.inner_text())
            completed_label = completed_item.locator("span").last
            check(
                "completed checklist item keeps line-through",
                "line-through" in (await completed_label.get_attribute("class") or ""),
            )
            close_button = checklist.get_by_role("button", name="Close checklist")
            check("active checklist keeps manual × close", await close_button.count() == 1)
            await close_button.click()
            await page.wait_for_function(
                "!document.querySelector('[data-slot=aui_claude_checklist]')",
                timeout=5000,
            )
            check("checklist exact revision dismisses", await checklist.count() == 0)
            check("existing down-arrow is the only return control", await down_arrow.count() == 1)

            initial = await metrics()
            check("initial response is pinned to bottom", initial["bottom"] <= 12, f"bottom={initial['bottom']:.1f}")
            pinned_samples: list[float] = []
            for number in range(1, 4):
                await append_chunk(1, number)
                pinned_samples.append((await metrics())["bottom"])
            check(
                "uninterrupted stream growth continuously follows",
                all(distance <= 12 for distance in pinned_samples),
                f"bottom={pinned_samples}",
            )

            await viewport.hover(position={"x": 300, "y": 220})
            await page.mouse.wheel(0, -650)
            await page.wait_for_timeout(250)
            reading = await metrics()
            check("user can scroll upward during stream", reading["bottom"] > 150, f"bottom={reading['bottom']:.1f}")
            await append_chunk(1, 4)
            after_growth = await metrics()
            check(
                "new stream content does not pull an upward reader down",
                after_growth["bottom"] > 150 and abs(after_growth["top"] - reading["top"]) <= 20,
                f"beforeTop={reading['top']:.1f} afterTop={after_growth['top']:.1f} bottom={after_growth['bottom']:.1f}",
            )

            await down_arrow.click()
            await page.wait_for_function(
                "el => el.scrollHeight-el.clientHeight-el.scrollTop <= 12",
                arg=await viewport.element_handle(),
                timeout=5000,
            )
            await append_chunk(1, 5)
            resumed = await metrics()
            check("existing down-arrow resumes follow", resumed["bottom"] <= 12, f"bottom={resumed['bottom']:.1f}")

            await fake_done.dispatch_event("click")
            await page.wait_for_function(
                "!document.querySelector('.aui-composer-cancel')",
                timeout=10000,
            )
            await page.wait_for_timeout(300)
            await viewport.hover(position={"x": 300, "y": 220})
            await page.mouse.wheel(0, -800)
            await page.wait_for_timeout(250)
            old_reading = await metrics()
            check("completed history can remain scrolled up", old_reading["bottom"] > 150)

            await send("synthetic-behavior-turn-2")
            await rendered("SYNTHETIC_TURN_2_CONTENT_END")
            new_turn = await metrics()
            check(
                "sending from old history jumps to the new turn",
                new_turn["bottom"] <= 12,
                f"bottom={new_turn['bottom']:.1f}",
            )
            await append_chunk(2, 1)
            second_growth = await metrics()
            check(
                "new turn remains followed while streaming",
                second_growth["bottom"] <= 12,
                f"bottom={second_growth['bottom']:.1f}",
            )
            await fake_done.dispatch_event("click")
            await page.wait_for_function("!document.querySelector('.aui-composer-cancel')")

            await send("synthetic-task-tools-turn")
            await rendered("SYNTHETIC_TURN_3_CONTENT_END")
            await checklist.wait_for(timeout=10000)

            async def task_group() -> list[dict]:
                return await checklist.locator("[data-checklist-status]").evaluate_all(
                    "items => items.map(el => ({status:el.dataset.checklistStatus,text:el.textContent}))"
                )

            task_items = await task_group()
            check(
                "TaskCreate starts a new two-item group instead of mixing old TodoWrite",
                len(task_items) == 2
                and "Synthetic TaskCreate item 1" in task_items[0]["text"]
                and "Synthetic task activity 2" in task_items[1]["text"],
                str(task_items),
            )
            check(
                "TaskUpdate applies completed and in-progress states",
                [item["status"] for item in task_items] == ["completed", "in_progress"],
            )
            completed_task = checklist.locator('[data-checklist-status="completed"]')
            check(
                "TaskUpdate completion keeps the check mark and strike-through",
                "✓" in await completed_task.inner_text()
                and "line-through" in (await completed_task.locator("span").last.get_attribute("class") or ""),
            )
            check(
                "task checklist is within the viewport",
                await checklist.evaluate(
                    "el => {const r=el.getBoundingClientRect();return r.width>0&&r.height>0"
                    "&&r.top>=0&&r.left>=0&&r.bottom<=innerHeight&&r.right<=innerWidth}"
                ),
            )
            await checklist.get_by_role("button", name="Collapse checklist", exact=True).click()
            check(
                "manual collapse hides task rows without removing the checklist",
                await checklist.get_attribute("data-collapsed") == "true"
                and await checklist.locator("[data-checklist-status]").count() == 0,
            )
            await checklist.get_by_role("button", name="Expand checklist", exact=True).click()
            check("manual expand restores the same task state", await task_group() == task_items)
            await fake_done.dispatch_event("click")
            await page.wait_for_function("!document.querySelector('.aui-composer-cancel')")
            await page.reload(wait_until="domcontentloaded")
            await checklist.wait_for(timeout=15000)
            check("TaskCreate/TaskUpdate history survives reload", await task_group() == task_items)

            websocket_open = await page.evaluate(
                "Boolean(window.Shiny?.shinyapp?.$socket) && "
                "window.Shiny.shinyapp.$socket.readyState === 1"
            )
            check("Shiny WebSocket remains open", bool(websocket_urls) and bool(websocket_open))
            check("no console errors", not console_errors, " | ".join(console_errors[:3]))
            check("no runtime exceptions", not runtime_errors, " | ".join(runtime_errors[:3]))
            check("no direct window error events", not window_errors, str(window_errors[:3]))
            check("no failed network requests", not network_errors, " | ".join(network_errors[:3]))
            check("no HTTP errors", not http_errors, " | ".join(http_errors[:3]))
        finally:
            await browser.close()

    if failures:
        print("FAILED:", ", ".join(failures))
        raise SystemExit(1)
    print("AGENT_CHECKLIST_AUTOFOLLOW_INSTALLED_VERIFY_OK")


if __name__ == "__main__":
    asyncio.run(main(
        sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:9197/",
        sys.argv[2] if len(sys.argv) > 2 else "",
    ))
