// @vitest-environment jsdom
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";

vi.mock("./AssistantUI", () => ({ default: () => null }));
vi.mock("react-dom/client", () => ({
  default: { createRoot: () => ({ render: vi.fn(), unmount: vi.fn() }) },
}));

type Binding = {
  renderValue: (element: HTMLElement, data: { inputId: string; config: object }) => void;
};
let binding: Binding;

beforeAll(async () => {
  vi.stubGlobal("Shiny", {
    OutputBinding: class {},
    outputBindings: { register: (value: Binding) => { binding = value; } },
  });
  await import("./index");
});

afterEach(async () => {
  document.body.replaceChildren();
  await Promise.resolve();
});
afterAll(() => vi.unstubAllGlobals());

describe("native output binding preserves the R container dimensions", () => {
  it.each(["600px", "100vh", "100%", "250px", "auto"])(
    "does not replace an explicit %s height with an unbounded percentage",
    (height) => {
      const element = document.createElement("div");
      element.style.height = height;
      element.style.minHeight = "0px";
      document.body.appendChild(element);
      binding.renderValue(element, { inputId: "chat_input", config: {} });
      expect(element.style.height).toBe(height);
      expect(element.style.minHeight).toBe("0px");
      element.style.height = "320px";
      binding.renderValue(element, { inputId: "chat_input", config: {} });
      expect(element.style.height).toBe("320px");
    },
  );
});
