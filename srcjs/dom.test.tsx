// @vitest-environment jsdom
import { describe, it, expect, vi, afterEach } from "vitest";
import React from "react";
import { render, screen, cleanup } from "@testing-library/react";
import { createRemovalWatcher } from "./helpers";
import { ErrorBoundary } from "./error-boundary";

// 每个测试后卸载渲染的组件，避免 DOM 残留污染后续断言
afterEach(() => cleanup());

describe("createRemovalWatcher", () => {
  it("el 从父节点移除时触发 onRemove", async () => {
    const parent = document.createElement("div");
    const el = document.createElement("div");
    parent.appendChild(el);
    document.body.appendChild(parent);

    const onRemove = vi.fn();
    createRemovalWatcher(el, onRemove);

    parent.removeChild(el); // 移除 el
    // MutationObserver 异步，等微任务
    await new Promise((r) => setTimeout(r, 0));
    expect(onRemove).toHaveBeenCalled();
    document.body.removeChild(parent);
  });

  it("el 仍在 DOM 时不触发", async () => {
    const parent = document.createElement("div");
    const el = document.createElement("div");
    const sibling = document.createElement("span");
    parent.appendChild(el);
    document.body.appendChild(parent);

    const onRemove = vi.fn();
    createRemovalWatcher(el, onRemove);

    parent.appendChild(sibling); // 父节点 childList 变化，但 el 还在
    await new Promise((r) => setTimeout(r, 0));
    expect(onRemove).not.toHaveBeenCalled();
    document.body.removeChild(parent);
  });

  it("无父节点返回 no-op disconnect 不崩", () => {
    const el = document.createElement("div");
    const disconnect = createRemovalWatcher(el, () => {});
    expect(() => disconnect()).not.toThrow();
  });

  it("disconnect 后移除 el 不再触发", async () => {
    const parent = document.createElement("div");
    const el = document.createElement("div");
    parent.appendChild(el);
    document.body.appendChild(parent);

    const onRemove = vi.fn();
    const disconnect = createRemovalWatcher(el, onRemove);
    disconnect();

    parent.removeChild(el);
    await new Promise((r) => setTimeout(r, 0));
    expect(onRemove).not.toHaveBeenCalled();
    document.body.removeChild(parent);
  });
});

// 故意抛错的子组件
function Boom({ crash }: { crash: boolean }) {
  if (crash) throw new Error("boom");
  return <div>ok content</div>;
}

describe("ErrorBoundary", () => {
  it("子组件正常时渲染 children", () => {
    render(
      <ErrorBoundary resetKey={1}>
        <Boom crash={false} />
      </ErrorBoundary>
    );
    expect(screen.getByText("ok content")).toBeTruthy();
  });

  it("子组件抛错时显示降级 UI", () => {
    // 抑制 React 错误日志噪音
    const spy = vi.spyOn(console, "error").mockImplementation(() => {});
    render(
      <ErrorBoundary resetKey={1}>
        <Boom crash={true} />
      </ErrorBoundary>
    );
    expect(screen.getByText("AssistantUI Error:")).toBeTruthy();
    spy.mockRestore();
  });

  it("resetKey 变化后从错误态恢复，渲染新 children", () => {
    const spy = vi.spyOn(console, "error").mockImplementation(() => {});
    const { rerender } = render(
      <ErrorBoundary resetKey={1}>
        <Boom crash={true} />
      </ErrorBoundary>
    );
    expect(screen.getByText("AssistantUI Error:")).toBeTruthy();

    // resetKey 变 + children 不再抛错 → 应恢复
    rerender(
      <ErrorBoundary resetKey={2}>
        <Boom crash={false} />
      </ErrorBoundary>
    );
    expect(screen.getByText("ok content")).toBeTruthy();
    expect(screen.queryByText("AssistantUI Error:")).toBeNull();
    spy.mockRestore();
  });

  it("resetKey 不变则保持错误态（不误恢复）", () => {
    const spy = vi.spyOn(console, "error").mockImplementation(() => {});
    const { rerender } = render(
      <ErrorBoundary resetKey={1}>
        <Boom crash={true} />
      </ErrorBoundary>
    );
    rerender(
      <ErrorBoundary resetKey={1}>
        <Boom crash={false} />
      </ErrorBoundary>
    );
    // resetKey 没变，仍显示错误
    expect(screen.getByText("AssistantUI Error:")).toBeTruthy();
    spy.mockRestore();
  });
});
