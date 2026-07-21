// @vitest-environment jsdom
import { afterEach, describe, expect, it } from "vitest";
import { cleanup, fireEvent, render } from "@testing-library/react";
import { ThreadSidebar, SidebarToggleButton, useSidebarCollapse } from "./thread-sidebar";

// 复刻 AssistantUI 的布局：展开时渲染侧栏（含收起按钮），折叠时侧栏消失、
// 展开按钮改渲染在主面板里（不留残留窄轨）。
function Harness({ storageKey }: { storageKey?: string }) {
  const sidebar = useSidebarCollapse(storageKey);
  return (
    <div>
      <ThreadSidebar collapsed={sidebar.collapsed} onToggle={sidebar.toggle}>
        <div data-testid="sidebar-child">thread list</div>
      </ThreadSidebar>
      <div data-testid="main-panel">
        {sidebar.collapsed && (
          <SidebarToggleButton
            collapsed
            onToggle={sidebar.toggle}
            data-testid="main-expand"
          />
        )}
        main
      </div>
    </div>
  );
}

afterEach(() => {
  cleanup();
  try { localStorage.clear(); } catch { /* noop */ }
});

describe("ThreadSidebar collapse", () => {
  it("removes the sidebar entirely when collapsed and moves the toggle into the main panel", () => {
    const { container, getByLabelText, getByTestId, queryByTestId } = render(<Harness />);

    const sidebar = container.querySelector<HTMLElement>("[data-slot=aui_thread_sidebar]");
    expect(sidebar).not.toBeNull();
    expect(queryByTestId("sidebar-child")).not.toBeNull();
    // 展开态：主面板里没有展开按钮
    expect(getByTestId("main-panel").querySelector("[data-testid=main-expand]")).toBeNull();

    fireEvent.click(getByLabelText("Collapse sidebar"));

    // 折叠态：侧栏元素完全消失（无残留窄轨），children 也没了
    expect(container.querySelector("[data-slot=aui_thread_sidebar]")).toBeNull();
    expect(queryByTestId("sidebar-child")).toBeNull();
    // 展开按钮出现在主面板中
    const expandBtn = getByTestId("main-panel").querySelector<HTMLElement>("[data-testid=main-expand]");
    expect(expandBtn).not.toBeNull();
    expect(expandBtn!.getAttribute("aria-label")).toBe("Expand sidebar");

    fireEvent.click(getByLabelText("Expand sidebar"));
    expect(container.querySelector("[data-slot=aui_thread_sidebar]")).not.toBeNull();
    expect(queryByTestId("sidebar-child")).not.toBeNull();
  });

  it("persists collapsed state to localStorage when a storageKey is given", () => {
    const { getByLabelText } = render(<Harness storageKey="aui:test:sidebar" />);
    fireEvent.click(getByLabelText("Collapse sidebar"));
    expect(localStorage.getItem("aui:test:sidebar")).toBe("1");

    cleanup();
    const { container, queryByTestId } = render(<Harness storageKey="aui:test:sidebar" />);
    // 重新挂载读取持久化折叠态：侧栏不渲染
    expect(container.querySelector("[data-slot=aui_thread_sidebar]")).toBeNull();
    expect(queryByTestId("sidebar-child")).toBeNull();
  });

  it("does not touch localStorage without a storageKey", () => {
    const { getByLabelText } = render(<Harness />);
    fireEvent.click(getByLabelText("Collapse sidebar"));
    expect(localStorage.length).toBe(0);
  });
});
