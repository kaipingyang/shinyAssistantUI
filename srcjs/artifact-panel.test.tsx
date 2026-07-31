// @vitest-environment jsdom
// Plan 47 A3 — Artifact panel real rendering.
// code path uses SyntaxHighlighter (pure PrismLight, no context) → unit-testable here.
// markdown path (MarkdownText, needs ShinyConfig context) is covered by tests/verify/verify_artifacts.R.
import { describe, it, expect } from "vitest";
import { render } from "@testing-library/react";
import { ArtifactPanel } from "@/artifact-panel";

const noop = () => {};

describe("Plan 47 A3 — ArtifactPanel", () => {
  it("code artifact is syntax-highlighted (uses lang), not a plain <pre>", () => {
    const { container } = render(
      <ArtifactPanel artifact={{ id: "c1", title: "Model", type: "code", lang: "r", content: "lm(y ~ x)" }} onClose={noop} />,
    );
    expect(container.querySelector("[data-syntax-highlighter]")).not.toBeNull();
    expect(container.textContent).toContain("lm(y ~ x)");
  });

  it("html artifact still renders a sandboxed iframe", () => {
    const { container } = render(
      <ArtifactPanel artifact={{ id: "h1", title: "Site", type: "html", content: "<b>hi</b>" }} onClose={noop} />,
    );
    const iframe = container.querySelector("iframe.aui-artifact-html");
    expect(iframe).not.toBeNull();
    expect(iframe!.getAttribute("sandbox")).toBe("");
  });
});
