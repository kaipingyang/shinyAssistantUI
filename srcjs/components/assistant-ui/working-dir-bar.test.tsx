// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import {
  AssistantRuntimeProvider,
  useExternalStoreRuntime,
} from "@assistant-ui/react";
import { ShinyConfigContext, type ShinyConfigCtx } from "../../shiny-config-context";
import { WorkingDirBar } from "./working-dir-bar";

const base: ShinyConfigCtx = {
  tools: [], commands: [], actionItems: [], showTimestamps: false,
  onEnqueue: () => {}, onRename: () => {}, onInvokeAction: () => {},
};
afterEach(cleanup);

function BarHarness({
  value,
  isRunning,
}: {
  value: ShinyConfigCtx;
  isRunning: boolean;
}) {
  const runtime = useExternalStoreRuntime({
    messages: [],
    isRunning,
    convertMessage: (message) => message,
    onNew: async () => {},
  });
  return (
    <AssistantRuntimeProvider runtime={runtime}>
      <ShinyConfigContext.Provider value={value}>
        <WorkingDirBar />
      </ShinyConfigContext.Provider>
    </AssistantRuntimeProvider>
  );
}

function renderBar(over: Partial<ShinyConfigCtx> = {}, isRunning = false) {
  const value = {
    ...base, workingDir: "/proj/app", projects: ["/a/one", "/b/two"],
    setWorkingDir: vi.fn(), ...over,
  } as ShinyConfigCtx;
  return render(<BarHarness value={value} isRunning={isRunning} />);
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


describe("WorkingDirBar favorites ordering", () => {
  it("renders a case-insensitive natural name order without mutating input", () => {
    const projects = [
      "/work/zeta",
      "/work/project-10",
      "/work/Alpha",
      "/work/project-2",
    ];
    const original = [...projects];
    const { container } = renderBar({ projects });

    fireEvent.click(screen.getByRole("button", { name: /Favorites \(4\)/ }));
    expect(Array.from(container.querySelectorAll("[data-slot=aui_project_item]"))
      .map((node) => node.getAttribute("data-project")))
      .toEqual([
        "/work/Alpha",
        "/work/project-2",
        "/work/project-10",
        "/work/zeta",
      ]);
    expect(projects).toEqual(original);
  });
});


describe("WorkingDirBar run guard", () => {
  it("opens the native picker while idle", () => {
    const pickWorkingDir = vi.fn();
    renderBar({ nativePicker: true, pickWorkingDir });

    fireEvent.click(screen.getByRole("button", { name: "app" }));
    expect(pickWorkingDir).toHaveBeenCalledTimes(1);
  });

  it("blocks native picker and favorite folder changes while running", () => {
    const pickWorkingDir = vi.fn();
    const setWorkingDir = vi.fn();
    const { container } = renderBar({
      nativePicker: true,
      pickWorkingDir,
      setWorkingDir,
    }, true);

    const change = container.querySelector(
      '[data-slot="aui_working_dir_change"]',
    ) as HTMLButtonElement;
    expect(change.disabled).toBe(true);
    expect(change.getAttribute("aria-disabled")).toBe("true");
    expect(change.dataset.runningDisabled).toBe("true");
    fireEvent.click(change);
    expect(pickWorkingDir).not.toHaveBeenCalled();

    fireEvent.click(screen.getByRole("button", { name: /Favorites \(2\)/ }));
    const jump = container.querySelector(
      '[data-slot="aui_project_jump"]',
    ) as HTMLButtonElement;
    expect(jump.disabled).toBe(true);
    fireEvent.click(jump);
    expect(setWorkingDir).not.toHaveBeenCalled();
  });
});
