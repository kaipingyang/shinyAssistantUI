import { describe, expect, it } from "vitest";
import { createThreadSearchIndex, matchThreadSearch, normalizeThreadSearch } from "./thread-search";

describe("history metadata search", () => {
  const items = [
    { id: "one", title: "Quarterly Analysis", custom: { preview: "Trial [A.*] results" } },
    { id: "two", title: "历史摘要", custom: { preview: "中文检索与复盘" } },
    { id: "three", title: "Other", custom: { project: "/not-a-search-field" } },
    { id: "four", title: "Legacy title" },
  ];

  it("normalizes case, whitespace and Unicode without treating punctuation as a regex", () => {
    expect(normalizeThreadSearch("  Ａnalysis \n REPORT  ")).toBe("analysis report");
    const index = createThreadSearchIndex(items);
    expect([...matchThreadSearch(index, "  qUaRtErLy  ")!]).toEqual(["one"]);
    expect([...matchThreadSearch(index, "[A.*]")!]).toEqual(["one"]);
    expect([...matchThreadSearch(index, ".*")!]).toEqual(["one"]);
    expect([...matchThreadSearch(index, "不存在")!]).toEqual([]);
  });

  it("matches existing previews and Chinese text but not IDs or project metadata", () => {
    const index = createThreadSearchIndex(items);
    expect([...matchThreadSearch(index, "检索")!]).toEqual(["two"]);
    expect([...matchThreadSearch(index, "历史")!]).toEqual(["two"]);
    expect([...matchThreadSearch(index, "not-a-search-field")!]).toEqual([]);
    expect([...matchThreadSearch(index, "three")!]).toEqual([]);
  });

  it("treats an empty/whitespace query as no filter and accepts legacy metadata", () => {
    const index = createThreadSearchIndex([
      ...items, { id: "empty" }, { id: "invalid-preview", custom: { preview: { text: "Not text" } } },
    ]);
    expect(matchThreadSearch(index, "")).toBeUndefined();
    expect(matchThreadSearch(index, " \t ")).toBeUndefined();
    expect([...matchThreadSearch(index, "legacy")!]).toEqual(["four"]);
    expect([...matchThreadSearch(index, "New Chat")!]).toEqual(["empty", "invalid-preview"]);
    expect([...matchThreadSearch(index, "Not text")!]).toEqual([]);
  });

  it("indexes the whole catalog, not only the rendered first page", () => {
    const index = createThreadSearchIndex(Array.from({ length: 10_000 }, (_, i) => ({
      id: `session-${i}`,
      title: `Conversation ${i}`,
      custom: { preview: i === 9_999 ? "Deep catalog needle" : "Regular preview" },
    })));
    expect(index.size).toBe(10_000);
    expect([...matchThreadSearch(index, "deep catalog needle")!]).toEqual(["session-9999"]);
    expect(matchThreadSearch(index, "conversation")?.size).toBe(10_000);
  });
});
