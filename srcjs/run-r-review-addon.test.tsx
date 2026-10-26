/** @vitest-environment jsdom */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import { ShinyConfigContext, type ShinyConfigCtx } from "@/shiny-config-context";
import {
  createRunRReviewBridge,
  parseRunRReviewAddon,
  parseServerReview,
  RUN_R_REVIEW_MAX_TEXT,
  type RunRReviewBridge,
} from "./run-r-review-addon";
import { RunROutputReviewPanel, RunROutputReviewToggle } from "./components/assistant-ui/run-r-review-panel";

type Handler = (data: unknown) => void;
const handlers = new Map<string, Handler>();
const inputs: { id: string; value: Record<string, unknown> }[] = [];
let counter = 0;
let inputId = "";

beforeEach(() => {
  counter += 1;
  inputId = `review${counter}`;
  inputs.length = 0;
  (globalThis as unknown as { Shiny: unknown }).Shiny = {
    setInputValue: (id: string, value: Record<string, unknown>) => inputs.push({ id, value }),
    addCustomMessageHandler: (type: string, handler: Handler) => handlers.set(type, handler),
  };
});
afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

const review = (id = "rr-1", threadId = "t1", text = "[1] 1\n[1] 2") => ({
  id, threadId, code: "print(1)", text, isError: false, expiresAt: 1_000,
});
const push = (data: unknown) => act(() => handlers.get(`${inputId}:run-r-review`)?.(data));
const allInputs = () => inputs.filter((item) => item.id === `${inputId}_run_r_review`).map((item) => {
  const { nonce: _nonce, ...rest } = item.value;
  return rest;
});
const decisions = () => allInputs().filter((item) => item.type !== "sync");

function renderPanel(bridge: RunRReviewBridge, currentThreadId = "t1") {
  return render(
    <ShinyConfigContext.Provider value={{ runROutputReview: bridge, currentThreadId } as unknown as ShinyConfigCtx}>
      <RunROutputReviewPanel />
      <RunROutputReviewToggle />
    </ShinyConfigContext.Provider>,
  );
}

describe("run_r review addon parsing", () => {
  it("accepts only the exact addon config", () => {
    expect(parseRunRReviewAddon({ addons: { runROutputReview: { version: 1, enabled: true } } }))
      .toEqual({ version: 1, enabled: true });
    expect(parseRunRReviewAddon({ addons: { runROutputReview: { version: 2, enabled: true } } })).toBeUndefined();
    expect(parseRunRReviewAddon({ addons: { runROutputReview: { version: 1, enabled: "yes" } } })).toBeUndefined();
    expect(parseRunRReviewAddon({ addons: { runROutputReview: { version: 1, enabled: true, x: 1 } } })).toBeUndefined();
    expect(parseRunRReviewAddon({})).toBeUndefined();
  });

  it("rejects malformed reviews", () => {
    expect(parseServerReview(review())).toMatchObject({ id: "rr-1", source: "server" });
    expect(parseServerReview({ ...review(), text: 1 })).toBeUndefined();
    expect(parseServerReview({ ...review(), id: "" })).toBeUndefined();
    expect(parseServerReview({ ...review(), extra: true })).toBeUndefined();
  });
});

