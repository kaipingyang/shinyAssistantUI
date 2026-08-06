// @vitest-environment jsdom
// CONTRACT PROOF (Plan 48A — quote): verify against installed @assistant-ui/react 0.15.1
// that with our ExternalStoreRuntime, setting a quote on the composer and sending makes the
// quote arrive on the onNew AppendMessage at `metadata.custom.quote` ({text, messageId}).
// If this holds, the R side can read msg$quote and prepend it as a blockquote (like the
// upstream `injectQuoteContext`). This is the make-or-break for the R data flow.
import { describe, it, expect } from "vitest";
import { render, screen, act } from "@testing-library/react";
import * as React from "react";
import {
  AssistantRuntimeProvider,
  useExternalStoreRuntime,
  ThreadPrimitive,
  useAui,
  type ThreadMessageLike,
} from "@assistant-ui/react";

// jsdom polyfills (viewport uses these; not API concerns)
globalThis.ResizeObserver ??= class { observe() {} unobserve() {} disconnect() {} } as any;
globalThis.IntersectionObserver ??= class { observe() {} unobserve() {} disconnect() {} takeRecords() { return []; } } as any;
if (!(Element.prototype as any).scrollTo) (Element.prototype as any).scrollTo = () => {};

const Driver: React.FC = () => {
  const aui = useAui();
  return (
    <button
      data-testid="do"
      onClick={() => {
        const c = aui.thread.composer();
        (c as any).setQuote({ text: "QUOTED_BIT", messageId: "m1" });
        c.setText("my follow-up question");
        c.send();
      }}
    >
      go
    </button>
  );
};

describe("quote contract (installed @assistant-ui/react 0.15.1, ExternalStoreRuntime)", () => {
  it("onNew AppendMessage carries metadata.custom.quote after setQuote + send", async () => {
    let received: any = null;
    function Harness() {
      const runtime = useExternalStoreRuntime({
        messages: [
          {
            id: "m1",
            role: "assistant",
            status: { type: "complete", reason: "stop" } as any,
            content: [{ type: "text", text: "a long assistant answer" } as any],
          },
        ] as ThreadMessageLike[],
        isRunning: false,
        convertMessage: (m: any) => m,
        onNew: async (msg: any) => {
          received = msg;
        },
      });
      return (
        <AssistantRuntimeProvider runtime={runtime}>
          <ThreadPrimitive.Root>
            <Driver />
          </ThreadPrimitive.Root>
        </AssistantRuntimeProvider>
      );
    }
    render(<Harness />);
    await act(async () => {
      screen.getByTestId("do").click();
      await new Promise((r) => setTimeout(r, 0));
    });

    expect(received).not.toBeNull();
    // The core contract: quote rides in metadata.custom.quote
    expect(received?.metadata?.custom?.quote).toEqual({
      text: "QUOTED_BIT",
      messageId: "m1",
    });
    // And the typed text is still the message body
    const text = (received?.content ?? [])
      .filter((p: any) => p.type === "text")
      .map((p: any) => p.text)
      .join("");
    expect(text).toContain("my follow-up question");
  });
});
