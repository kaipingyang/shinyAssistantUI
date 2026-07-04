import { describe, it, expect, beforeEach, vi } from "vitest";
import {
  registerApprovalHandler, unregisterApprovalHandler,
  resolveApprovalHandler, _clearApprovalHandlers,
} from "./approval-registry";

beforeEach(() => _clearApprovalHandlers());

describe("approval-registry — 多 widget 隔离（HIGH 修复核心）", () => {
  it("按 inputId 路由到对应 handler", () => {
    const a = vi.fn();
    const b = vi.fn();
    registerApprovalHandler("chatA", a);
    registerApprovalHandler("chatB", b);
    resolveApprovalHandler("chatA")?.("tc1", true);
    expect(a).toHaveBeenCalledWith("tc1", true);
    expect(b).not.toHaveBeenCalled();
    resolveApprovalHandler("chatB")?.("tc2", false);
    expect(b).toHaveBeenCalledWith("tc2", false);
  });

  it("后注册 widget 不覆盖前者（修复前单例串台的根因）", () => {
    const a = vi.fn();
    const b = vi.fn();
    registerApprovalHandler("chatA", a);
    registerApprovalHandler("chatB", b); // 修复前：会覆盖单例
    // A 的审批仍路由到 A，不串到 B
    resolveApprovalHandler("chatA")?.("tc", true);
    expect(a).toHaveBeenCalledTimes(1);
    expect(b).toHaveBeenCalledTimes(0);
  });

  it("单 widget 缺 inputId 时 fallback 到唯一 handler", () => {
    const a = vi.fn();
    registerApprovalHandler("chatA", a);
    resolveApprovalHandler(undefined)?.("tc", true); // card 未拿到 inputId
    expect(a).toHaveBeenCalled();
  });

  it("多 widget 缺 inputId 时返回 null（不猜、不串台）", () => {
    registerApprovalHandler("chatA", vi.fn());
    registerApprovalHandler("chatB", vi.fn());
    expect(resolveApprovalHandler(undefined)).toBeNull();
  });

  it("未知 inputId 返回 null（多 widget，不 fallback）", () => {
    registerApprovalHandler("chatA", vi.fn());
    registerApprovalHandler("chatB", vi.fn());
    expect(resolveApprovalHandler("ghost")).toBeNull();
  });

  it("卸载只删自己，不影响其它 widget", () => {
    const a = vi.fn();
    const b = vi.fn();
    const c = vi.fn();
    registerApprovalHandler("chatA", a);
    registerApprovalHandler("chatB", b);
    registerApprovalHandler("chatC", c);
    unregisterApprovalHandler("chatA"); // A 卸载
    // B/C 仍各自可用（修复前 cleanup 无条件 =null 会误清全部）
    resolveApprovalHandler("chatB")?.("tc", true);
    resolveApprovalHandler("chatC")?.("tc", true);
    expect(b).toHaveBeenCalled();
    expect(c).toHaveBeenCalled();
    // A 已删，且仍有多个 handler → 精确查 chatA 返回 null（不 fallback）
    expect(resolveApprovalHandler("chatA")).toBeNull();
  });

  it("卸载到只剩一个时，未知 inputId 会 fallback（单 widget 兼容，故意行为）", () => {
    const a = vi.fn();
    const b = vi.fn();
    registerApprovalHandler("chatA", a);
    registerApprovalHandler("chatB", b);
    unregisterApprovalHandler("chatA");
    // 只剩 chatB → 查已卸载的 chatA 会 fallback 到唯一的 B（size===1）
    // 真实中 chatA widget 已卸载，其卡片也随之消失，不会再有 A 的审批，故无害
    resolveApprovalHandler("chatA")?.("tc", true);
    expect(b).toHaveBeenCalled();
  });

  it("空注册表返回 null", () => {
    expect(resolveApprovalHandler("any")).toBeNull();
    expect(resolveApprovalHandler(undefined)).toBeNull();
  });

  it("重注册同 inputId 覆盖（React re-render 更新 sendToolApproval）", () => {
    const a1 = vi.fn();
    const a2 = vi.fn();
    registerApprovalHandler("chatA", a1);
    registerApprovalHandler("chatA", a2); // 同 inputId 更新
    resolveApprovalHandler("chatA")?.("tc", true);
    expect(a1).not.toHaveBeenCalled();
    expect(a2).toHaveBeenCalled();
  });
});
