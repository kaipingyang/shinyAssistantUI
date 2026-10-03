// jsdom does not implement HTMLElement.scrollTo, while assistant-ui's viewport
// primitive correctly uses that browser API. Keep the polyfill test-only.
if (typeof HTMLElement !== "undefined" && !HTMLElement.prototype.scrollTo) {
  Object.defineProperty(HTMLElement.prototype, "scrollTo", {
    configurable: true,
    value(leftOrOptions?: number | ScrollToOptions, top?: number) {
      if (typeof leftOrOptions === "number") {
        this.scrollLeft = leftOrOptions;
        this.scrollTop = top ?? this.scrollTop;
        return;
      }
      if (leftOrOptions?.left !== undefined) this.scrollLeft = leftOrOptions.left;
      if (leftOrOptions?.top !== undefined) this.scrollTop = leftOrOptions.top;
    },
  });
}
