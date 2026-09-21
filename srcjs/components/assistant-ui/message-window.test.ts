import { describe, expect, it } from "vitest";
import {
  buildMessageLayout,
  captureMessageAnchor,
  findMessageIndex,
  restoreMessageAnchor,
  selectMessageWindow,
  selectMountedMessageIds,
} from "./message-window";

// 虚拟化的窗口选择逻辑:给定全部消息 id、当前被观察到"在视口附近"的 id、
// 尾部强制挂载条数、正在编辑的 id,算出应该真正挂载哪些。
// 抽成纯函数以便脱离 DOM 测试 —— 滚动/观察器时序在浏览器门禁里另测。
describe("selectMountedMessageIds", () => {
  const ids = ["a", "b", "c", "d", "e", "f", "g", "h"];

  it("mounts everything when the thread is shorter than the tail window", () => {
    const short = ["a", "b"];
    expect(selectMountedMessageIds(short, new Set(), { tail: 5 })).toEqual(
      new Set(short),
    );
  });

  describe("measured message geometry", () => {
    it("includes each gap exactly once and preserves measured zero/fractional heights", () => {
      const layout = buildMessageLayout(
        ["a", "b", "c"],
        new Map([["a", 0], ["b", 50.5]]),
        100,
        24,
      );
      expect(layout.offsets).toEqual([0, 24, 98.5, 198.5]);
      expect(findMessageIndex(layout, -1)).toBe(-1);
      expect(findMessageIndex(layout, 24)).toBe(1);
      expect(findMessageIndex(layout, 98.5)).toBe(2);
      expect(findMessageIndex(layout, 10000)).toBe(2);
      expect(findMessageIndex(buildMessageLayout([], new Map()), 0)).toBe(-1);
    });

    it("replaces hidden runs with spacers instead of one placeholder per message", () => {
      const ids = Array.from({ length: 300 }, (_, i) => `m${i}`);
      const layout = buildMessageLayout(ids, new Map(), 100, 0);
      const window = selectMessageWindow(layout, 10000, 400, {
        overscan: 200,
        tail: 2,
        pinnedIds: new Set(["m3"]),
      });
      const rows = window.filter((item) => item.type === "message");
      const gaps = window.filter((item) => item.type === "spacer");
      expect(rows.map((row) => row.id)).toEqual([
        "m3", "m98", "m99", "m100", "m101", "m102", "m103", "m104",
        "m105", "m106", "m298", "m299",
      ]);
      expect(gaps).toHaveLength(3);
      expect(gaps.reduce((sum, gap) => sum + gap.height, rows.length * 100))
        .toBe(30000);
    });

    it("preserves a visible message through prepend and height correction above it", () => {
      const before = buildMessageLayout(["a", "b", "c"], new Map(), 100, 24);
      const anchor = captureMessageAnchor(before, 150);
      expect(anchor).toEqual({ id: "b", offset: 26 });
      const after = buildMessageLayout(
        ["older", "a", "b", "c"],
        new Map([["older", 250], ["a", 60]]),
        100,
        24,
      );
      expect(restoreMessageAnchor(after, anchor)).toBe(384);
      expect(restoreMessageAnchor(
        buildMessageLayout(["c"], new Map()), anchor,
      )).toBeNull();
    });

    it("keeps a partial first row stable and handles an empty replacement", () => {
      const layout = buildMessageLayout(["a", "b"], new Map(), 100, 24);
      expect(captureMessageAnchor(layout, -40)).toEqual({ id: "a", offset: -40 });
      expect(captureMessageAnchor(buildMessageLayout([], new Map()), 0)).toBeNull();
      expect(selectMessageWindow(buildMessageLayout([], new Map()), 0, 600, {
        overscan: 600, tail: 8, pinnedIds: new Set(["old"]),
      })).toEqual([]);
    });

    it("does not drift after repeating the same measurement and anchor correction", () => {
      const ids = Array.from({ length: 200 }, (_, i) => `m${i}`);
      const heights = new Map<string, number>();
      let layout = buildMessageLayout(ids, heights, 120, 24);
      let top = 100 * 144 + 17;
      for (let pass = 0; pass < 30; pass++) {
        const anchor = captureMessageAnchor(layout, top);
        heights.set("m90", 310.25);
        heights.set("m99", 55.5);
        layout = buildMessageLayout(ids, heights, 120, 24);
        top = restoreMessageAnchor(layout, anchor)!;
        expect(captureMessageAnchor(layout, top)).toEqual({ id: "m100", offset: 17 });
      }
    });
  });

  it("always mounts the tail even with nothing near the viewport", () => {
    // 尾部必须无条件挂载:流式输出和输入框邻近区域不能依赖观察器时序。
    expect(selectMountedMessageIds(ids, new Set(), { tail: 3 })).toEqual(
      new Set(["f", "g", "h"]),
    );
  });

  it("mounts the near-viewport set in addition to the tail", () => {
    expect(
      selectMountedMessageIds(ids, new Set(["b", "c"]), { tail: 2 }),
    ).toEqual(new Set(["b", "c", "g", "h"]));
  });

  it("force-mounts the message being edited even when far away", () => {
    // 正在编辑的消息若被卸载,输入焦点和草稿都会丢。
    expect(
      selectMountedMessageIds(ids, new Set(), { tail: 2, editingId: "a" }),
    ).toEqual(new Set(["a", "g", "h"]));
  });

  it("ignores visible ids that are no longer in the thread", () => {
    // 消息被删除/历史被替换后,观察器可能仍持有旧 id。
    expect(
      selectMountedMessageIds(ids, new Set(["zzz"]), { tail: 1 }),
    ).toEqual(new Set(["h"]));
  });

  it("ignores an editingId that is no longer in the thread", () => {
    expect(
      selectMountedMessageIds(ids, new Set(), { tail: 1, editingId: "gone" }),
    ).toEqual(new Set(["h"]));
  });

  it("handles an empty thread", () => {
    expect(selectMountedMessageIds([], new Set(), { tail: 5 })).toEqual(
      new Set(),
    );
  });

  it("treats a non-positive tail as no forced tail", () => {
    expect(selectMountedMessageIds(ids, new Set(["c"]), { tail: 0 })).toEqual(
      new Set(["c"]),
    );
  });
});
