// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { FOOTER_HEIGHT_VAR, observeFooterHeight } from "./footer-height-var";

describe("observeFooterHeight", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("publishes the footer height and follows its resizes", () => {
    let callback: ResizeObserverCallback = () => undefined;
    const disconnect = vi.fn();
    vi.stubGlobal("ResizeObserver", class {
      constructor(cb: ResizeObserverCallback) { callback = cb; }
      observe() {}
      disconnect() { disconnect(); }
    });
    const viewport = document.createElement("div");
    const footer = document.createElement("div");
    footer.setAttribute("data-slot", "aui_thread-viewport-footer");
    viewport.appendChild(footer);
    let height = 120.2;
    footer.getBoundingClientRect = () => ({ height } as DOMRect);
    const stop = observeFooterHeight(viewport);
    expect(viewport.style.getPropertyValue(FOOTER_HEIGHT_VAR)).toBe("121px");
    height = 180;
    callback([], {} as ResizeObserver);
    expect(viewport.style.getPropertyValue(FOOTER_HEIGHT_VAR)).toBe("180px");
    stop();
    expect(disconnect).toHaveBeenCalledOnce();
    expect(viewport.style.getPropertyValue(FOOTER_HEIGHT_VAR)).toBe("");
  });

  it("does nothing without a footer", () => {
    const viewport = document.createElement("div");
    expect(() => observeFooterHeight(viewport)()).not.toThrow();
    expect(viewport.style.getPropertyValue(FOOTER_HEIGHT_VAR)).toBe("");
  });
});
