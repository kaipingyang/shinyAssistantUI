// @vitest-environment jsdom
import React from "react";
import { act, cleanup, fireEvent, render } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { createFileReferenceClient, type FileReferenceRequest, type FileReferenceView } from "@/file-reference";
import { MarkdownText } from "./markdown-text";

const fixture = vi.hoisted(() => ({
  text: "settings.json", block: false, open: vi.fn(),
  references: undefined as FileReferenceView | undefined,
}));
vi.mock("@/shiny-config-context", async (importOriginal) => ({
  ...await importOriginal<typeof import("@/shiny-config-context")>(),
  useShinyConfig: () => ({ onOpenFile: fixture.open, fileReferences: fixture.references }),
}));
vi.mock("@assistant-ui/react-markdown", async (importOriginal) => {
  const original = await importOriginal<typeof import("@assistant-ui/react-markdown")>();
  return {
    ...original,
    unstable_memoizeMarkdownComponents: (components: unknown) => components,
    useIsMarkdownCodeBlock: () => fixture.block,
    MarkdownTextPrimitive: ({ components }: {
      components: { code: React.ComponentType<{ children: string }> };
    }) => <components.code>{fixture.text}</components.code>,
  };
});
afterEach(() => {
  cleanup();
  fixture.references?.client.clear();
  fixture.references = undefined;
  fixture.text = "settings.json";
  fixture.block = false;
  fixture.open.mockReset();
  vi.useRealTimers();
});

describe("confirmed inline file links", () => {
  it("does not lose the first click when revalidation begins between pointer-down and click", () => {
    vi.useFakeTimers();
    const requests: FileReferenceRequest[] = [];
    const client = createFileReferenceClient((request) => requests.push(request));
    fixture.references = { client, threadId: "history", project: "/project", candidate: (path) => path };
    const view = render(<MarkdownText />);
    act(() => vi.advanceTimersByTime(30));
    act(() => client.accept({
      version: 1, requestId: requests[0].requestId, threadId: "history",
      files: [{ path: "settings.json", resolvedPath: "/project/settings.json" }],
    }));
    const code = view.container.querySelector("code")!;
    fireEvent.pointerDown(code, { button: 0 });
    act(() => client.invalidate("history"));
    expect(code.getAttribute("role")).toBe("button");
    fireEvent.pointerUp(code, { button: 0 });
    fireEvent.click(code);
    expect(fixture.open).toHaveBeenCalledExactlyOnceWith("/project/settings.json");
    act(() => vi.advanceTimersByTime(30));
    act(() => client.accept({
      version: 1, requestId: requests[1].requestId, threadId: "history",
      files: [{ path: "settings.json", resolvedPath: null }],
    }));
    expect(view.container.querySelector("code[role=button]")).toBeNull();
  });

  it("keeps unknown references gray and noninteractive until the backend confirms a path", () => {
    vi.useFakeTimers();
    fixture.text = "settings.json:7";
    const requests: FileReferenceRequest[] = [];
    const client = createFileReferenceClient((request) => requests.push(request));
    fixture.references = { client, threadId: "history", project: "/project", candidate: (path) => path };
    const view = render(<MarkdownText />);
    const code = () => view.container.querySelector("code")!;
    expect(code().getAttribute("role")).toBeNull();
    expect(code().hasAttribute("tabindex")).toBe(false);
    expect(code().className).toContain("bg-muted");
    expect(code().className).not.toMatch(/bg-blue|cursor-pointer|underline/);
    fireEvent.click(code());
    expect(fixture.open).not.toHaveBeenCalled();
    act(() => vi.advanceTimersByTime(30));
    expect(requests[0].paths).toEqual(["settings.json"]);
    act(() => client.accept({
      version: 1, requestId: requests[0].requestId, threadId: "history",
      files: [{ path: "settings.json", resolvedPath: "/project/settings.json" }],
    }));
    expect(code().getAttribute("role")).toBe("button");
    expect(code().className).toContain("decoration-dotted");
    fireEvent.keyDown(code(), { key: "Enter" });
    expect(fixture.open).toHaveBeenCalledExactlyOnceWith("/project/settings.json", 7);
  });

  it("does not present missing files or unsupported-host references as links", () => {
    vi.useFakeTimers();
    const requests: FileReferenceRequest[] = [];
    const client = createFileReferenceClient((request) => requests.push(request));
    fixture.references = { client, threadId: "history", candidate: (path) => path };
    const view = render(<MarkdownText />);
    act(() => vi.advanceTimersByTime(30));
    act(() => client.accept({
      version: 1, requestId: requests[0].requestId, threadId: "history",
      files: [{ path: "settings.json", resolvedPath: null }],
    }));
    expect(view.container.querySelector("[data-file-ref]")).toBeNull();
    expect(view.container.querySelector("code")?.className).toContain("bg-muted");
    view.unmount();
    fixture.references = undefined;
    const plain = render(<MarkdownText />);
    expect(plain.container.querySelector("code[role=button]")).toBeNull();
    expect(plain.container.querySelector("code")?.className).toContain("bg-muted");
  });
});
