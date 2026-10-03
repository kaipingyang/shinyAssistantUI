// @vitest-environment jsdom
import React from "react";
import { cleanup, fireEvent, render } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { A2uiRuntimeView } from "./render";

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
