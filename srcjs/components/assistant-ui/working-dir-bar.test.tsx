// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { ShinyConfigContext, type ShinyConfigCtx } from "../../shiny-config-context";
import { WorkingDirBar } from "./working-dir-bar";

const base: ShinyConfigCtx = {
  tools: [], commands: [], actionItems: [], showTimestamps: false,
  onEnqueue: () => {}, onRename: () => {}, onInvokeAction: () => {},
};
afterEach(cleanup);

function renderBar(over: Partial<ShinyConfigCtx> = {}) {
  return render(
    <ShinyConfigContext.Provider value={{
      ...base, workingDir: "/proj/app", projects: ["/a/one", "/b/two"],
      setWorkingDir: vi.fn(), ...over,
    }}>
      <WorkingDirBar />
    </ShinyConfigContext.Provider>,
  );
}

describe("WorkingDirBar favorites (collapsible)", () => {
  it("is collapsed by default, shows a count, and hides the items", () => {
    renderBar();
    const toggle = screen.getByRole("button", { name: /Favorites \(2\)/ });
    expect(toggle.getAttribute("aria-expanded")).toBe("false");
    expect(screen.queryByText("one")).toBeNull();
    expect(screen.queryByText("two")).toBeNull();
  });

  it("expands to reveal the favorite folders on click", () => {
    const setWorkingDir = vi.fn();
    renderBar({ setWorkingDir });
    fireEvent.click(screen.getByRole("button", { name: /Favorites \(2\)/ }));
    const toggle = screen.getByRole("button", { name: /Favorites \(2\)/ });
    expect(toggle.getAttribute("aria-expanded")).toBe("true");
    fireEvent.click(screen.getByText("one"));
    expect(setWorkingDir).toHaveBeenCalledWith("/a/one");
  });
});

describe("WorkingDirBar files-pane-follow toggle", () => {
  it("is absent when the capability is not provided", () => {
    renderBar();
    expect(screen.queryByText("Sync Files pane to folder")).toBeNull();
  });
  it("reflects the value and reports changes", () => {
    const setFilesPaneFollow = vi.fn();
    renderBar({ filesPaneFollow: true, setFilesPaneFollow });
    const box = screen.getByRole("checkbox") as HTMLInputElement;
    expect(box.checked).toBe(true);
    fireEvent.click(box);
    expect(setFilesPaneFollow).toHaveBeenCalledWith(false);
  });
});

describe("WorkingDirBar auto-run toggle", () => {
  it("is absent when the capability is not provided", () => {
    renderBar();
    expect(screen.queryByText("Auto-run R (Claude)")).toBeNull();
  });
  it("reflects the value and reports changes", () => {
    const setAutoRunEnabled = vi.fn();
    renderBar({ autoRunEnabled: false, setAutoRunEnabled });
    const box = screen.getByRole("checkbox") as HTMLInputElement;
    expect(box.checked).toBe(false);
    fireEvent.click(box);
    expect(setAutoRunEnabled).toHaveBeenCalledWith(true);
  });
});