describe("RunROutputReviewPanel", () => {
  it("asks the server to resend pending reviews once its handler exists", () => {
    createRunRReviewBridge(inputId, { version: 1, enabled: true });
    expect(allInputs()).toEqual([{ type: "sync" }]);
  });
  it("sends the original output unchanged", () => {
    const bridge = createRunRReviewBridge(inputId, { version: 1, enabled: true });
    renderPanel(bridge);
    push({ type: "show", review: review() });
    const textarea = screen.getByRole("textbox", { name: "Output" }) as HTMLTextAreaElement;
    expect(textarea.value).toBe("[1] 1\n[1] 2");
    fireEvent.click(screen.getByRole("button", { name: "Send output" }));
    expect(decisions()).toEqual([{ type: "decide", id: "rr-1", decision: "approve" }]);
    // The card stays (locked) until the backend confirms the decision.
    expect(screen.getByRole("status").textContent).toMatch(/Sending decision/);
    expect((screen.getByRole("button", { name: "Send output" }) as HTMLButtonElement).disabled).toBe(true);
    fireEvent.click(screen.getByRole("button", { name: "Send output" }));
    expect(decisions()).toHaveLength(1);
    push({ type: "dismiss", id: "rr-1", outcome: "approve" });
    expect(document.querySelector("[data-run-r-review]")).toBeNull();
  });

  it("keeps the card usable when the decision cannot be sent", () => {
    const bridge = createRunRReviewBridge(inputId, { version: 1, enabled: true });
    renderPanel(bridge);
    push({ type: "show", review: review() });
    (globalThis as unknown as { Shiny: { setInputValue: () => void } }).Shiny.setInputValue = () => {
      throw new Error("disconnected");
    };
    let accepted = true;
    act(() => { accepted = bridge.decide("rr-1", "approve"); });
    expect(accepted).toBe(false);
    expect(bridge.getSnapshot().reviews[0]?.submitting).toBe(false);
    expect((screen.getByRole("button", { name: "Send output" }) as HTMLButtonElement).disabled).toBe(false);
  });

  it("rejects unknown decision values and malformed frames", () => {
    const bridge = createRunRReviewBridge(inputId, { version: 1, enabled: true });
    renderPanel(bridge);
    push({ type: "show", review: review(), extra: 1 });
    expect(document.querySelector("[data-run-r-review]")).toBeNull();
    push({ type: "show", review: review() });
    expect(bridge.decide("rr-1", "maybe" as never)).toBe(false);
    push({ type: "settings", enabled: false, extra: 1 });
    expect(bridge.getSnapshot().enabled).toBe(true);
  });

  it("sends only the edited text after editing, with reset available", () => {
    const bridge = createRunRReviewBridge(inputId, { version: 1, enabled: true });
    renderPanel(bridge);
    push({ type: "show", review: review("rr-2", "t1", "name: Alice") });
    const textarea = screen.getByRole("textbox", { name: "Output" });
    fireEvent.change(textarea, { target: { value: "name: <redacted>" } });
    fireEvent.click(screen.getByRole("button", { name: "Reset" }));
    expect((textarea as HTMLTextAreaElement).value).toBe("name: Alice");
    fireEvent.change(textarea, { target: { value: "name: <redacted>" } });
    fireEvent.click(screen.getByRole("button", { name: "Send edited output" }));
    expect(decisions()).toEqual([
      { type: "decide", id: "rr-2", decision: "edit", text: "name: <redacted>" },
    ]);
  });

  it("declines without sending any text", () => {
    const bridge = createRunRReviewBridge(inputId, { version: 1, enabled: true });
    renderPanel(bridge);
    push({ type: "show", review: review() });
    fireEvent.change(screen.getByRole("textbox", { name: "Output" }), { target: { value: "x" } });
    fireEvent.click(screen.getByRole("button", { name: "Don't send" }));
    expect(decisions()).toEqual([{ type: "decide", id: "rr-1", decision: "reject" }]);
    push({ type: "dismiss", id: "rr-1", outcome: "reject" });
    expect(document.querySelector("[data-run-r-review]")).toBeNull();
  });

  it("blocks overly long edits", () => {
    const bridge = createRunRReviewBridge(inputId, { version: 1, enabled: true });
    renderPanel(bridge);
    push({ type: "show", review: review() });
    fireEvent.change(screen.getByRole("textbox", { name: "Output" }), {
      target: { value: "x".repeat(RUN_R_REVIEW_MAX_TEXT + 1) },
    });
    expect(screen.getByRole("alert").textContent).toMatch(/limited/);
    expect((screen.getByRole("button", { name: "Send edited output" }) as HTMLButtonElement).disabled).toBe(true);
    expect(bridge.decide("rr-1", "edit", "x".repeat(RUN_R_REVIEW_MAX_TEXT + 1))).toBe(false);
  });

  it("removes reviews dismissed by the server and ignores duplicates", () => {
    const bridge = createRunRReviewBridge(inputId, { version: 1, enabled: true });
    renderPanel(bridge);
    push({ type: "show", review: review() });
    push({ type: "show", review: review() });
    expect(document.querySelectorAll("[data-run-r-review]")).toHaveLength(1);
    push({ type: "dismiss", id: "rr-1", outcome: "reject" });
    expect(document.querySelector("[data-run-r-review]")).toBeNull();
    expect(bridge.decide("rr-1", "approve")).toBe(false);
  });

  it("shows the current thread and summarises other threads", () => {
    const bridge = createRunRReviewBridge(inputId, { version: 1, enabled: true });
    renderPanel(bridge, "t1");
    push({ type: "show", review: review("a", "t1") });
    push({ type: "show", review: review("b", "t2") });
    push({ type: "show", review: review("c", "t3") });
    expect(document.querySelectorAll("[data-run-r-review]")).toHaveLength(1);
    expect(screen.getByRole("status").textContent).toMatch(/2 R outputs are waiting/);
  });

  it("toggle reflects and changes the setting", () => {
    const bridge = createRunRReviewBridge(inputId, { version: 1, enabled: true });
    renderPanel(bridge);
    const checkbox = screen.getByRole("checkbox", { name: /Review R output before sending/ }) as HTMLInputElement;
    expect(checkbox.checked).toBe(true);
    fireEvent.click(checkbox);
    expect(checkbox.checked).toBe(false);
    expect(checkbox.disabled).toBe(true);
    // Not effective until the backend confirms: local output is still reviewed.
    expect(bridge.getSnapshot().enabled).toBe(true);
    const delivered: (string | null)[] = [];
    act(() => bridge.reviewLocal({ threadId: "t1", code: "x", text: "out", isError: false },
      (t) => delivered.push(t)));
    expect(delivered).toEqual([]);
    expect(decisions()).toEqual([{ type: "set_enabled", enabled: false }]);
    push({ type: "settings", enabled: true });   // write failed: still on
    expect(checkbox.checked).toBe(true);
    expect(checkbox.disabled).toBe(false);
    fireEvent.click(checkbox);
    push({ type: "settings", enabled: false });
    expect(checkbox.checked).toBe(false);
    expect(bridge.getSnapshot().enabled).toBe(false);
  });
});

