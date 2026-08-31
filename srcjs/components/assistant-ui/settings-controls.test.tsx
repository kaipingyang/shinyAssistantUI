// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { ShinyConfigContext, type ShinyConfigCtx } from "../../shiny-config-context";
import { PermissionModeControl, ThinkingControl, ModelPickerDialog, SidebarSettings } from "./settings-controls";

const baseContext: ShinyConfigCtx = {
  tools: [], commands: [], actionItems: [], showTimestamps: false,
  onEnqueue: () => {}, onRename: () => {}, onInvokeAction: () => {},
};

afterEach(cleanup);

function renderWithContext(
  component: React.ReactNode,
  permissionMode?: ShinyConfigCtx["permissionMode"],
) {
  return render(
    <ShinyConfigContext.Provider value={{ ...baseContext, permissionMode }}>
      {component}
    </ShinyConfigContext.Provider>,
  );
}

describe("PermissionModeControl", () => {
  it("is absent when the backend has no capability", () => {
    renderWithContext(<PermissionModeControl compact />);
    expect(screen.queryByLabelText("Permission mode")).toBeNull();
  });

  it("shows options, pending state, and delegates selection", () => {
    const setValue = vi.fn();
    renderWithContext(<PermissionModeControl compact />, {
      value: "plan",
      options: [
        { value: "default", label: "Manual" },
        { value: "plan", label: "Plan" },
        { value: "acceptEdits", label: "Auto-edit" },
      ],
      pending: false,
      error: null,
      setValue,
    });
    const select = screen.getByLabelText("Permission mode") as HTMLSelectElement;
    expect(select.value).toBe("plan");
    fireEvent.change(select, { target: { value: "acceptEdits" } });
    expect(setValue).toHaveBeenCalledWith("acceptEdits");
  });

  it("exposes bypass as a selectable option", () => {
    const setValue = vi.fn();
    renderWithContext(<PermissionModeControl compact />, {
      value: "default",
      options: [
        { value: "default", label: "Manual" },
        { value: "bypassPermissions", label: "Bypass" },
      ],
      pending: false,
      error: null,
      setValue,
    });
    const option = screen.getByRole("option", { name: "Bypass" });
    expect((option as HTMLOptionElement).disabled).toBe(false);
    fireEvent.change(screen.getByLabelText("Permission mode"), {
      target: { value: "bypassPermissions" },
    });
    expect(setValue).toHaveBeenCalledWith("bypassPermissions");
  });

  it("uses unique label targets when multiple widgets render controls", () => {
    const permissionMode = {
      value: "default",
      options: [{ value: "default", label: "Manual" }],
      pending: false,
      error: null,
      setValue: () => {},
    };
    const { container } = renderWithContext(
      <><PermissionModeControl /><PermissionModeControl /></>,
      permissionMode,
    );
    const selects = [...container.querySelectorAll("select")];
    const labels = [...container.querySelectorAll("label")];
    expect(selects).toHaveLength(2);
    expect(new Set(selects.map((select) => select.id)).size).toBe(2);
    expect(labels.map((label) => label.htmlFor)).toEqual(selects.map((select) => select.id));
  });
});

describe("ModelPickerDialog", () => {
  const modelOpts = [
    { value: "default", label: "Default" },
    { value: "haiku", label: "Haiku" },
    { value: "sonnet", label: "Sonnet" },
    { value: "opus", label: "Opus" },
  ];
  const mk = (over = {}) => ({ value: "default", options: modelOpts, setValue: vi.fn(), pickerOpen: false, setPickerOpen: vi.fn(), ...over });
  it("renders nothing without model capability", () => {
    render(<ShinyConfigContext.Provider value={baseContext}><ModelPickerDialog /></ShinyConfigContext.Provider>);
    expect(screen.queryByRole("combobox")).toBeNull();
  });
  // ModelPickerDialog 现在渲染官方 @assistant-ui ModelSelector(需 AssistantRuntimeProvider 的
  // useAui;渲染 combobox trigger + 受控 popover)。trigger 显示当前模型、打开/选择交互由 headless
  // verify(真实 runtime)覆盖,不在此 jsdom 单测里重复(base-ui popover + portal 不适合 jsdom)。
});

