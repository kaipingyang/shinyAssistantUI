(() => {
  const normalize = (text) =>
    text.normalize("NFKC").toLowerCase().replace(/\s+/g, " ").trim();
  window.__auiSearchTimings = [];
  window.__auiSearchSent = [];
  window.__auiSearchLongTasks = [];
  window.__auiSearchLongTasksAvailable =
    typeof PerformanceObserver !== "undefined" &&
    PerformanceObserver.supportedEntryTypes.includes("longtask");
  if (window.__auiSearchLongTasksAvailable) {
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) {
        if (window.__auiSearchLongTasks.length < 200) {
          window.__auiSearchLongTasks.push({ start: entry.startTime, duration: entry.duration });
        }
      }
    }).observe({ type: "longtask", buffered: true });
  }
  document.addEventListener("input", (event) => {
    const input = event.target;
    if (!(input instanceof HTMLInputElement) ||
        input.getAttribute("aria-label") !== "Search history") return;
    const widget = ["chat", "workspace"].find((id) =>
      document.getElementById(id)?.contains(input));
    const root = document.getElementById(widget);
    const query = normalize(input.value);
    const started = performance.now();
    const frame = () => {
      const list = root.querySelector("[data-slot=aui_thread-list-outer-scroll]");
      const settled = list?.dataset.searchQuery === query &&
        list.getAttribute("aria-busy") === "false";
      if (settled || performance.now() - started > 3000) {
        const rows = root.querySelectorAll(
          "[data-slot=aui_thread-list-item], [data-slot=aui_thread-list-archived-item]",
        );
        window.__auiSearchTimings.push({
          widget, query, settled, startedAtMs: started, elapsedMs: performance.now() - started,
          visibility: document.visibilityState,
          rows: rows.length,
          rowIds: [...rows].map((row) => {
            const id = row.dataset.threadId;
            return `${row.dataset.slot}:${id.startsWith("t_") ? "new-thread" : id}`;
          }),
        });
      } else requestAnimationFrame(frame);
    };
    requestAnimationFrame(frame);
  }, true);
  window.__auiSearchInstallSpy = () => {
    const original = Shiny.setInputValue;
    Shiny.setInputValue = function (name, value, options) {
      if (name.startsWith("chat_input") || name.startsWith("workspace_input")) {
        window.__auiSearchSent.push({ name, type: value?.type ?? null });
      }
      return original.call(this, name, value, options);
    };
  };
})();
