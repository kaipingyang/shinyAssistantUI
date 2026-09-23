// @vitest-environment jsdom
import type { ComponentType, ComponentProps } from "react";
import { cleanup, render } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { MarkdownText } from "./markdown-text";

const fixture = vi.hoisted(() => ({ href: "https://example.invalid/docs" }));
vi.mock("@assistant-ui/react-markdown", async (importOriginal) => ({
  ...await importOriginal<typeof import("@assistant-ui/react-markdown")>(),
  unstable_memoizeMarkdownComponents: (components: unknown) => components,
  MarkdownTextPrimitive: ({ components }: {
    components: { a: ComponentType<ComponentProps<"a">> };
  }) => <components.a href={fixture.href}>Documentation</components.a>,
}));
afterEach(() => {
  cleanup();
  fixture.href = "https://example.invalid/docs";
});

describe("assistant web links", () => {
  it("uses the scoped web-link palette, not the Send-button primary", () => {
    const { getByRole } = render(<MarkdownText />);
    const link = getByRole("link", { name: "Documentation" });
    expect(link.className).toContain("aui-web-link");
    expect(link.className).not.toMatch(/text-primary/);
    expect(link.getAttribute("href")).toBe(fixture.href);
    expect(link.getAttribute("target")).toBe("_blank");
    expect(link.getAttribute("rel")).toBe("noopener noreferrer");
  });

  it("does not turn a rejected URL into a clickable blue link", () => {
    fixture.href = "javascript:alert(1)";
    const { container, queryByRole } = render(<MarkdownText />);
    expect(queryByRole("link")).toBeNull();
    expect(container.textContent).toBe("Documentation");
    expect(container.querySelector("a[href]")).toBeNull();
  });
});
