// @vitest-environment jsdom
import { describe, expect, it } from "vitest";
import { render } from "@testing-library/react";
import { getEditDiff } from "@/helpers";
import { DiffViewer } from "./diff-viewer";

describe("getEditDiff", () => {
  it("Edit → old/new/file", () => {
    expect(getEditDiff("Edit", { file_path: "a.R", old_string: "x <- 1", new_string: "x <- 2" }))
      .toEqual({ oldContent: "x <- 1", newContent: "x <- 2", fileName: "a.R" });
  });
  it("Edit 缺 new_string → null（流式中）", () => {
    expect(getEditDiff("Edit", { file_path: "a.R", old_string: "x <- 1" })).toBeNull();
  });
  it("MultiEdit → 合并各段 old/new", () => {
    expect(getEditDiff("MultiEdit", {
      file_path: "a.R",
      edits: [{ old_string: "a", new_string: "b" }, { old_string: "c", new_string: "d" }],
    })).toEqual({ oldContent: "a\nc", newContent: "b\nd", fileName: "a.R" });
  });
  it("Write / Bash / 空 → null", () => {
    expect(getEditDiff("Write", { file_path: "a.R", content: "x" })).toBeNull();
    expect(getEditDiff("Bash", { command: "ls" })).toBeNull();
    expect(getEditDiff(undefined, {})).toBeNull();
  });
});

describe("DiffViewer", () => {
  it("computes diff from old/new content (add + del lines)", () => {
    const { container } = render(
      <DiffViewer oldFile={{ content: "x <- 1", name: "a.R" }} newFile={{ content: "x <- 2", name: "a.R" }} viewMode="unified" />,
    );
    expect(container.querySelector('[data-slot=diff-viewer-line][data-type=add]')).not.toBeNull();
    expect(container.querySelector('[data-slot=diff-viewer-line][data-type=del]')).not.toBeNull();
    expect(container.textContent).toContain("x <- 2");
    expect(container.textContent).toContain("x <- 1");
  });

  it("loose-parses a bare +/- diff block (no @@ hunk header)", () => {
    const { container } = render(
      <DiffViewer patch={"- old line\n+ new line"} viewMode="unified" />,
    );
    expect(container.querySelector('[data-type=add]')).not.toBeNull();
    expect(container.querySelector('[data-type=del]')).not.toBeNull();
    expect(container.textContent).toContain("new line");
    expect(container.textContent).toContain("old line");
  });

  it("treats +++/--- headers as normal (not add/del)", () => {
    const { container } = render(<DiffViewer patch={"--- a/x\n+++ b/x\n- a\n+ b"} viewMode="unified" />);
    const adds = container.querySelectorAll('[data-type=add]');
    const dels = container.querySelectorAll('[data-type=del]');
    // 仅 `- a` / `+ b` 计入，不含 `---`/`+++` 头
    expect(adds.length).toBe(1);
    expect(dels.length).toBe(1);
  });
});
