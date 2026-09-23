/** @vitest-environment jsdom */
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { useOpeningFile } from "./use-opening-file";

function Harness({ onOpen }: { onOpen: (path: string) => unknown }) {
  const { opening, failed, open } = useOpeningFile(onOpen);
  return (
    <button aria-busy={opening} onClick={() => open("/project/subfolder/dm.R")}>
      {opening ? "Opening…" : failed ? "Open failed" : "dm.R"}
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

  it("waits for a real asynchronous outcome instead of declaring completion after 1.5 seconds", async () => {
    vi.useFakeTimers();
    let finish!: (value: boolean) => void;
    const onOpen = vi.fn(() => new Promise<boolean>((resolve) => { finish = resolve; }));
    render(<Harness onOpen={onOpen} />);
    fireEvent.click(screen.getByRole("button", { name: "dm.R" }));
    await act(async () => { await vi.advanceTimersByTimeAsync(2000); });
    expect(screen.getByRole("button", { name: "Opening…" }).getAttribute("aria-busy")).toBe("true");
    fireEvent.click(screen.getByRole("button", { name: "Opening…" }));
    expect(onOpen).toHaveBeenCalledOnce();
    await act(async () => finish(false));
    expect(screen.getByRole("button", { name: "Open failed" }).getAttribute("aria-busy")).toBe("false");
    fireEvent.click(screen.getByRole("button", { name: "Open failed" }));
    await act(async () => finish(true));
    expect(screen.getByRole("button", { name: "dm.R" })).toBeTruthy();
  });

  it("settles safely when a pending open outlives its component", async () => {
    let finish!: (value: boolean) => void;
    const view = render(<Harness onOpen={() => new Promise<boolean>((resolve) => { finish = resolve; })} />);
    fireEvent.click(screen.getByRole("button", { name: "dm.R" }));
    view.unmount();
    await act(async () => finish(true));
  });
});
