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
            await page.wait_for_selector(".aui-root", timeout=30000)
            model_trigger = page.locator('[data-slot="model-selector-trigger"]').first
            await model_trigger.wait_for(state="visible", timeout=90000)
            try:
                await page.wait_for_selector(
                    '[data-slot="aui_warming"]', state="detached", timeout=90000
                )
            except Exception:
                # No warming element is also the completed state.
                pass

            await page.wait_for_function(
                "Boolean(window.Shiny?.shinyapp?.$socket) && "
                "window.Shiny.shinyapp.$socket.readyState === 1",
                timeout=30000,
            )
            await page.evaluate("""
                window.__verifyTrace = [];
                window.__verifyModelTrace = [];
                window.__verifyT0 = null;
                window.__verifyLastStage = "";
                window.__verifyLastModel = "";
                window.__verifyCapture = () => {
                  if (window.__verifyT0 === null) return;
                  const at = performance.now() - window.__verifyT0;
                  const indicator = document.querySelector('[data-slot=aui_warming]');
                  if (indicator) {
                    const event = {
                      at, phase: indicator.getAttribute('data-run-phase') || '',
                      stage: indicator.getAttribute('data-run-stage') || '',
                      text: (indicator.textContent || '').trim()
                    };
                    const key = `${event.phase}|${event.stage}|${event.text}`;
                    if (key !== window.__verifyLastStage) {
                      window.__verifyTrace.push(event);
                      window.__verifyLastStage = key;
                    }
                  }
                  const control = document.querySelector('[data-slot=aui_model_control]');
                  const trigger = document.querySelector('[data-slot=model-selector-trigger]');
                  const modelEvent = {
                    at, pending: control?.getAttribute('data-pending') || '',
                    pendingText: (control?.querySelector('[data-slot=aui_model_pending]')?.textContent || '').trim(),
                    errorText: (control?.querySelector('[data-slot=aui_model_error]')?.textContent || '').trim(),
                    triggerText: (trigger?.textContent || '').trim()
                  };
                  const modelKey = JSON.stringify(modelEvent, ['pending', 'pendingText', 'errorText', 'triggerText']);
                  if (modelKey !== window.__verifyLastModel) {
                    window.__verifyModelTrace.push(modelEvent);
                    window.__verifyLastModel = modelKey;
                  }
                };
                new MutationObserver(window.__verifyCapture).observe(document.body, {
                  subtree: true, childList: true, attributes: true
                });
                window.__verifyCaptureTimer = setInterval(window.__verifyCapture, 10);
            """)
            await model_trigger.click()
            content = page.locator('[data-slot="model-selector-content"]').first
            await content.wait_for(state="visible", timeout=10000)
            sonnet = content.locator('[data-slot="model-selector-item"]', has_text="Sonnet").first
            await sonnet.wait_for(state="visible", timeout=10000)
            started = time.monotonic()
            await page.evaluate("window.__verifyT0 = performance.now(); window.__verifyCapture()")
            await sonnet.click()

            # Deliberately submit on the next browser task with no ack wait.
            composer = page.locator(
                ".aui-lexical-input[contenteditable='true']"
            ).first
            await composer.click()
            await page.keyboard.insert_text(
                "Reply with exactly MODEL_SWITCH_ACK_OK and no other text. Do not use tools."
            )
            await page.keyboard.press("Enter")

            await page.wait_for_selector('[data-role="user"]', timeout=10000)
            await page.wait_for_function(
                "(document.querySelector('[data-slot=model-selector-trigger]')?.innerText||'')"
                ".toLowerCase().includes('sonnet')",
                timeout=15000,
            )
            ack_elapsed = time.monotonic() - started
            sonnet_committed = "sonnet" in (await model_trigger.inner_text()).lower()
            await page.wait_for_function(
                "[...document.querySelectorAll('[data-role=assistant]')]"
                ".some(e=>e.innerText.includes('MODEL_SWITCH_ACK_OK'))",
                timeout=75000,
            )
            elapsed = time.monotonic() - started

            # Verify the canonical default value through the same acknowledged path.
            await model_trigger.click()
            await content.wait_for(state="visible", timeout=10000)
            default_item = content.locator(
                '[data-slot="model-selector-item"]', has_text="Default"
            ).first
            await default_item.wait_for(state="visible", timeout=10000)
            default_started = time.monotonic()
            await default_item.click()
            await page.wait_for_function(
                "(document.querySelector('[data-slot=model-selector-trigger]')?.innerText||'')"
                ".toLowerCase().includes('default')",
                timeout=30000,
            )
            default_ack_elapsed = time.monotonic() - default_started
            default_committed = "default" in (await model_trigger.inner_text()).lower()

            body_text = await page.locator("body").inner_text()
            websocket_open = await page.evaluate(
                "Boolean(window.Shiny?.shinyapp?.$socket) && "
                "window.Shiny.shinyapp.$socket.readyState === 1"
            )
            traces = await page.evaluate("window.__verifyTrace || []")
            model_traces = await page.evaluate("window.__verifyModelTrace || []")
            stages = [event.get("stage") for event in traces if event.get("stage")]
            expected_stages = [
                "submitting", "model-switch", "consumer-acquire", "sending",
                "awaiting-model", "finalizing",
            ]
            positions = [stages.index(stage) if stage in stages else -1 for stage in expected_stages]
            streaming_events = [event for event in traces if event.get("stage") == "streaming"]
            awaiting_events = [event for event in traces if event.get("stage") == "awaiting-model"]
            finalizing_events = [event for event in traces if event.get("stage") == "finalizing"]
            pending_visible = any(
                event.get("pending") == "true" and "Sonnet" in event.get("pendingText", "")
                for event in model_traces
            )
            first_stream_ms = streaming_events[0]["at"] if streaming_events else None
            awaiting_ms = awaiting_events[0]["at"] if awaiting_events else None
            finalizing_ms = finalizing_events[0]["at"] if finalizing_events else None

            check("prompt accepted immediately", True)
            check("model acknowledgement committed", sonnet_committed, f"ack={ack_elapsed:.3f}s")
            check(
                "default model acknowledgement committed",
                default_committed,
                f"ack={default_ack_elapsed:.3f}s",
            )
            check("model acknowledgement pending was visible", pending_visible)
            check("request stages appeared in order", all(position >= 0 for position in positions) and positions == sorted(positions), " -> ".join(stages))
            check("streaming stage appeared", bool(streaming_events))
            check("foreground reply completed", "MODEL_SWITCH_ACK_OK" in body_text)
            check(
                "phase timings captured",
                awaiting_ms is not None and first_stream_ms is not None and finalizing_ms is not None,
                f"awaiting={awaiting_ms}ms first={first_stream_ms}ms finalizing={finalizing_ms}ms total={elapsed * 1000:.0f}ms",
            )
            check("no 120-second idle-owner delay", elapsed < 75, f"elapsed={elapsed:.3f}s")
            check("no idle timeout surfaced", "Idle Claude turn timed out" not in body_text)
            check("Shiny WebSocket remains open", bool(websocket_open))
            check("no console errors", not console_errors, " | ".join(console_errors[:3]))
            check("no runtime exceptions", not runtime_errors, " | ".join(runtime_errors[:3]))
            check("no network request failures", not network_errors, " | ".join(network_errors[:3]))
            check("no frame crashes", not frame_errors, " | ".join(frame_errors[:3]))
        finally:
            await browser.close()

    if failures:
        raise RuntimeError("verification failed: " + ", ".join(failures))
    print("MODEL_SWITCH_ACK_BROWSER_VERIFY_DONE")


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1]))
