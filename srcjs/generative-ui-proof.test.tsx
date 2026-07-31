// @vitest-environment jsdom
// FOUNDATION PROOF (kept as regression): verified against installed @assistant-ui/react 0.15.1
// that the two R-driven *display* mechanisms actually render, via EXPLICIT component slots on
// MessagePrimitive.Parts (no scope registration, no makeAssistantDataUI):
//   • data part      — R pushes {type:"data-<name>", data} → auto-converts to {type:"data", name, data}
//                       → rendered by components.data.by_name[name]
//   • generative-ui   — R pushes {type:"generative-ui", spec:{root:{component,props,children}}}
//                       → rendered by components.generativeUI.components allowlist
// NOTE (learned by testing): makeAssistantDataUI + part.dataRendererUI did NOT render by mere mount
// (needs the dataRenderers scope). The reliable path is the explicit by_name slot below. A message
// MUST carry an `id` or it never enters the thread.
import { describe, it, expect } from "vitest";
import { render, screen } from "@testing-library/react";
import * as React from "react";
import {
  AssistantRuntimeProvider,
  useExternalStoreRuntime,
  ThreadPrimitive,
  MessagePrimitive,
  type ThreadMessageLike,
} from "@assistant-ui/react";

// jsdom polyfills (viewport uses these; not API concerns)
globalThis.ResizeObserver ??= class { observe() {} unobserve() {} disconnect() {} } as any;
globalThis.IntersectionObserver ??= class { observe() {} unobserve() {} disconnect() {} takeRecords() { return []; } } as any;
if (!(Element.prototype as any).scrollTo) (Element.prototype as any).scrollTo = () => {};

const ChartData = ({ data }: any) => <div data-testid="chart">{data.title}</div>;

const allowlist = {
  Box: ({ children }: { children?: React.ReactNode }) => <div data-testid="box">{children}</div>,
  Txt: ({ text }: { text?: string }) => <span data-testid="txt">{text}</span>,
};
const Fallback = ({ component }: { component: string }) => (
  <span data-testid="fallback">unknown:{component}</span>
);

function Harness({ messages }: { messages: ThreadMessageLike[] }) {
  const runtime = useExternalStoreRuntime({
    messages,
    isRunning: false,
    convertMessage: (m: any) => m,
    onNew: async () => {},
  });
  return (
    <AssistantRuntimeProvider runtime={runtime}>
      <ThreadPrimitive.Root>
        <ThreadPrimitive.Viewport>
          <ThreadPrimitive.Messages>
            {() => (
              <MessagePrimitive.Root>
                <MessagePrimitive.Parts
                  components={{
                    data: { by_name: { chart: ChartData as any } } as any,
                    generativeUI: { components: allowlist as any, Fallback } as any,
                  } as any}
                />
              </MessagePrimitive.Root>
            )}
          </ThreadPrimitive.Messages>
        </ThreadPrimitive.Viewport>
      </ThreadPrimitive.Root>
    </AssistantRuntimeProvider>
  );
}

describe("generative-ui display foundation (installed @assistant-ui/react 0.15.1)", () => {
  it("renders data-* part (by_name slot) and generative-ui spec (allowlist)", () => {
    const messages: ThreadMessageLike[] = [
      {
        id: "m1",
        role: "assistant",
        status: { type: "complete", reason: "stop" } as any,
        content: [
          { type: "text", text: "BASELINE_TEXT" } as any,
          { type: "data-chart", data: { title: "HELLO_DATA" } } as any,
          {
            type: "generative-ui",
            spec: { root: { component: "Box", children: [{ component: "Txt", props: { text: "HELLO_GUI" } }] } },
          } as any,
        ],
      },
    ];
    render(<Harness messages={messages} />);
    expect(screen.getByTestId("chart").textContent).toBe("HELLO_DATA");
    expect(screen.getByTestId("box")).not.toBeNull();
    expect(screen.getByTestId("txt").textContent).toBe("HELLO_GUI");
  });

  it("unknown generative-ui component name falls back (allowlist is the security boundary)", () => {
    const messages: ThreadMessageLike[] = [
      {
        id: "m2",
        role: "assistant",
        status: { type: "complete", reason: "stop" } as any,
        content: [
          { type: "generative-ui", spec: { root: { component: "NotAllowed", props: {} } } } as any,
        ],
      },
    ];
    render(<Harness messages={messages} />);
    expect(screen.getByTestId("fallback").textContent).toContain("NotAllowed");
  });

  // Production thread.tsx uses MessagePrimitive.GroupedParts (render-prop), NOT the Parts
  // `data.by_name` slot above. This asserts the *production path*: in the render-prop, a data
  // part exposes `part.name` + `part.data`, so `case "data"` can look them up in our own map.
  it("GroupedParts render-prop: data part exposes part.name/part.data for our own lookup", () => {
    const byName: Record<string, React.FC<{ data: any }>> = {
      chart: ({ data }) => <div data-testid="gp-chart">{data.title}</div>,
    };
    function GPHarness() {
      const runtime = useExternalStoreRuntime({
        messages: [
          {
            id: "gp1",
            role: "assistant",
            status: { type: "complete", reason: "stop" } as any,
            content: [{ type: "data-chart", data: { title: "GP_DATA" } } as any],
          },
        ],
        isRunning: false,
        convertMessage: (m: any) => m,
        onNew: async () => {},
      });
      return (
        <AssistantRuntimeProvider runtime={runtime}>
          <ThreadPrimitive.Root>
            <ThreadPrimitive.Viewport>
              <ThreadPrimitive.Messages>
                {() => (
                  <MessagePrimitive.Root>
                    <MessagePrimitive.GroupedParts groupBy={() => []}>
                      {({ part }: any) => {
                        if (part.type !== "data") return null;
                        const C = byName[part.name];
                        return C ? <C data={part.data} /> : <span data-testid="gp-nomatch">no:{String(part.name)}</span>;
                      }}
                    </MessagePrimitive.GroupedParts>
                  </MessagePrimitive.Root>
                )}
              </ThreadPrimitive.Messages>
            </ThreadPrimitive.Viewport>
          </ThreadPrimitive.Root>
        </AssistantRuntimeProvider>
      );
    }
    render(<GPHarness />);
    expect(screen.getByTestId("gp-chart").textContent).toBe("GP_DATA");
  });
});