describe("SidebarSettings", () => {
  const ctxWith = (over: Partial<ShinyConfigCtx> = {}): ShinyConfigCtx => ({
    ...baseContext,
    permissionMode: {
      value: "default",
      options: [
        { value: "default", label: "Manual", description: "Ask before edits" },
        { value: "bypassPermissions", label: "Bypass" },
        { value: "yolo", label: "YOLO" },
      ],
      pending: false, error: null, setValue: () => {},
    },
    defaultPermissionMode: "default",
    setDefaultPermissionMode: vi.fn(),
    modeVisibility: { showBypass: true, showYolo: true },
    setModeVisibility: vi.fn(),
    ...over,
  });

  it("opens an inline non-Portal panel with default-mode + visibility controls", () => {
    const { container } = render(
      <ShinyConfigContext.Provider value={ctxWith()}><SidebarSettings /></ShinyConfigContext.Provider>,
    );
    const settingsButton = screen.getByRole("button", { name: "Settings" });
    fireEvent.click(settingsButton);
    const panel = screen.getByRole("dialog", { name: "Settings" });
    expect(container.contains(panel)).toBe(true);
    // 重定位后:Settings 放"新会话默认模式" + 可见性开关(不再是 composer 的即时 Permission mode)
    expect(panel.querySelector('select[aria-label="Default permission mode"]')).toBeTruthy();
    expect(panel.querySelector('[data-mode-vis="showBypass"]')).toBeTruthy();
    expect(panel.querySelector('[data-mode-vis="showYolo"]')).toBeTruthy();
    expect(document.activeElement).toBe(panel);

    fireEvent.keyDown(panel, { key: "Escape" });
    expect(screen.queryByRole("dialog", { name: "Settings" })).toBeNull();
    expect(document.activeElement).toBe(settingsButton);
  });

  it("hides YOLO from the default-mode select when visibility is off", () => {
    render(
      <ShinyConfigContext.Provider value={ctxWith({ modeVisibility: { showBypass: true, showYolo: false } })}>
        <SidebarSettings />
      </ShinyConfigContext.Provider>,
    );
    fireEvent.click(screen.getByRole("button", { name: "Settings" }));
    const sel = screen.getByLabelText("Default permission mode") as HTMLSelectElement;
    const values = Array.from(sel.options).map((o) => o.value);
    expect(values).toContain("bypassPermissions");
    expect(values).not.toContain("yolo");
  });

  it("shows an enabled-by-default copilot-api auto-start toggle and delegates changes", () => {
    const setAutoStartCopilotApi = vi.fn();
    const context = {
      ...ctxWith(),
      autoStartCopilotApi: true,
      setAutoStartCopilotApi,
    } as ShinyConfigCtx;
    render(
      <ShinyConfigContext.Provider value={context}>
        <SidebarSettings />
      </ShinyConfigContext.Provider>,
    );

    fireEvent.click(screen.getByRole("button", { name: "Settings" }));
    const toggle = screen.getByRole("checkbox", {
      name: "Automatically start copilot-api",
    }) as HTMLInputElement;
    expect(toggle.checked).toBe(true);

    fireEvent.click(toggle);
    expect(setAutoStartCopilotApi).toHaveBeenCalledOnce();
    expect(setAutoStartCopilotApi).toHaveBeenCalledWith(false);
  });
});

describe("ThinkingControl", () => {
  const thinkingOpts = [
    { value: "default", label: "Default" },
    { value: "adaptive", label: "Adaptive" },
    { value: "enabled", label: "Extended" },
    { value: "disabled", label: "Off" },
  ];
  it("absent without capability", () => {
    render(<ShinyConfigContext.Provider value={baseContext}><ThinkingControl /></ShinyConfigContext.Provider>);
    expect(screen.queryByLabelText("Thinking level")).toBeNull();
  });
  it("renders options and delegates selection", () => {
    const setValue = vi.fn();
    render(
      <ShinyConfigContext.Provider value={{ ...baseContext, thinking: { value: "default", options: thinkingOpts, setValue } }}>
        <ThinkingControl />
      </ShinyConfigContext.Provider>,
    );
    const select = screen.getByLabelText("Thinking level") as HTMLSelectElement;
    expect(select.value).toBe("default");
    expect(screen.getByRole("option", { name: "Extended" })).toBeTruthy();
    fireEvent.change(select, { target: { value: "enabled" } });
    expect(setValue).toHaveBeenCalledWith("enabled");
  });
});


describe("Assistant text size and constrained Settings layout", () => {
  it("offers three assistant text sizes and delegates the selected value", () => {
    const setAssistantTextSize = vi.fn();
    const context = {
      ...baseContext,
      assistantTextSize: "small",
      setAssistantTextSize,
    } as ShinyConfigCtx;
    render(
      <ShinyConfigContext.Provider value={context}>
        <SidebarSettings />
      </ShinyConfigContext.Provider>,
    );

    fireEvent.click(screen.getByRole("button", { name: "Settings" }));
    const select = screen.getByLabelText("Assistant text size") as HTMLSelectElement;
    expect(select.value).toBe("small");
    expect(Array.from(select.options).map((option) => option.value))
      .toEqual(["small", "compact", "medium"]);
    expect(Array.from(select.options).map((option) => option.textContent))
      .toEqual(["Small", "Medium", "Default"]);
    fireEvent.change(select, { target: { value: "compact" } });
    expect(setAssistantTextSize).toHaveBeenCalledWith("compact");
  });

  it("constrains the dialog to the sidebar and makes overflow scrollable", () => {
    const context = {
      ...baseContext,
      assistantTextSize: "medium",
      setAssistantTextSize: vi.fn(),
    } as ShinyConfigCtx;
    const { container } = render(
      <div data-slot="aui_thread_sidebar" className="relative h-80">
        <ShinyConfigContext.Provider value={context}>
          <SidebarSettings />
        </ShinyConfigContext.Provider>
      </div>,
    );

    fireEvent.click(screen.getByRole("button", { name: "Settings" }));
    const wrapper = container.querySelector(".aui-sidebar-settings") as HTMLElement;
    const dialog = container.querySelector('[data-slot="aui_settings_dialog"]') as HTMLElement;
    const header = container.querySelector('[data-slot="aui_settings_header"]') as HTMLElement;
    expect(wrapper.className).not.toContain("relative");
    expect(dialog.className).toContain("max-h-[calc(100%-4rem)]");
    expect(dialog.className).toContain("overflow-y-auto");
    expect(dialog.className).toContain("overscroll-contain");
    expect(dialog.className).toContain("[scrollbar-gutter:stable]");
    expect(header.className).toContain("sticky");
  });
});
