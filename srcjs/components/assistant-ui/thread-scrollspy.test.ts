import { describe, expect, it } from "vitest";
import { selectActiveQuestionIndex } from "./thread";

// scroll-spy 的选择逻辑:顶部条显示"当前视口所在那一轮"的用户提问。
// 原实现靠对每条 user 消息调 getBoundingClientRect() 判断是否越过阈值线,
// 那会在每次 ResizeObserver 触发时强制同步布局(2294 节点时 30ms)。
// 这里把"给定每条消息是否已越线 -> 选哪一条"抽成纯函数,
// 供 IntersectionObserver 版本复用,并锁定与原实现一致的语义。
describe("selectActiveQuestionIndex", () => {
  it("returns -1 when no question has crossed the threshold line", () => {
    expect(selectActiveQuestionIndex([false, false, false])).toBe(-1);
  });

  it("returns the last question that crossed the line", () => {
    // 原实现是 forEach 里不断覆盖 idx,因此取的是"最后一个越线的"。
    expect(selectActiveQuestionIndex([true, true, false, false])).toBe(1);
  });

  it("returns the final index when every question is above the line", () => {
    expect(selectActiveQuestionIndex([true, true, true])).toBe(2);
  });

  it("handles an empty thread", () => {
    expect(selectActiveQuestionIndex([])).toBe(-1);
  });

  it("tolerates a non-contiguous crossing set by taking the last true", () => {
    // 滚动过程中 IntersectionObserver 的回调可能乱序到达,
    // 选择逻辑必须只依赖最终状态,不依赖到达顺序。
    expect(selectActiveQuestionIndex([true, false, true, false])).toBe(2);
  });
});
