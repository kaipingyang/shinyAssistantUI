import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { build } from "esbuild";
import { describe, expect, it } from "vitest";
import { stabilizeAssistantStoreContext } from "../vite.config.mts";

const moduleId = "/node_modules/@assistant-ui/store/dist/useAui.js";

describe("assistant store event-context compatibility", () => {
  it("does not transform application code or other dependency modules", () => {
    expect(stabilizeAssistantStoreContext("unchanged", "/srcjs/runtime.ts")).toBeNull();
    expect(stabilizeAssistantStoreContext("unchanged", `${moduleId}.map`)).toBeNull();
  });

  it("fails explicitly if the upstream context shape changes", () => {
    expect(() => stabilizeAssistantStoreContext("export const changed = true;", moduleId))
      .toThrow(/assistant-ui.*context/i);
  });

  it("isolates typing from immutable history without suppressing child state or events", async () => {
    const result = await build({
      stdin: {
        resolveDir: process.cwd(),
        sourcefile: "assistant-store-context-probe.js",
        contents: `
          import { AuiConfig, createAssistantClient, useAssistantEmit, useClientLookup } from "@assistant-ui/store/client";
          import { resource, withKey, flushTapSync } from "@assistant-ui/tap";
          import { useState } from "react";

          async function main() {
          const rendered = [];
          const Message = resource(id => {
            rendered.push(id);
            const [text, setText] = useState("original");
            const emit = useAssistantEmit();
            return {
              getState: () => ({ id, text }),
              setText,
              send: () => emit("composer.send", { threadId: "history", messageId: id }),
            };
          });
          const Thread = resource(() => {
            const [text, setText] = useState("");
            const messages = useClientLookup(Array.from({ length: 240 }, (_, id) =>
              withKey(id, Message(id), [id])
            ));
            return {
              getState: () => ({ text, messages: messages.state }),
              setText,
              message: index => messages.get({ index }),
            };
          });
          const handle = createAssistantClient(AuiConfig({ threads: Thread() }));
          const unsubscribe = handle.subscribe(() => {});
          const events = [];
          const offEvent = handle.getClient().on(
            { scope: "*", event: "composer.send" }, event => events.push(event),
          );
          try {
            rendered.length = 0;
            flushTapSync(() => handle.getClient().threads.setText("typed"));
            const typingRenders = rendered.length;
            rendered.length = 0;
            const message = handle.getClient().threads.message(42);
            flushTapSync(() => message.setText("updated"));
            message.send();
            await new Promise(resolve => setImmediate(resolve));
            console.log(JSON.stringify({
              typingRenders,
              childRenders: rendered.length,
              childId: rendered[0],
              text: handle.getClient().threads.getState().text,
              count: handle.getClient().threads.getState().messages.length,
              childText: message.getState().text,
              events,
            }));
          } finally {
            offEvent();
            unsubscribe();
            handle.destroy();
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
        name: "production-context-transform",
        setup(builder) {
          builder.onLoad({ filter: /\/@assistant-ui\/store\/dist\/useAui\.js$/ }, ({ path }) => {
            const source = readFileSync(path, "utf8");
            const transformed = stabilizeAssistantStoreContext(source, path);
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
    expect(JSON.parse(output)).toEqual({
      typingRenders: 0,
      childRenders: 1,
      childId: 42,
      text: "typed",
      count: 240,
      childText: "updated",
      events: [{ threadId: "history", messageId: 42 }],
    });
  });
});
