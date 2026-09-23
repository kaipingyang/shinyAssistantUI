(() => {
  const phases = {};
  let current = null;
  let observeHistory = null;
  let enabled = false;
  const clock = () => performance.now();
  const collectLongTasks = (rows) => {
    for (const entry of rows) {
      for (const phase of Object.values(phases)) {
        if (entry.startTime >= phase.started && entry.startTime < (phase.ended ?? Infinity)) {
          phase.longTasks.push({ start: entry.startTime - phase.started, duration: entry.duration });
          break;
        }
      }
    }
  };
  const supportsLongTasks = PerformanceObserver.supportedEntryTypes.includes("longtask");
  const longTasks = supportsLongTasks ? new PerformanceObserver((list) => collectLongTasks(list.getEntries())) : null;
  longTasks?.observe({ type: "longtask", buffered: true });
  document.addEventListener("beforeinput", (event) => {
    if (!current || !event.target?.closest?.("#chat .aui-lexical-input")) return;
    const phase = current;
    const start = clock();
    if (enabled && document.querySelector("#chat code[data-file-ref-candidate]")) phase.inputsDuringConfirmation += 1;
    requestAnimationFrame(() => phase.inputFrameMs.push(clock() - start));
  }, true);

  const geometry = () => ({
    domNodes: document.querySelectorAll("*").length,
    mountedMessages: document.querySelectorAll("#chat [data-slot=aui_message-slot]").length,
    confirmedReferences: document.querySelectorAll("#chat code[data-file-ref]").length,
    unconfirmedReferences: document.querySelectorAll("#chat code[data-file-ref-candidate]").length,
  });
  const checkHistory = () => {
    const phase = phases.initial;
    if (!phase || phase.ended != null) return;
    const last = document.querySelector("#chat [data-message-index='239']");
    if (!last?.textContent.includes("BENCH_LAST_MESSAGE")) return;
    phase.historyReadyMs ??= clock() - phase.started;
    const nodes = geometry();
    if (enabled && nodes.confirmedReferences > 0 && nodes.unconfirmedReferences === 0) {
      phase.confirmedMs ??= clock() - phase.started;
    } else if (enabled) {
      phase.confirmedMs = null;
    }
  };
  window.__fileReferencePerf = {
    begin(name, confirmationEnabled) {
      observeHistory?.disconnect();
      enabled = confirmationEnabled;
      current = phases[name] = {
        started: clock(), ended: null, inputFrameMs: [], longTasks: [],
        historyReadyMs: null, confirmedMs: null, inputsDuringConfirmation: 0,
      };
      if (name === "initial") {
        observeHistory = new MutationObserver(checkHistory);
        observeHistory.observe(document.getElementById("chat"), {
          childList: true, subtree: true, characterData: true, attributes: true,
          attributeFilter: ["data-file-ref", "data-file-ref-candidate", "data-message-index"],
        });
      }
    },
    ready() {
      checkHistory();
      const phase = phases.initial;
      return phase?.historyReadyMs != null &&
        (!enabled || (phase.confirmedMs != null && geometry().unconfirmedReferences === 0));
    },
    snapshot(name, finish = false) {
      checkHistory();
      collectLongTasks(longTasks?.takeRecords() ?? []);
      const phase = phases[name];
      if (finish) {
        phase.ended = clock();
        current = null;
        observeHistory?.disconnect();
      }
      return { ...phase, supportsLongTasks, ...geometry() };
    },
  };
})();
