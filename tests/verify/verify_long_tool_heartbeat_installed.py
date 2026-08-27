#!/usr/bin/env python3
import asyncio
import re
import sys
from playwright.async_api import async_playwright


def duration_seconds(text: str) -> float:
    text = text.strip()
    if text == "<1s":
        return 0.0
    minute = re.fullmatch(r"(\d+)m\s+(\d+)s", text)
    if minute:
        return int(minute.group(1)) * 60 + int(minute.group(2))
    seconds = re.fullmatch(r"([0-9.]+)s", text)
    if seconds:
        return float(seconds.group(1))
    raise ValueError(f"unexpected duration format: {text!r}")


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
        try:
            page = await browser.new_page(viewport={"width": 1000, "height": 900})
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
            await page.wait_for_function(
                "Boolean(window.Shiny?.shinyapp?.$socket) && "
                "window.Shiny.shinyapp.$socket.readyState === 1",
                timeout=15000,
            )

            marker = await page.locator(
                'meta[name="shinyassistant-heartbeat-package"]'
            ).get_attribute("content")
            check("installed Home package fixture loaded", marker == "installed-0.5.6", f"marker={marker}")

            composer = page.locator(".aui-lexical-input[contenteditable='true']").first
            await composer.click()
            await page.keyboard.insert_text("synthetic-heartbeat-marker")
            await page.keyboard.press("Enter")
            await page.wait_for_function(
                "document.querySelector('#fixture_ready')?.textContent?.trim() === 'ready'",
                timeout=15000,
            )
            await page.locator("#start_fake").dispatch_event("click")
            await page.wait_for_function(
                "document.querySelectorAll('[data-slot=tool-fallback-trigger]').length >= 2",
                timeout=15000,
            )

            bash = page.locator(
                '[data-slot="tool-fallback-trigger"][data-status="running"]'
                '[aria-label^="Running tool: Bash"]'
            ).first
            agent = page.locator(
                '[data-slot="tool-fallback-trigger"][data-status="running"]'
                '[aria-label^="Agent working: Agent"]'
            ).first
            task = page.locator('[data-slot="aui_task_card"][data-task-active="true"]').first
            await bash.wait_for(timeout=15000)
            await agent.wait_for(timeout=15000)
            await task.wait_for(timeout=15000)

            check("Bash running wording is explicit", await bash.count() == 1)
            check("Agent working wording is explicit", await agent.count() == 1)
            check(
                "Bash spinner and shimmer remain mounted",
                await bash.locator('[data-slot="tool-fallback-trigger-icon"].animate-spin').count() == 1
                and await bash.locator('[data-slot="tool-fallback-trigger-shimmer"]').count() == 1,
            )
            check(
                "Agent spinner and shimmer remain mounted",
                await agent.locator('[data-slot="tool-fallback-trigger-icon"].animate-spin').count() == 1
                and await agent.locator('[data-slot="tool-fallback-trigger-shimmer"]').count() == 1,
            )

            bash_samples: list[str] = []
            agent_samples: list[str] = []
            task_samples: list[int] = []
            for _ in range(3):
                bash_samples.append(
                    (await bash.locator('[data-slot="tool-fallback-duration"]').inner_text()).strip()
                )
                agent_samples.append(
                    (await agent.locator('[data-slot="tool-fallback-duration"]').inner_text()).strip()
                )
                task_text = await task.inner_text()
                match = re.search(r"·\s*(\d+)s(?:\s|$)", task_text)
                task_samples.append(int(match.group(1)) if match else -1)
                await page.wait_for_timeout(1150)

            bash_seconds = [duration_seconds(value) for value in bash_samples]
            agent_seconds = [duration_seconds(value) for value in agent_samples]
            check(
                "Bash elapsed advances at least twice without backend updates",
                len(set(bash_samples)) == 3 and bash_seconds == sorted(bash_seconds),
                f"samples={bash_samples}",
            )
            check(
                "Agent elapsed advances at least twice without polling",
                len(set(agent_samples)) == 3 and agent_seconds == sorted(agent_seconds),
                f"samples={agent_samples}",
            )
            check(
                "Task Monitor elapsed advances without TaskProgress",
                len(set(task_samples)) == 3 and task_samples == sorted(task_samples),
                f"samples={task_samples}",
            )

            await page.locator("#complete_fake").dispatch_event("click")
            await page.wait_for_function(
                "document.querySelectorAll('[data-slot=tool-fallback-trigger][data-status=running]').length === 0",
                timeout=12000,
            )
            await page.wait_for_function(
                "document.querySelectorAll('[data-slot=aui_task_card][data-task-active=true]').length === 0",
                timeout=5000,
            )

            complete_bash = page.locator(
                '[data-slot="tool-fallback-trigger"][data-status="complete"]'
                '[aria-label^="Used tool: Bash"]'
            ).first
            complete_agent = page.locator(
                '[data-slot="tool-fallback-trigger"][data-status="complete"]'
                '[aria-label^="Used tool: Agent"]'
            ).first
            settled_before = (
                await complete_agent.locator('[data-slot="tool-fallback-duration"]').inner_text()
            ).strip()
            await page.wait_for_timeout(1250)
            settled_after = (
                await complete_agent.locator('[data-slot="tool-fallback-duration"]').inner_text()
            ).strip()

            check("completed Bash returns to Used tool", await complete_bash.count() == 1)
            check("completed Agent returns to Used tool", await complete_agent.count() == 1)
            check(
                "completion removes active spinner and shimmer",
                await page.locator(
                    '[data-slot="tool-fallback-trigger"][data-status="complete"] '
                    '[data-slot="tool-fallback-trigger-shimmer"]'
                ).count() == 0
                and await page.locator(
                    '[data-slot="tool-fallback-trigger"][data-status="complete"] '
                    '[data-slot="tool-fallback-trigger-icon"].animate-spin'
                ).count() == 0,
            )
            check(
                "completed Agent duration is frozen",
                settled_before == settled_after,
                f"before={settled_before} after={settled_after}",
            )

            websocket_open = await page.evaluate(
                "Boolean(window.Shiny?.shinyapp?.$socket) && "
                "window.Shiny.shinyapp.$socket.readyState === 1"
            )
            check(
                "Shiny WebSocket remains open",
                bool(websocket_urls) and bool(websocket_open),
                f"observed={len(websocket_urls)}",
            )
            check("no console errors", not console_errors, " | ".join(console_errors[:3]))
            check("no runtime exceptions", not runtime_errors, " | ".join(runtime_errors[:3]))
            check("no failed network requests", not network_errors, " | ".join(network_errors[:3]))
            check("no HTTP errors", not http_errors, " | ".join(http_errors[:3]))
        finally:
            await browser.close()

    if failures:
        print("FAILED:", ", ".join(failures))
        raise SystemExit(1)
    print("HEARTBEAT_INSTALLED_VERIFY_OK")


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:9196/"))
