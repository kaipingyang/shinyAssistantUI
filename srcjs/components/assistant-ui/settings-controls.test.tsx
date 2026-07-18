// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { ShinyConfigContext, type ShinyConfigCtx } from "../../shiny-config-context";
import { PermissionModeControl, SidebarSettings } from "./settings-controls";

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

describe("SidebarSettings", () => {
  it("opens an inline non-Portal settings panel sharing the permission control", () => {
    const { container } = renderWithContext(<SidebarSettings />, {
      value: "default",
      options: [{ value: "default", label: "Manual", description: "Ask before edits" }],
      pending: false,
      error: null,
      setValue: () => {},
    });
    const settingsButton = screen.getByRole("button", { name: "Settings" });
    fireEvent.click(settingsButton);
    const panel = screen.getByRole("dialog", { name: "Settings" });
    expect(container.contains(panel)).toBe(true);
    expect(panel.querySelector('select[aria-label="Permission mode"]')).toBeTruthy();
    expect(document.activeElement).toBe(panel);

    fireEvent.keyDown(panel, { key: "Escape" });
    expect(screen.queryByRole("dialog", { name: "Settings" })).toBeNull();
    expect(document.activeElement).toBe(settingsButton);
  });
});