describe("local (Run in Console) review", () => {
  it("delivers only after approval, edited text, or nothing on decline", () => {
    const bridge = createRunRReviewBridge(inputId, { version: 1, enabled: true });
    renderPanel(bridge);
    const delivered: (string | null)[] = [];
    act(() => bridge.reviewLocal({ threadId: "t1", code: "x", text: "secret", isError: false },
      (text) => delivered.push(text)));
    expect(delivered).toEqual([]);
    expect(document.querySelector("[data-run-r-review-source='local']")).not.toBeNull();
    fireEvent.change(screen.getByRole("textbox", { name: "Output" }), { target: { value: "safe" } });
    fireEvent.click(screen.getByRole("button", { name: "Send edited output" }));
    act(() => bridge.reviewLocal({ threadId: "t1", code: "x", text: "secret", isError: true },
      (text) => delivered.push(text)));
    fireEvent.click(screen.getByRole("button", { name: "Don't send" }));
    expect(delivered).toEqual(["safe", null]);
    expect(decisions()).toEqual([]);   // local reviews never reach the server
  });

  it("delivers immediately when review is turned off", () => {
    const bridge = createRunRReviewBridge(inputId, { version: 1, enabled: false });
    const delivered: (string | null)[] = [];
    bridge.reviewLocal({ threadId: "t1", code: "x", text: "out", isError: false }, (t) => delivered.push(t));
    expect(delivered).toEqual(["out"]);
  });
});
