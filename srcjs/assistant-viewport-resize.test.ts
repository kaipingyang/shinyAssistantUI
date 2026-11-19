import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { build } from "esbuild";
import { describe, expect, it } from "vitest";
import {
  deferAssistantViewportResize,
  inlineGenerativeUiNodeEnv,
} from "../vite.config.mts";

describe("react-generative-ui browser environment compatibility", () => {
  it("inlines bracket NODE_ENV only inside the verified upstream package", () => {
    const source = 'if (process.env["NODE_ENV"] !== "production") warn();\n' +
      "if (process.env['NODE_ENV'] !== 'production') warn();";
    expect(inlineGenerativeUiNodeEnv(source, "/srcjs/runtime.ts")).toBeNull();
    const result = inlineGenerativeUiNodeEnv(
      source,
      "/node_modules/@assistant-ui/react-generative-ui/dist/actionRegistry.js",
    );
    expect(result?.code).not.toContain("process.env");
    expect(result?.code).toContain('if ("production" !== "production")');
    expect(result?.code).toContain("if (\"production\" !== 'production')");
  });
});


const moduleId = "/node_modules/@assistant-ui/store/dist/utils/viewport-scroll.js";

describe("assistant viewport resize scheduling compatibility", () => {
  it("does not transform application code or other dependency modules", () => {
    expect(deferAssistantViewportResize("unchanged", "/srcjs/runtime.ts")).toBeNull();
    expect(deferAssistantViewportResize("unchanged", `${moduleId}.map`)).toBeNull();
    expect(deferAssistantViewportResize("unchanged",
      "/node_modules/@assistant-ui/react/dist/utils/hooks/useSizeHandle.js")).toBeNull();
  });

  it("requires the verified upstream callback and cleanup shape", () => {
    const source = readFileSync(`.${moduleId}`, "utf8");
    expect(() => deferAssistantViewportResize("export const changed = true;", moduleId))
      .toThrow(/assistant-ui.*resize/i);
    expect(() => deferAssistantViewportResize(
      source.replace("for (const dispose of disposers) dispose();", "disposers.length = 0;"), moduleId,
    )).toThrow(/assistant-ui.*resize/i);
    expect(() => deferAssistantViewportResize(`${source}\n${source}`, moduleId))
      .toThrow(/assistant-ui.*resize/i);
  });

  it("coalesces real upstream resize work, keeps mutation semantics and cancels on detach", async () => {
    const result = await build({
      stdin: {
        resolveDir: process.cwd(),
        sourcefile: "assistant-viewport-resize-probe.js",
        contents: `
          import assert from "node:assert/strict";
          import { observeContentResize } from "./node_modules/@assistant-ui/store/dist/utils/viewport-scroll.js";

          const frames = new Map(), cancelled = [], resizeObservers = [], mutationObservers = [];
          let nextFrame = 0, geometry = 10;
          globalThis.Node = { ELEMENT_NODE: 1 };
          globalThis.requestAnimationFrame = callback => { const id = nextFrame++; frames.set(id, callback); return id; };
          globalThis.cancelAnimationFrame = id => { cancelled.push(id); frames.delete(id); };
          const flushFrame = () => { const pending = [...frames.values()]; frames.clear(); for (const cb of pending) cb(0); };
          class Observer {
            constructor(callback) { this.callback = callback; this.disconnected = false; this.targets = []; }
            observe(target, options) { this.targets.push(target); this.options = options; }
            unobserve() {}
            disconnect() { this.disconnected = true; }
            emit(records = []) { this.callback(records, this); }
          }
          globalThis.ResizeObserver = class extends Observer { constructor(cb) { super(cb); resizeObservers.push(this); } };
          globalThis.MutationObserver = class extends Observer { constructor(cb) { super(cb); mutationObservers.push(this); } };
          const calls = [];
          const viewport = () => ({ children: [] });

          const detachOld = observeContentResize(viewport(), () => calls.push(geometry));
          const oldResize = resizeObservers.at(-1), oldMutation = mutationObservers.at(-1);
          oldResize.emit();
          assert.equal(calls.length, 0, "resize must not synchronously mutate the observed layout");
          assert.deepEqual([...frames.keys()], [0]);
          detachOld();
          assert.deepEqual(cancelled, [0], "frame ID zero must be cancelled");
          assert.equal(oldResize.disconnected, true);
          assert.equal(oldMutation.disconnected, true);
          flushFrame();
          assert.equal(calls.length, 0, "detached viewport must not receive queued work");

          const detach = observeContentResize(viewport(), () => calls.push(geometry));
          const resize = resizeObservers.at(-1), mutation = mutationObservers.at(-1);
          resize.emit(); resize.emit();
          assert.equal(frames.size, 1, "resize notifications coalesce");
          geometry = 20;
          flushFrame();
          assert.deepEqual(calls, [20], "the frame reads the latest geometry");

          const before = calls.length;
          mutation.emit([{ type: "attributes", attributeName: "style", target: null, addedNodes: [], removedNodes: [] }]);
          assert.equal(calls.length, before, "style-only mutations remain filtered");
          mutation.emit([{ type: "attributes", attributeName: "class", target: null, addedNodes: [], removedNodes: [] }]);
          mutation.emit([{ type: "childList", target: null, addedNodes: [], removedNodes: [] }]);
          assert.equal(calls.length, before + 2, "content mutations stay immediate");
          assert.deepEqual(mutation.options, { childList: true, subtree: true, attributes: true, characterData: true });

          resize.emit();
          detach();
          flushFrame();
          assert.equal(calls.length, before + 2);
          assert.equal(resize.disconnected, true);
          assert.equal(mutation.disconnected, true);
          console.log("viewport-resize-production-ok");
        `,
      },
      bundle: true,
      platform: "node",
      format: "cjs",
      write: false,
      logLevel: "silent",
      plugins: [{
        name: "production-viewport-resize-transform",
        setup(builder) {
          builder.onLoad({ filter: /\/@assistant-ui\/store\/dist\/utils\/viewport-scroll\.js$/ }, ({ path }) => {
            const source = readFileSync(path, "utf8");
            const transformed = deferAssistantViewportResize(source, path);
            if (!transformed) throw new Error("transform did not apply");
            return { contents: transformed.code, loader: "js" };
          });
        },
      }],
    });
    const output = execFileSync(process.execPath, [], {
      input: result.outputFiles[0]!.text,
      encoding: "utf8",
      timeout: 10_000,
    });
    expect(output.trim()).toBe("viewport-resize-production-ok");
  });
});
