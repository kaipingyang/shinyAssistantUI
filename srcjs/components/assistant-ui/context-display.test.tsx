// @vitest-environment jsdom
import { afterEach, describe, expect, it } from "vitest";
import { cleanup, render, screen } from "@testing-library/react";
import { ShinyConfigContext, type ShinyConfigCtx } from "@/shiny-config-context";
import { ShinyContextDisplay } from "./context-display";

const baseContext: ShinyConfigCtx = {
  tools: [], commands: [], actionItems: [], showTimestamps: false,
  onEnqueue: () => {}, onRename: () => {}, onInvokeAction: () => {},
  selectionVisible: true, setSelectionVisible: () => {},
  refreshIdeContext: () => {},
  workspaceMentions: { enabled: false, query: "", items: [], loading: false },
  searchWorkspace: () => {},
};

afterEach(cleanup);

describe("ShinyContextDisplay stable usage affordance", () => {
  it("shows an unknown placeholder instead of disappearing before usage arrives", () => {
    render(
      <ShinyConfigContext.Provider value={{
        ...baseContext,
        showUsage: true,
        usageStyle: "ring",
      }}>
        <ShinyContextDisplay />
      </ShinyConfigContext.Provider>,
    );

    const trigger = screen.getByRole("button", {
      name: "Context usage unavailable",
    });
    expect(trigger.getAttribute("data-usage-unavailable")).toBe("true");
    expect(trigger.querySelector("svg circle")).toBeTruthy();
    expect(trigger.textContent).toContain("—");
  });

  it("remains absent when usage UI is not enabled", () => {
    render(
      <ShinyConfigContext.Provider value={baseContext}>
        <ShinyContextDisplay />
      </ShinyConfigContext.Provider>,
    );
    expect(screen.queryByRole("button")).toBeNull();
  });
});
