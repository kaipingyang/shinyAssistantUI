// Tool 审批 handler 注册表（模块级 Map，避免 React context tree 依赖）。
// ToolFallback 由 @assistant-ui 渲染，位置可能在独立 React 树里，context 不可靠。
// 用 Map<inputId, handler> 而非单例，避免多 widget 同页时后挂载者覆盖前者导致
// 审批路由串台 / 死锁。card 经 annotations.inputId 定位本实例的 handler；
// 单 widget 场景（map.size===1）缺 inputId 时 fallback 到唯一项，保持向后兼容。
export type ToolApprovalFn = (
  id: string,
  approved: boolean,
  opts?: { suggestionIdx?: number; suggestionIdxs?: number[]; customMessage?: string },
) => void;

const _handlers = new Map<string, ToolApprovalFn>();

export function registerApprovalHandler(inputId: string, fn: ToolApprovalFn): void {
  _handlers.set(inputId, fn);
}

export function unregisterApprovalHandler(inputId: string): void {
  _handlers.delete(inputId);
}

export function resolveApprovalHandler(inputId?: string): ToolApprovalFn | null {
  if (inputId && _handlers.has(inputId)) return _handlers.get(inputId)!;
  if (_handlers.size === 1) return _handlers.values().next().value ?? null;
  return null;
}

// 仅供测试：清空注册表
export function _clearApprovalHandlers(): void {
  _handlers.clear();
}
