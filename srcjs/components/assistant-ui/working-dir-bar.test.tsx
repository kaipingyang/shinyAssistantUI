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
