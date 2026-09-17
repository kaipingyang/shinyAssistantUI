(() => {
  "use strict";
  if (globalThis.__plan123Perf) return;

  const nativeRequestAnimationFrame = globalThis.requestAnimationFrame.bind(globalThis);
  const nativeCancelAnimationFrame = globalThis.cancelAnimationFrame.bind(globalThis);
  const nativeSetTimeout = globalThis.setTimeout.bind(globalThis);
  const NativeMutationObserver = globalThis.MutationObserver;
  const NativePerformanceObserver = globalThis.PerformanceObserver;
  const productSchedulers = {
    rafArms: 0, rafFires: 0, rafCancels: 0, activeRaf: 0, maxRafDepth: 0,
    orbRafArms: 0, orbRafFires: 0, orbRafCancels: 0, activeOrbRaf: 0,
    intervalArms: 0, intervalFires: 0, intervalCancels: 0, activeIntervals: 0,
    domPollArms: 0,
    mutationObserverArms: 0, mutationObserverDisconnects: 0,
  };
  const activeRafIds = new Set();
  const activeOrbRafIds = new Set();
  const orbRafSignatures = new Set();
  let orbProfileActive = false;
  const stackSignature = () => {
    const stack = String(new Error().stack ?? "").split("\n").slice(2, 5).join("\n")
      .replace(/https?:\/\/[^/) ]+/g, "<origin>");
    let hash = 2166136261;
    for (let index = 0; index < stack.length; index += 1) {
      hash ^= stack.charCodeAt(index);
      hash = Math.imul(hash, 16777619);
    }
    return (hash >>> 0).toString(16).padStart(8, "0");
  };
  const activeIntervalIds = new Set();
  const realSetInterval = globalThis.setInterval.bind(globalThis);
  const realClearInterval = globalThis.clearInterval.bind(globalThis);

  globalThis.requestAnimationFrame = (callback) => {
    productSchedulers.rafArms += 1;
    const signature = stackSignature();
    if (orbProfileActive) orbRafSignatures.add(signature);
    const isOrb = orbRafSignatures.has(signature);
    if (isOrb) productSchedulers.orbRafArms += 1;
    let id = 0;
    id = nativeRequestAnimationFrame((timestamp) => {
      if (activeRafIds.delete(id)) productSchedulers.activeRaf -= 1;
      if (activeOrbRafIds.delete(id)) {
        productSchedulers.activeOrbRaf -= 1;
        productSchedulers.orbRafFires += 1;
      }
      productSchedulers.rafFires += 1;
      callback(timestamp);
    });
    activeRafIds.add(id);
    productSchedulers.activeRaf += 1;
    if (isOrb) {
      activeOrbRafIds.add(id);
      productSchedulers.activeOrbRaf += 1;
    }
    productSchedulers.maxRafDepth = Math.max(productSchedulers.maxRafDepth, productSchedulers.activeRaf);
    return id;
  };
  globalThis.cancelAnimationFrame = (id) => {
    if (activeRafIds.delete(id)) {
      productSchedulers.activeRaf -= 1;
      productSchedulers.rafCancels += 1;
    }
    if (activeOrbRafIds.delete(id)) {
      productSchedulers.activeOrbRaf -= 1;
      productSchedulers.orbRafCancels += 1;
    }
    return nativeCancelAnimationFrame(id);
  };
  globalThis.setInterval = (callback, delay, ...args) => {
    productSchedulers.intervalArms += 1;
    try {
      const source = Function.prototype.toString.call(callback);
      if (/querySelector|getElementsBy|document\./.test(source)) productSchedulers.domPollArms += 1;
    } catch (_) { /* counting is fail-open */ }
    const id = realSetInterval((...callbackArgs) => {
      productSchedulers.intervalFires += 1;
      callback(...callbackArgs);
    }, delay, ...args);
    activeIntervalIds.add(id);
    productSchedulers.activeIntervals += 1;
    return id;
  };
  globalThis.clearInterval = (id) => {
    if (activeIntervalIds.delete(id)) {
      productSchedulers.activeIntervals -= 1;
      productSchedulers.intervalCancels += 1;
    }
    return realClearInterval(id);
  };
  if (NativeMutationObserver) {
    globalThis.MutationObserver = class CountingMutationObserver extends NativeMutationObserver {
      constructor(callback) {
        super(callback);
        this.__plan123Disconnected = false;
      }
      observe(...args) {
        productSchedulers.mutationObserverArms += 1;
        return super.observe(...args);
      }
      disconnect() {
        if (!this.__plan123Disconnected) {
          productSchedulers.mutationObserverDisconnects += 1;
          this.__plan123Disconnected = true;
        }
        return super.disconnect();
      }
    };
  }

  const results = new Map();
  const pending = new Map();
  const longTasks = { rows: [], keys: new Set() };
  let longTaskObserver;
  if (NativePerformanceObserver) {
    try {
      longTaskObserver = new NativePerformanceObserver((list) => {
        for (const entry of list.getEntries()) {
          const key = `${entry.startTime}:${entry.duration}`;
          if (longTasks.keys.has(key)) continue;
          longTasks.keys.add(key);
          longTasks.rows.push({ startTime: entry.startTime, duration: entry.duration });
        }
      });
      longTaskObserver.observe({ type: "longtask", buffered: true });
    } catch (_) { longTaskObserver = undefined; }
  }

  const normalizeText = (value) => String(value ?? "").replace(/\s+/g, " ").trim();
  const semanticProjection = (container) => {
    const markdown = container?.querySelector("[data-slot='aui_assistant-text'] .aui-md");
    if (!markdown) return { text: "", semantic: "" };
    const blocks = Array.from(markdown.querySelectorAll("h1,h2,h3,h4,h5,h6,p,li,pre,blockquote,table"));
    const selected = blocks.filter((node) => !blocks.some((other) => other !== node && other.contains(node) &&
      ["LI", "PRE", "BLOCKQUOTE", "TABLE"].includes(other.tagName)));
    const semantic = selected.map((node) => `<${node.tagName.toLowerCase()}>${normalizeText(node.innerText ?? node.textContent)}</${node.tagName.toLowerCase()}>`).join("");
    return { text: normalizeText(markdown.innerText ?? markdown.textContent), semantic };
  };
  const sha256 = async (value) => {
    const bytes = new TextEncoder().encode(value);
    const hash = await crypto.subtle.digest("SHA-256", bytes);
    return Array.from(new Uint8Array(hash), (byte) => byte.toString(16).padStart(2, "0")).join("");
  };
  const fixturePreprocess = (markdown) => {
    const started = performance.now();
    // Same fixed fixture input is scanned in both conditions. The installed wrapper
    // still executes its real owned LaTeX preprocessing; this sidecar timing is the
    // symmetric benchmark-only observation and never enters production telemetry.
    let output = "";
    for (let index = 0; index < markdown.length; index += 1) output += markdown[index];
    return { output, durationMs: Math.max(0, performance.now() - started) };
  };
  const resetSchedulers = () => {
    for (const key of Object.keys(productSchedulers)) {
      if (key === "activeRaf" || key === "activeOrbRaf" || key === "activeIntervals") continue;
      productSchedulers[key] = 0;
    }
    productSchedulers.activeRaf = activeRafIds.size;
    productSchedulers.activeOrbRaf = activeOrbRafIds.size;
    productSchedulers.activeIntervals = activeIntervalIds.size;
  };
  const schedulerSnapshot = () => ({ ...productSchedulers });

  const receive = (payload) => {
    const fixtureOrdinal = payload?.fixtureOrdinal;
    const fixtureInstance = payload?.fixtureInstance;
    if (!Number.isSafeInteger(fixtureOrdinal) || fixtureOrdinal <= 0 ||
        !/^[0-9a-f]{32}$/.test(fixtureInstance ?? "")) return false;
    const key = `${fixtureOrdinal}:${fixtureInstance}`;
    if (pending.has(key) || results.has(key)) return false;
    const expectedText = normalizeText(payload.expectedText);
    const expectedSha256 = String(payload.expectedSha256 ?? "");
    const preprocess = fixturePreprocess(String(payload.markdown ?? ""));
    const existing = new Set(document.querySelectorAll("[data-role='assistant']"));
    const state = {
      key, fixtureOrdinal, fixtureInstance, expectedText, expectedSha256,
      callbackEpochMs: Number(payload.callbackEpochMs), receivePerfMs: performance.now(),
      preprocessMs: preprocess.durationMs, lastMutationMs: performance.now(), quietFrames: 0,
      firstSemanticMatchPerfMs: null, firstSemanticMatchEpochMs: null,
      mutationGeneration: 0, semanticMatches: false, latestProjection: null, latestSemanticSha256: null,
      frameTimestamps: [], observer: null, rootObserver: null, rafId: null, timeoutId: null,
      container: null, stopped: false,
    };
    pending.set(key, state);

    const finish = (ok, reason, projection, semanticSha256) => {
      if (state.stopped) return;
      state.stopped = true;
      state.observer?.disconnect();
      state.rootObserver?.disconnect();
      if (state.rafId !== null) nativeCancelAnimationFrame(state.rafId);
      if (state.timeoutId !== null) clearTimeout(state.timeoutId);
      const now = performance.now();
      const frameIntervals = state.frameTimestamps.slice(1).map((time, index) => time - state.frameTimestamps[index]);
      const callbackToDomMs = state.firstSemanticMatchPerfMs !== null
        ? state.firstSemanticMatchPerfMs - state.receivePerfMs
        : null;
      const serverCallbackToDomMs = Number.isFinite(state.callbackEpochMs) && state.firstSemanticMatchEpochMs !== null
        ? state.firstSemanticMatchEpochMs - state.callbackEpochMs
        : null;
      results.set(key, {
        ok, reason, fixtureOrdinal, fixtureInstance, expectedSha256,
        semanticSha256: semanticSha256 ?? null,
        textMatch: projection ? projection.text === expectedText : false,
        semanticText: projection?.text ?? "",
        semanticProjection: projection?.semantic ?? "",
        receiveToDomMs: now - state.receivePerfMs,
        callbackToDomMs,
        serverCallbackToDomMs,
        preprocessMs: state.preprocessMs,
        quietFrames: state.quietFrames,
        quietMs: now - state.lastMutationMs,
        frameIntervals,
        scheduler: schedulerSnapshot(),
      });
      pending.delete(key);
    };
    const checkSemantic = async () => {
      if (state.stopped || !state.container?.isConnected) return;
      const generation = state.mutationGeneration;
      const projection = semanticProjection(state.container);
      const digest = await sha256(projection.semantic);
      if (state.stopped || generation !== state.mutationGeneration) return;
      state.latestProjection = projection;
      state.latestSemanticSha256 = digest;
      state.semanticMatches = projection.text === expectedText && digest === expectedSha256;
      if (state.semanticMatches && state.firstSemanticMatchPerfMs === null) {
        state.firstSemanticMatchPerfMs = performance.now();
        state.firstSemanticMatchEpochMs = Date.now();
      }
    };
    const frame = (timestamp) => {
      if (state.stopped) return;
      state.frameTimestamps.push(timestamp);
      state.quietFrames += 1;
      if (state.container && state.container.isConnected) {
        const quietMs = performance.now() - state.lastMutationMs;
        if (state.semanticMatches && state.quietFrames >= 2 && quietMs >= 100) {
          finish(true, "ok", state.latestProjection, state.latestSemanticSha256);
          return;
        }
      } else if (state.container && !state.container.isConnected) {
        finish(false, "container_replaced", null, null);
        return;
      }
      state.rafId = nativeRequestAnimationFrame(frame);
    };
    const attach = (container) => {
      if (state.container || !container) return;
      state.container = container;
      state.lastMutationMs = performance.now();
      state.quietFrames = 0;
      state.rootObserver?.disconnect();
      state.observer = new NativeMutationObserver(() => {
        state.lastMutationMs = performance.now();
        state.quietFrames = 0;
        state.mutationGeneration += 1;
        state.semanticMatches = false;
        void checkSemantic();
      });
      state.observer.observe(container, { childList: true, subtree: true, characterData: true, attributes: false });
      void checkSemantic();
      state.rafId = nativeRequestAnimationFrame(frame);
    };
    state.rootObserver = new NativeMutationObserver(() => {
      const candidates = Array.from(document.querySelectorAll("[data-role='assistant']"));
      attach(candidates.find((node) => !existing.has(node)));
    });
    state.rootObserver.observe(document.documentElement, { childList: true, subtree: true });
    const immediate = Array.from(document.querySelectorAll("[data-role='assistant']")).find((node) => !existing.has(node));
    attach(immediate);
    state.timeoutId = nativeSetTimeout(() => finish(false, "timeout", state.container ? semanticProjection(state.container) : null, null), 10_000);
    return true;
  };

  const frameProbe = (count = 12) => new Promise((resolve) => {
    const timestamps = [];
    const tick = (timestamp) => {
      timestamps.push(timestamp);
      if (timestamps.length >= count + 1) {
        resolve(timestamps.slice(1).map((time, index) => time - timestamps[index]));
      } else nativeRequestAnimationFrame(tick);
    };
    nativeRequestAnimationFrame(tick);
  });
  const settle = () => new Promise((resolve) => {
    nativeSetTimeout(() => nativeRequestAnimationFrame(() => nativeRequestAnimationFrame(
      () => nativeSetTimeout(resolve, 100)
    )), 0);
  });
  const longTaskPreflight = async () => {
    longTasks.rows.length = 0;
    longTasks.keys.clear();
    await new Promise((resolve) => nativeSetTimeout(() => {
      const started = performance.now();
      while (performance.now() - started < 70) { /* intentional fixture-only task */ }
      resolve();
    }, 0));
    await new Promise((resolve) => nativeSetTimeout(resolve, 150));
    const beforeClear = { count: longTasks.rows.length, unique: longTasks.keys.size,
      durations: longTasks.rows.map((row) => row.duration) };
    longTasks.rows.length = 0;
    longTasks.keys.clear();
    return { supported: Boolean(longTaskObserver), beforeClear, afterClear: { count: 0, unique: 0 } };
  };

  globalThis.__plan123Perf = Object.freeze({
    nativeRequestAnimationFrame,
    receive,
    result: (key) => results.get(key) ?? null,
    resetSchedulers,
    schedulerSnapshot,
    beginOrbProfile: () => { orbProfileActive = true; },
    endOrbProfile: () => { orbProfileActive = false; return Array.from(orbRafSignatures); },
    seedOrbSignatures: (values) => {
      if (!Array.isArray(values) || values.some((value) => !/^[0-9a-f]{8}$/.test(value))) return false;
      for (const value of values) orbRafSignatures.add(value);
      return true;
    },
    semanticProjection,
    frameProbe,
    settle,
    longTaskPreflight,
    visibility: () => document.visibilityState,
  });
})();
