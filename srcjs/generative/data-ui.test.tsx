// @vitest-environment jsdom
// Plan 47 A0 — Data UI: R pushes {type:"data-<name>", data} → GroupedParts case "data"
// → renderDataPart(part) looks up DATA_UI_BY_NAME[part.name] and renders our own component.
// Mirrors the verified production path (thread.tsx uses MessagePrimitive.GroupedParts render-prop).
import { describe, it, expect } from "vitest";
import { render } from "@testing-library/react";
import * as React from "react";
import {
  AssistantRuntimeProvider,
  useExternalStoreRuntime,
  ThreadPrimitive,
  MessagePrimitive,
  type ThreadMessageLike,
} from "@assistant-ui/react";
import { renderDataPart, DATA_UI_BY_NAME } from "@/generative/data-ui";

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
                  {({ part }: any) => (part.type === "data" ? renderDataPart(part) : null)}
                </MessagePrimitive.GroupedParts>
              </MessagePrimitive.Root>
            )}
          </ThreadPrimitive.Messages>
        </ThreadPrimitive.Viewport>
      </ThreadPrimitive.Root>
    </AssistantRuntimeProvider>
  );
}

describe("Plan 47 A0 — DATA_UI_BY_NAME + renderDataPart (production GroupedParts path)", () => {
  it("registry has table/stat/flow/action-progress", () => {
    expect(Object.keys(DATA_UI_BY_NAME).sort()).toEqual(["action-progress", "flow", "stat", "table"]);
  });

  it("data-table renders a table from row objects", () => {
    const { container } = render(<Harness content={[{ type: "data-table", data: { rows: [{ var: "age", est: 1.2 }, { var: "bmi", est: 3.4 }] } }]} />);
    const t = container.querySelector('[data-slot="data-table"]')!;
    expect(t).not.toBeNull();
    expect(t.textContent).toContain("age");
    expect(t.textContent).toContain("1.2");
    expect(t.textContent).toContain("bmi");
  });

  it("data-stat renders label/value", () => {
    const { container } = render(<Harness content={[{ type: "data-stat", data: { label: "R²", value: "0.87" } }]} />);
    const s = container.querySelector('[data-slot="data-stat"]')!;
    expect(s).not.toBeNull();
    expect(s.textContent).toContain("R²");
    expect(s.textContent).toContain("0.87");
  });

  it("data-flow revives FlowCanvas with nodes (data-flow-id present)", () => {
    const { container } = render(<Harness content={[{ type: "data-flow", data: { nodes: [{ id: "a", label: "Load" }, { id: "b", label: "Model" }], edges: [{ from: "a", to: "b" }] } }]} />);
    expect(container.querySelector('[data-slot="data-flow"]')).not.toBeNull();
    expect(container.querySelector('[data-flow-id="a"]')?.textContent).toBe("Load");
    expect(container.querySelector('[data-flow-id="b"]')?.textContent).toBe("Model");
  });

  it("unknown data name renders nothing (no crash)", () => {
    const { container } = render(<Harness content={[{ type: "data-nope", data: {} }]} />);
    expect(container.querySelector('[data-testid^="data-"]')).toBeNull();
  });
});


describe("compact action progress data UI", () => {
  it("renders an honest indeterminate compacting phase with elapsed time and no percentage", () => {
    const { container } = render(<Harness content={[{
      type: "data-action-progress",
      data: { kind: "compact", phase: "compacting", startedAt: Date.now() - 4_000 },
    }]} />);
    const progress = container.querySelector('[data-slot="action-progress"]')!;
    expect(progress).not.toBeNull();
    expect(progress.getAttribute("data-action-kind")).toBe("compact");
    expect(progress.getAttribute("data-action-state")).toBe("running");
    expect(progress.querySelector('[data-indeterminate="true"]')).not.toBeNull();
    expect(progress.textContent).toMatch(/Compacting/i);
    expect(progress.textContent).toMatch(/4s/);
    expect(progress.textContent).not.toMatch(/\d+%/);
  });

  it.each(["complete", "error"])("renders %s as a non-animating terminal state", (phase) => {
    const { container } = render(<Harness content={[{
      type: "data-action-progress",
      data: { kind: "compact", phase, startedAt: Date.now() - 1_000, message: phase },
    }]} />);
    const progress = container.querySelector('[data-slot="action-progress"]')!;
    expect(progress.getAttribute("data-action-state")).toBe(phase === "complete" ? "complete" : "error");
    expect(progress.querySelector('[data-indeterminate="true"]')).toBeNull();
  });

  it("settles stale restored running progress instead of animating forever", () => {
    const { container } = render(<Harness content={[{
      type: "data-action-progress",
      data: { kind: "compact", phase: "compacting", startedAt: Date.now() - 186_000 },
    }]} />);
    const progress = container.querySelector('[data-slot="action-progress"]')!;
    expect(progress.getAttribute("data-action-state")).toBe("interrupted");
    expect(progress.querySelector('[data-indeterminate="true"]')).toBeNull();
  });


  it("treats missing or unknown restored phases as interrupted", () => {
    const { container } = render(<Harness content={[{
      type: "data-action-progress",
      data: { kind: "compact", phase: "future-phase", startedAt: Date.now() },
    }]} />);
    const progress = container.querySelector('[data-slot="action-progress"]')!;
    expect(progress.getAttribute("data-action-state")).toBe("interrupted");
    expect(progress.querySelector('[data-indeterminate="true"]')).toBeNull();
  });
});
