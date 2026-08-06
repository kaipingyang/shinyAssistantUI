// @vitest-environment jsdom
// CONTRACT PROOF (Plan 48B — dynamic follow-up suggestions), verified against installed
// @assistant-ui/react 0.15.1. The upstream ThreadFollowupSuggestions reads
// `s.thread.suggestions` directly via useAuiState + AuiIf(!isEmpty && !isRunning &&
// suggestions.length>0) and renders ThreadPrimitive.Suggestion (singular, method="replace"
// autoSend) — NOT ThreadPrimitive.Suggestions (which is welcome/empty-gated). This test
// pins that contract in OUR ExternalStoreRuntime (suggestions field + isRunning flag).
import { describe, it, expect, afterEach } from "vitest";
import { render, screen, cleanup } from "@testing-library/react";
import * as React from "react";
import {
  AssistantRuntimeProvider,
  useExternalStoreRuntime,
  ThreadPrimitive,
  AuiIf,
  useAuiState,
  type ThreadMessageLike,
} from "@assistant-ui/react";

globalThis.ResizeObserver ??= class { observe() {} unobserve() {} disconnect() {} } as any;
globalThis.IntersectionObserver ??= class { observe() {} unobserve() {} disconnect() {} takeRecords() { return []; } } as any;
if (!(Element.prototype as any).scrollTo) (Element.prototype as any).scrollTo = () => {};
afterEach(() => cleanup());

// Mirror of the upstream registry ThreadFollowupSuggestions (the pattern we will vendor).
const FollowupSuggestions: React.FC = () => {
  const suggestions = useAuiState((s: any) => s.thread.suggestions);
  return (
    <AuiIf
      condition={(s: any) => !s.thread.isEmpty && !s.thread.isRunning && s.thread.suggestions.length > 0}
    >
      <div data-testid="followup">
        {suggestions.map((sg: any, i: number) => (
          <ThreadPrimitive.Suggestion key={i} prompt={sg.prompt} method="replace" autoSend>
            {sg.prompt}
          </ThreadPrimitive.Suggestion>
        ))}
      </div>
    </AuiIf>
  );
};

function Harness({
  messages,
  suggestions,
  isRunning = false,
}: {
  messages: ThreadMessageLike[];
  suggestions: Array<{ prompt: string; text?: string }>;
  isRunning?: boolean;
}) {
  const runtime = useExternalStoreRuntime({
    messages,
    isRunning,
    convertMessage: (m: any) => m,
    onNew: async () => {},
    suggestions,
  } as any);
  return (
    <AssistantRuntimeProvider runtime={runtime}>
      <ThreadPrimitive.Root>
        <FollowupSuggestions />
      </ThreadPrimitive.Root>
    </AssistantRuntimeProvider>
  );
}

const A: ThreadMessageLike = { id: "u1", role: "user", content: [{ type: "text", text: "hi" } as any] };
const B: ThreadMessageLike = { id: "a1", role: "assistant", status: { type: "complete", reason: "stop" } as any, content: [{ type: "text", text: "answer" } as any] };

describe("dynamic follow-up suggestions (installed @assistant-ui/react 0.15.1)", () => {
  it("renders chips when thread is non-empty, not running, and has suggestions", () => {
    render(<Harness messages={[A, B]} suggestions={[{ prompt: "NEXT_STEP_A" }, { prompt: "NEXT_STEP_B" }]} />);
    expect(screen.getByText("NEXT_STEP_A")).not.toBeNull();
    expect(screen.getByText("NEXT_STEP_B")).not.toBeNull();
  });

  it("renders nothing on an empty thread (welcome uses a different path)", () => {
    render(<Harness messages={[]} suggestions={[{ prompt: "NEXT_STEP_A" }]} />);
    expect(screen.queryByTestId("followup")).toBeNull();
  });

  it("renders nothing while running", () => {
    render(<Harness messages={[A, B]} suggestions={[{ prompt: "NEXT_STEP_A" }]} isRunning />);
    expect(screen.queryByTestId("followup")).toBeNull();
  });
});
