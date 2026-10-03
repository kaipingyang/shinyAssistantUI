(() => {
  const tailPattern = /FOLLOW_TAIL_(\d{4})/g;
  const anchorPattern = /FOLLOW_(?:BASE|HISTORY|REPLY|TAIL)_\d{4}/g;
  const samples = [];
  const events = [];
  let phase = "mount";
  let recording = false;
  let frame = null;
  let timer = null;
  let anchor = null;
  let previousTail = 0;
  let tailSince = performance.now();
  const nodeIds = new WeakMap();
  let nextNodeId = 0;
  const nodeId = (element) => {
    if (!element) return null;
    if (!nodeIds.has(element)) nodeIds.set(element, ++nextNodeId);
    return nodeIds.get(element);
  };
  const viewport = () => document.querySelector('[data-slot="aui_thread-viewport"]');
  const fixture = () => {
    const text = document.getElementById("fixture_state")?.textContent.trim();
    return text ? JSON.parse(text) : { sequence: 0, done: true, phase: "boot" };
  };
  const rectData = (node, start, end, root) => {
    const range = document.createRange();
    range.setStart(node, Math.max(start, end - 4));
    range.setEnd(node, end);
    const rect = range.getBoundingClientRect();
    const clip = { top: 0, bottom: innerHeight, left: 0, right: innerWidth };
    let inner = null;
    for (let el = node.parentElement; el; el = el.parentElement) {
      const style = getComputedStyle(el);
      const bounds = el.getBoundingClientRect();
      if (el === root || /auto|scroll|hidden|clip/.test(style.overflowY)) {
        clip.top = Math.max(clip.top, bounds.top + el.clientTop);
        clip.bottom = Math.min(clip.bottom, bounds.top + el.clientTop + el.clientHeight);
      }
      if (el === root || /auto|scroll|hidden|clip/.test(style.overflowX)) {
        clip.left = Math.max(clip.left, bounds.left + el.clientLeft);
        clip.right = Math.min(clip.right, bounds.left + el.clientLeft + el.clientWidth);
      }
      if (!inner && el !== root && /auto|scroll/.test(style.overflowY) &&
          el.scrollHeight > el.clientHeight + 1) {
        inner = {
          region: el.dataset.toolScrollRegion || el.dataset.slot || el.tagName,
          top: el.scrollTop,
          height: el.clientHeight,
          gap: el.scrollHeight - el.clientHeight - el.scrollTop,
        };
      }
    }
    const footer = root.querySelector('[data-slot="aui_thread-viewport-footer"]');
    if (footer && !footer.contains(node)) {
      const bounds = footer.getBoundingClientRect();
      if (bounds.height > 0 && bounds.bottom > clip.top && bounds.top < clip.bottom) {
        clip.bottom = Math.min(clip.bottom, bounds.top);
      }
    }
    const question = root.querySelector('[data-slot="aui_current_question"]');
    if (question && !question.contains(node)) {
      const bounds = question.getBoundingClientRect();
      if (bounds.top <= clip.top + 1 && bounds.bottom > clip.top) {
        clip.top = Math.max(clip.top, bounds.bottom);
      }
    }
    return {
      top: rect.top, bottom: rect.bottom, height: rect.height,
      clipTop: clip.top, clipBottom: clip.bottom,
      visible: rect.width > 0 && rect.height > 0 &&
        rect.top >= clip.top - 1 && rect.bottom <= clip.bottom + 1 &&
        rect.left >= clip.left - 1 && rect.right <= clip.right + 1,
      inner,
    };
  };
  const scan = (pickAnchor = false) => {
    const root = viewport();
    if (!root) return null;
    const messages = root.querySelector('[data-slot="aui_message-group"]');
    if (!messages) return null;
    const walker = document.createTreeWalker(messages, NodeFilter.SHOW_TEXT);
    let latest = null;
    let anchorRect = null;
    let candidate = null;
    let node;
    while ((node = walker.nextNode())) {
      const text = node.data;
      for (const match of text.matchAll(tailPattern)) {
        const sequence = Number(match[1]);
        if (latest && sequence < latest.sequence) continue;
        const geometry = rectData(node, match.index, match.index + match[0].length, root);
        if (geometry.height > 0) latest = { sequence, ...geometry };
      }
      if (anchor && text.includes(anchor)) {
        const start = text.indexOf(anchor);
        anchorRect = rectData(node, start, start + anchor.length, root);
      }
      if (pickAnchor) {
        for (const match of text.matchAll(anchorPattern)) {
          const geometry = rectData(node, match.index, match.index + match[0].length, root);
          if (geometry.visible && (!candidate || geometry.top < candidate.top)) {
            candidate = { marker: match[0], top: geometry.top };
          }
        }
      }
    }
    return { root, latest, anchorRect, candidate };
  };
  const snapshot = () => {
    const view = scan();
    if (!view) return { ready: false };
    const state = fixture();
    const now = performance.now();
    const rendered = view.latest?.sequence || 0;
    if (rendered !== previousTail) {
      previousTail = rendered;
      tailSince = now;
    }
    const tool = view.root.querySelector(".aui-shiny-tool");
    const args = tool?.querySelector("[data-arg-view]");
    const preview = tool?.querySelector("[data-markdown-preview]");
    const markdown = preview?.querySelector(".aui-md");
    const liveRow = [...view.root.querySelectorAll('[data-slot="aui_message-slot"]')].at(-1);
    const textParts = liveRow ? [...liveRow.querySelectorAll('[data-slot="aui_assistant-text"]')] : [];
    const content = textParts.at(-1) || liveRow?.querySelector("[data-markdown-preview] .aui-md") ||
      liveRow?.querySelector(".aui-reasoning-text-content");
    let renderedTail = null;
    if (content) {
      const walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT);
      let last = null;
      let node;
      while ((node = walker.nextNode())) if (node.data.trim()) last = node;
      const end = last ? last.data.search(/\s*$/) : 0;
      renderedTail = {
        rowNode: nodeId(liveRow),
        messageNode: nodeId(liveRow.querySelector('[data-role="assistant"]')),
        contentNode: nodeId(content),
        chars: content.textContent.length,
        geometry: last ? rectData(last, Math.max(0, end - 4), end, view.root) : null,
      };
    }
    return {
      ready: true, at: now, phase,
      fixturePhase: state.phase,
      delivered: state.sequence,
      done: state.done,
      rendered,
      renderedAgeMs: now - tailSince,
      visible: view.latest?.visible ?? false,
      tailTop: view.latest?.top ?? null,
      tailBottom: view.latest?.bottom ?? null,
      clipTop: view.latest?.clipTop ?? null,
      clipBottom: view.latest?.clipBottom ?? null,
      inner: view.latest?.inner ?? null,
      outerTop: view.root.scrollTop,
      outerHeight: view.root.scrollHeight,
      outerClient: view.root.clientHeight,
      outerGap: view.root.scrollHeight - view.root.clientHeight - view.root.scrollTop,
      anchor,
      anchorTop: view.anchorRect?.top ?? null,
      running: Boolean(document.querySelector(".aui-composer-cancel")),
      renderedTail,
      tool: tool ? {
        node: nodeId(tool), kind: args?.dataset.argView || null,
        streaming: args?.dataset.argsStreaming || null,
        previewNode: nodeId(preview), markdownNode: nodeId(markdown),
        renderedChars: preview?.textContent.length || 0,
        top: preview?.scrollTop ?? null,
        height: preview?.clientHeight ?? null,
        scrollHeight: preview?.scrollHeight ?? null,
      } : null,
    };
  };
  const loop = () => {
    frame = requestAnimationFrame(() => {
      timer = setTimeout(() => {
        if (!recording) return;
        if (samples.length < 2400) samples.push(snapshot());
        loop();
      }, 0);
    });
  };
  const note = (event) => {
    const root = viewport();
    const target = event.target instanceof Element ? event.target : null;
    if (!recording || !root || !target || !root.contains(target)) return;
    if (events.length >= 2000) return;
    const row = { at: performance.now(), type: event.type, phase, trusted: event.isTrusted };
    if (event.type === "wheel") row.deltaY = event.deltaY;
    if (event.type === "keydown") {
      if (!["PageUp", "PageDown", "ArrowUp", "ArrowDown", "Home", "End", "Enter"].includes(event.key)) return;
      row.key = event.key;
      row.editing = Boolean(target.closest("input,textarea,[contenteditable=true]"));
    }
    if (event.type === "scroll") {
      row.region = target === root ? "outer" : target.dataset.toolScrollRegion || target.dataset.slot || target.tagName;
      row.top = target.scrollTop;
      row.height = target.scrollHeight;
      row.client = target.clientHeight;
    }
    events.push(row);
  };
  for (const type of ["wheel", "keydown", "scroll", "pointerdown", "pointerup"]) {
    document.addEventListener(type, note, { capture: true, passive: true });
  }
  window.followProbe = {
    start() {
      samples.length = 0;
      events.length = 0;
      phase = "auto";
      recording = true;
      loop();
    },
    mark(value) {
      phase = value;
      events.push({ at: performance.now(), type: "phase", phase });
    },
    pickAnchor() {
      const candidate = scan(true)?.candidate;
      anchor = candidate?.marker || null;
      return candidate;
    },
    snapshot,
    stop() {
      recording = false;
      if (frame !== null) cancelAnimationFrame(frame);
      if (timer !== null) clearTimeout(timer);
      return { samples, events, final: snapshot() };
    },
  };
})();
