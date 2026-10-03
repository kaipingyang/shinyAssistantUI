// @vitest-environment node
import { execFileSync } from "node:child_process";
import { build } from "esbuild";
import { describe, expect, it } from "vitest";

// Store 0.3.15 memoizes the event-context envelope upstream
// (`useMemo(() => ({ clientRef, emit: notifications.emit }), [...])` in
// dist/useAui.js), so no build-time compatibility transform is applied.
// This behavioural gate runs the real production dependency untransformed and
// fails if a future version reintroduces a fresh envelope per update.
describe("assistant store event-context behaviour", () => {
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
