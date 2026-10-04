// @vitest-environment jsdom
import React from "react";
import { cleanup, fireEvent, render } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { A2uiRuntimeView, openSafeA2uiUrl } from "./render";

afterEach(cleanup);

describe("A2UI runtime renderer safety", () => {
  it("forces no-referrer on the rendered image element", () => {
    const view = render(
      <A2uiRuntimeView
        surfaceId="surface-1"
        spec={{
          $type: "Image",
          src: "https://example.com/image.png",
          alt: "safe image",
          size: 32,
          referrerPolicy: "unsafe-url",
        }}
      />,
    );
    const image = view.getByRole("img");
    expect(image.getAttribute("src")).toBe("https://example.com/image.png");
    expect(image.getAttribute("referrerpolicy")).toBe("no-referrer");
  });

  it("renders no image for a rejected source", () => {
    const view = render(
      <A2uiRuntimeView
        surfaceId="surface-1"
        spec={{ $type: "Image", src: "javascript:alert(1)", alt: "bad" }}
      />,
    );
    expect(view.queryByRole("img")).toBeNull();
  });

  it("dispatches a filtered button action through the bound widget callback", () => {
    const dispatch = vi.fn();
    const view = render(
      <A2uiRuntimeView
        surfaceId="surface-1"
        dispatch={dispatch}
        spec={{
          $type: "Button", label: "Confirm",
          $action: {
            type: "a2ui:action", name: "confirm", surfaceId: "surface-1",
            sourceComponentId: "button-1", context: { mode: "safe" }, $input: { accepted: true },
          },
        }}
      />,
    );
    fireEvent.click(view.getByRole("button", { name: "Confirm" }));
    expect(dispatch).toHaveBeenCalledExactlyOnceWith({
      type: "a2ui:action", name: "confirm", surfaceId: "surface-1",
      sourceComponentId: "button-1", context: { mode: "safe" }, $input: { accepted: true },
    });
  });
});


it("keeps A2UI inputs, sibling bindings, and action context on one live local model", () => {
  const dispatch = vi.fn();
  const operations = [
    { version: "v0.9", createSurface: { surfaceId: "surface-form" } },
    { version: "v0.9", updateComponents: {
      surfaceId: "surface-form",
      components: [
        { id: "root", component: "Column", children: ["field", "mirror", "submit"] },
        { id: "field", component: "TextField", label: "Name", value: { path: "/name" } },
        { id: "mirror", component: "Text", text: { path: "/name" } },
        { id: "submit", component: "Button", text: "Submit", action: {
          event: { name: "submit", context: { name: { path: "/name" } } },
        } },
      ],
    } },
    { version: "v0.9", updateDataModel: {
      surfaceId: "surface-form", path: "/", contents: { name: "Ada" },
    } },
  ];
  const view = render(
    <A2uiRuntimeView
      surfaceId="surface-form"
      spec={{ $type: "Text", value: "fallback" }}
      operations={operations}
      dispatch={dispatch}
    />,
  );
  const input = view.getByRole("textbox", { name: "Name" }) as HTMLInputElement;
  expect(input.value).toBe("Ada");
  expect(view.getByText("Ada")).toBeTruthy();
  fireEvent.change(input, { target: { value: "Grace" } });
  expect(input.value).toBe("Grace");
  expect(view.getByText("Grace")).toBeTruthy();
  fireEvent.click(view.getByRole("button", { name: "Submit" }));
  expect(dispatch).toHaveBeenCalledExactlyOnceWith(expect.objectContaining({
    type: "a2ui:action", name: "submit", surfaceId: "surface-form",
    sourceComponentId: "submit", context: { name: "Grace" },
  }));
});


it("preserves local edits across unrelated agent updates and yields on same-path updates", () => {
  const operations = (name: string, status: string) => [
    { version: "v0.9", createSurface: { surfaceId: "surface-reconcile" } },
    { version: "v0.9", updateComponents: {
      surfaceId: "surface-reconcile",
      components: [
        { id: "root", component: "Column", children: ["field", "mirror", "status"] },
        { id: "field", component: "TextField", label: "Name", value: { path: "/name" } },
        { id: "mirror", component: "Text", text: { path: "/name" } },
        { id: "status", component: "Text", text: { path: "/status" } },
      ],
    } },
    { version: "v0.9", updateDataModel: {
      surfaceId: "surface-reconcile", path: "/", contents: { name, status },
    } },
  ];
  const view = render(
    <A2uiRuntimeView
      surfaceId="surface-reconcile" spec={{}}
      operations={operations("Ada", "first")}
    />,
  );
  const input = view.getByRole("textbox", { name: "Name" }) as HTMLInputElement;
  fireEvent.change(input, { target: { value: "Grace" } });
  expect(input.value).toBe("Grace");

  view.rerender(
    <A2uiRuntimeView
      surfaceId="surface-reconcile" spec={{}}
      operations={operations("Ada", "second")}
    />,
  );
  expect((view.getByRole("textbox", { name: "Name" }) as HTMLInputElement).value).toBe("Grace");
  expect(view.getByText("Grace")).toBeTruthy();
  expect(view.getByText("second")).toBeTruthy();

  view.rerender(
    <A2uiRuntimeView
      surfaceId="surface-reconcile" spec={{}}
      operations={operations("Agent", "third")}
    />,
  );
  expect((view.getByRole("textbox", { name: "Name" }) as HTMLInputElement).value).toBe("Agent");
  expect(view.getByText("Agent")).toBeTruthy();
});


describe("A2UI local openUrl function", () => {
  it("opens only credential-free HTTP(S) URLs with isolation features", () => {
    const open = vi.fn();
    const payload = {
      type: "a2ui:functionCall", call: "openUrl",
      surfaceId: "surface-url", sourceComponentId: "open",
      args: { url: "/docs" },
    };
    expect(openSafeA2uiUrl(payload, "surface-url", open, "https://example.com/chat")).toBe(true);
    expect(open).toHaveBeenCalledExactlyOnceWith(
      "https://example.com/docs", "_blank", "noopener,noreferrer",
    );
    for (const url of [
      "javascript:alert(1)", "data:text/html,bad", "file:///tmp/x",
      "https://user:pass@example.com/private", "http://[::1",
    ]) {
      expect(openSafeA2uiUrl({ ...payload, args: { url } }, "surface-url", open,
        "https://example.com/chat")).toBe(false);
    }
    expect(open).toHaveBeenCalledTimes(1);
    expect(openSafeA2uiUrl({ ...payload, surfaceId: "other" }, "surface-url", open,
      "https://example.com/chat")).toBe(false);
  });

  it("dispatches functionCall locally without using the R action callback", () => {
    const open = vi.spyOn(window, "open").mockImplementation(() => null);
    const dispatch = vi.fn();
    const operations = [
      { version: "v0.9.1", createSurface: { surfaceId: "surface-url" } },
      { version: "v0.9.1", updateComponents: {
        surfaceId: "surface-url", components: [
          { id: "root", component: "Button", text: "Open docs", action: {
            functionCall: { call: "openUrl", args: { url: "https://example.com/docs" } },
          } },
        ],
      } },
    ];
    const view = render(
      <A2uiRuntimeView surfaceId="surface-url" spec={{}}
        operations={operations} dispatch={dispatch} />,
    );
    fireEvent.click(view.getByRole("button", { name: "Open docs" }));
    expect(open).toHaveBeenCalledExactlyOnceWith(
      "https://example.com/docs", "_blank", "noopener,noreferrer",
    );
    expect(dispatch).not.toHaveBeenCalled();
  });
});
