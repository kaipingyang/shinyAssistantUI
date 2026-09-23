import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { build } from "esbuild";
import { describe, expect, it } from "vitest";
import { deferAssistantViewportResize } from "../vite.config.mts";

const moduleId = "/node_modules/@assistant-ui/react/dist/utils/hooks/useOnResizeContent.js";

describe("assistant viewport resize scheduling compatibility", () => {
  it("does not transform application code or other dependency modules", () => {
    expect(deferAssistantViewportResize("unchanged", "/srcjs/runtime.ts")).toBeNull();
    expect(deferAssistantViewportResize("unchanged", `${moduleId}.map`)).toBeNull();
    expect(deferAssistantViewportResize("unchanged", moduleId.replace("useOnResizeContent", "useSizeHandle")))
      .toBeNull();
  });

  it("requires the verified upstream callback and cleanup shape", () => {
    const source = readFileSync(`.${moduleId}`, "utf8");
    expect(() => deferAssistantViewportResize("export const changed = true;", moduleId))
      .toThrow(/assistant-ui.*resize/i);
    expect(() => deferAssistantViewportResize(
      source.replace("resizeObserver.disconnect();", "resizeObserver.unobserve(el);"), moduleId,
    )).toThrow(/assistant-ui.*resize/i);
    expect(() => deferAssistantViewportResize(`${source}\n${source}`, moduleId))
      .toThrow(/assistant-ui.*resize/i);
  });

  it("coalesces real production-hook resize work, keeps mutation semantics and cancels on detach", async () => {
    const result = await build({
      stdin: {
        resolveDir: process.cwd(),
        sourcefile: "assistant-viewport-resize-probe.js",
        contents: `
          import assert from "node:assert/strict";
          import { createTapRoot, flushTapSync } from "@assistant-ui/tap";
          import { useState } from "react";
          import { useOnResizeContent } from "./node_modules/@assistant-ui/react/dist/utils/hooks/useOnResizeContent.js";

          async function main() {
            const frames = new Map(), cancelled = [], resizeObservers = [], mutationObservers = [];
            let nextFrame = 0, geometry = 10;
            globalThis.requestAnimationFrame = callback => {
              const id = nextFrame++;
              frames.set(id, callback);
              return id;
            };
            globalThis.cancelAnimationFrame = id => {
              cancelled.push(id);
              frames.delete(id);
            };
            const flushFrame = () => {
              const pending = [...frames.values()];
              frames.clear();
              for (const callback of pending) callback(0);
            };
            class Observer {
              constructor(callback) { this.callback = callback; this.disconnected = false; }
              observe(target, options) { this.target = target; this.options = options; }
              disconnect() { this.disconnected = true; }
              emit(records = []) { this.callback(records, this); }
            }
            globalThis.ResizeObserver = class extends Observer {
              constructor(callback) { super(callback); resizeObservers.push(this); }
            };
            globalThis.MutationObserver = class extends Observer {
              constructor(callback) { super(callback); mutationObservers.push(this); }
            };
            const calls = [];
            const root = createTapRoot(() => {
              const [revision, setRevision] = useState(0);
              const ref = useOnResizeContent(() => calls.push({ revision, geometry }));
              return { ref, setRevision };
            });
            try {
              const first = root.getValue();
              first.ref({ name: "old-viewport" });
              const oldResize = resizeObservers.at(-1);
              const oldMutation = mutationObservers.at(-1);
              oldResize.emit();
              assert.equal(calls.length, 0, "resize must not synchronously mutate the observed layout");
              assert.deepEqual([...frames.keys()], [0]);
              first.ref(null);
              assert.deepEqual(cancelled, [0], "frame ID zero must be cancelled");
              assert.equal(oldResize.disconnected, true);
              assert.equal(oldMutation.disconnected, true);
              flushFrame();
              assert.equal(calls.length, 0, "detached viewport must not receive queued work");

              first.ref({ name: "current-viewport" });
              const resize = resizeObservers.at(-1);
              const mutation = mutationObservers.at(-1);
              resize.emit();
              resize.emit();
              assert.equal(frames.size, 1, "resize notifications coalesce");
              assert.equal(calls.length, 0);
              geometry = 20;
              flushFrame();
              assert.deepEqual(calls, [{ revision: 0, geometry: 20 }]);

              resize.emit();
              flushTapSync(() => first.setRevision(1));
              await new Promise(resolve => setImmediate(resolve));
              geometry = 30;
              flushFrame();
              assert.deepEqual(calls.at(-1), { revision: 1, geometry: 30 });

              const beforeMutation = calls.length;
              mutation.emit([{ type: "attributes", attributeName: "style" }]);
              assert.equal(calls.length, beforeMutation, "style-only mutations remain filtered");
              mutation.emit([{ type: "attributes", attributeName: "class" }]);
              mutation.emit([{ type: "childList" }]);
              assert.equal(calls.length, beforeMutation + 2, "content mutations stay immediate");
              assert.equal(frames.size, 0);
              assert.deepEqual(mutation.options, {
                childList: true, subtree: true, attributes: true, characterData: true,
              });

              resize.emit();
              root.getValue().ref(null);
              flushFrame();
              assert.equal(calls.length, beforeMutation + 2);
              assert.equal(resize.disconnected, true);
              assert.equal(mutation.disconnected, true);
              console.log("viewport-resize-production-ok");
            } finally {
              root.getValue().ref(null);
              root.unmount();
            }
          }
          main().catch(error => { console.error(error); process.exitCode = 1; });
        `,
      },
      bundle: true,
      platform: "node",
      format: "cjs",
      write: false,
      logLevel: "silent",
      define: { "process.env.NODE_ENV": '"production"' },
      plugins: [{
        name: "production-viewport-resize-transform",
        setup(builder) {
          builder.onLoad({
            filter: /\/@assistant-ui\/react\/dist\/utils\/hooks\/useOnResizeContent\.js$/,
          }, ({ path }) => {
            const source = readFileSync(path, "utf8");
            const transformed = deferAssistantViewportResize(source, path);
            return { contents: transformed?.code ?? source, loader: "js" };
          });
        },
      }],
    });
    const output = execFileSync(process.execPath, [], {
      input: result.outputFiles[0]!.text,
      env: { ...process.env, NODE_ENV: "production" },
      encoding: "utf8",
      timeout: 10_000,
    });
    expect(output.trim()).toBe("viewport-resize-production-ok");
  });
});
