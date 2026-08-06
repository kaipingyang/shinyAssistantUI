/** @vitest-environment jsdom */
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { useOpeningFile } from "./use-opening-file";

function Harness({ onOpen }: { onOpen: (path: string) => void }) {
  const { opening, open } = useOpeningFile(onOpen);
  return (
    <button aria-busy={opening} onClick={() => open("/project/subfolder/dm.R")}>
      {opening ? "Opening…" : "dm.R"}
    </button>
  );
}

describe("useOpeningFile", () => {
  afterEach(() => {
    cleanup();
    vi.useRealTimers();
  });

  it("shows English Opening feedback immediately and resets after 1.5s", () => {
    vi.useFakeTimers();
    const onOpen = vi.fn();
    render(<Harness onOpen={onOpen} />);

    fireEvent.click(screen.getByRole("button", { name: "dm.R" }));
    expect(onOpen).toHaveBeenCalledWith("/project/subfolder/dm.R");
    expect(screen.getByRole("button", { name: "Opening…" }).getAttribute("aria-busy")).toBe("true");

    fireEvent.click(screen.getByRole("button", { name: "Opening…" }));
    expect(onOpen).toHaveBeenCalledTimes(1);

    act(() => vi.advanceTimersByTime(1500));
    expect(screen.getByRole("button", { name: "dm.R" }).getAttribute("aria-busy")).toBe("false");
  });


  it("clears the pending feedback timer on unmount", () => {
    vi.useFakeTimers();
    const { unmount } = render(<Harness onOpen={vi.fn()} />);
    fireEvent.click(screen.getByRole("button", { name: "dm.R" }));
    expect(vi.getTimerCount()).toBe(1);
    unmount();
    expect(vi.getTimerCount()).toBe(0);
  });
});
