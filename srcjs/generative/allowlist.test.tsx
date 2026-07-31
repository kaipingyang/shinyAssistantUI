// @vitest-environment jsdom
// Plan 47 A1 — shinyAllowlist rendered via MessagePrimitive.GenerativeUI in the production
// GroupedParts render-prop path (mirrors generative-ui-proof.test.tsx).
import { describe, it, expect } from "vitest";
import { render } from "@testing-library/react";
import {
  AssistantRuntimeProvider,
  useExternalStoreRuntime,
  ThreadPrimitive,
  MessagePrimitive,
  type ThreadMessageLike,
} from "@assistant-ui/react";
import { shinyAllowlist, GenerativeUiFallback } from "@/generative/allowlist";

globalThis.ResizeObserver ??= class { observe() {} unobserve() {} disconnect() {} } as any;
globalThis.IntersectionObserver ??= class { observe() {} unobserve() {} disconnect() {} takeRecords() { return []; } } as any;
if (!(Element.prototype as any).scrollTo) (Element.prototype as any).scrollTo = () => {};

function Harness({ content }: { content: any[] }) {
  const runtime = useExternalStoreRuntime({
    messages: [{ id: "m1", role: "assistant", status: { type: "complete", reason: "stop" } as any, content }],
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
                  {({ part }: any) =>
                    part.type === "generative-ui" ? (
                      <MessagePrimitive.GenerativeUI components={shinyAllowlist as any} Fallback={GenerativeUiFallback} />
                    ) : null
                  }
                </MessagePrimitive.GroupedParts>
              </MessagePrimitive.Root>
            )}
          </ThreadPrimitive.Messages>
        </ThreadPrimitive.Viewport>
      </ThreadPrimitive.Root>
    </AssistantRuntimeProvider>
  );
}

describe("Plan 47 A1 — shinyAllowlist via MessagePrimitive.GenerativeUI", () => {
  it("renders a composed Card>Stack>[Heading,Stat] layout", () => {
    const { container } = render(
      <Harness
        content={[
          {
            type: "generative-ui",
            spec: {
              root: {
                component: "Card",
                props: { title: "Summary" },
                children: [
                  { component: "Stack", children: [
                    { component: "Heading", props: { level: 3 }, children: ["Model fit"] },
                    { component: "Stat", props: { label: "R²", value: "0.87" } },
                  ] },
                ],
              },
            },
          },
        ]}
      />,
    );
    expect(container.querySelector('[data-slot="gui-card"]')).not.toBeNull();
    expect(container.querySelector('[data-slot="gui-stack"]')).not.toBeNull();
    expect(container.querySelector('[data-slot="gui-heading"]')?.textContent).toContain("Model fit");
    const stat = container.querySelector('[data-slot="gui-stat"]')!;
    expect(stat.textContent).toContain("R²");
    expect(stat.textContent).toContain("0.87");
  });

  it("unknown component name falls back (allowlist boundary)", () => {
    const { container } = render(
      <Harness content={[{ type: "generative-ui", spec: { root: { component: "Danger", props: {} } } }]} />,
    );
    expect(container.querySelector('[data-slot="gui-unknown"]')?.textContent).toContain("Danger");
  });
});
