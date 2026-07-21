// @vitest-environment jsdom
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import { act, cleanup, fireEvent, render, waitFor } from "@testing-library/react";
import { AssistantRuntimeProvider, useLocalRuntime } from "@assistant-ui/react";
import { ShinyCurrentQuestion } from "./current-question";

const noOpAdapter = {
  async run() {
    return { content: [{ type: "text" as const, text: "ok" }] };
  },
};

beforeAll(() => {
  Element.prototype.scrollIntoView ??= vi.fn();
  globalThis.ResizeObserver ??= class {
    observe() {}
    unobserve() {}
    disconnect() {}
  } as never;
});

afterEach(() => cleanup());

function Harness({ visible, send }: { visible: boolean; send?: string }) {
  const runtime = useLocalRuntime(noOpAdapter);
  if (send && !(runtime as unknown as { __seeded?: boolean }).__seeded) {
    (runtime as unknown as { __seeded?: boolean }).__seeded = true;
  }
  return (
    <div data-testid="host">
      <AssistantRuntimeProvider runtime={runtime}>
        <Seed text={send} />
        <ShinyCurrentQuestion visible={visible} />
      </AssistantRuntimeProvider>
    </div>
  );
}

// 通过 composer 发一条 user 消息（noOp adapter 立即完成），使 thread.messages 有 user 轮次
import { useAui } from "@assistant-ui/react";
import { useEffect, useRef } from "react";
function Seed({ text }: { text?: string }) {
  const aui = useAui();
  const done = useRef(false);
  useEffect(() => {
    if (!text || done.current) return;
    done.current = true;
    void (async () => {
      await aui.composer().setText(text);
      await aui.composer().send();
    })();
  }, [aui, text]);
  return null;
}

describe("ShinyCurrentQuestion", () => {
  const longQ = "请帮我创建一个临时 R 文件并写入测试代码然后执行它看看输出对不对再顺便解释每一行";

  it("shows the latest user question when visible, truncated, and expands on toggle", async () => {
    const { getByTestId, queryByTestId } = render(<Harness visible send={longQ} />);
    const bar = await waitFor(() => {
      const el = getByTestId("host").querySelector<HTMLElement>("[data-slot=aui_current_question]");
      expect(el).not.toBeNull();
      return el!;
    });
    expect(bar.textContent).toContain("请帮我创建一个临时 R 文件");
    expect(bar.getAttribute("data-expanded")).toBe("false");

    const toggle = bar.querySelector<HTMLElement>("[data-slot=aui_current_question_toggle]");
    expect(toggle).not.toBeNull();
    await act(async () => { fireEvent.click(toggle!); });
    expect(bar.getAttribute("data-expanded")).toBe("true");
    expect(queryByTestId("host")).not.toBeNull();
  });

  it("renders nothing when not visible", async () => {
    const { getByTestId } = render(<Harness visible={false} send={longQ} />);
    await new Promise((r) => setTimeout(r, 50));
    expect(getByTestId("host").querySelector("[data-slot=aui_current_question]")).toBeNull();
  });

  it("renders nothing when there is no user message", async () => {
    const { getByTestId } = render(<Harness visible />);
    await new Promise((r) => setTimeout(r, 50));
    expect(getByTestId("host").querySelector("[data-slot=aui_current_question]")).toBeNull();
  });
});
