export type MessageWindowOptions = {
  /** 末尾无条件挂载的条数:流式输出与输入框邻近区域不能依赖观察器时序。 */
  tail: number;
  /** 正在编辑的消息 id;若被卸载会丢失焦点与草稿,故强制挂载。 */
  editingId?: string | undefined;
};

/**
 * 算出应当真正挂载的消息 id 集合。
 *
 * 传入的 `visibleIds`(观察器认为在视口附近)与 `editingId` 都可能已经不在
 * 当前线程里 —— 历史被替换、消息被删除时观察器仍会持有旧 id —— 一律按
 * 当前 `ids` 过滤,避免把不存在的消息塞进挂载集合。
 */
export const selectMountedMessageIds = (
  ids: readonly string[],
  visibleIds: ReadonlySet<string>,
  { tail, editingId }: MessageWindowOptions,
): Set<string> => {
  const present = new Set(ids);
  const mounted = new Set<string>();

  if (tail > 0) {
    for (const id of ids.slice(Math.max(0, ids.length - tail))) mounted.add(id);
  }
  for (const id of visibleIds) if (present.has(id)) mounted.add(id);
  if (editingId !== undefined && present.has(editingId)) mounted.add(editingId);

  return mounted;
};

export type MessageLayout = {
  ids: readonly string[];
  offsets: readonly number[];
  indexById: ReadonlyMap<string, number>;
};

export type MessageAnchor = { id: string; offset: number };

export type MessageWindowItem =
  | { type: "message"; id: string; index: number }
  | { type: "spacer"; id: string; height: number };

export const buildMessageLayout = (
  ids: readonly string[],
  heights: ReadonlyMap<string, number>,
  estimate = 120,
  gap = 24,
): MessageLayout => {
  const offsets = [0];
  const indexById = new Map<string, number>();
  ids.forEach((id, index) => {
    indexById.set(id, index);
    offsets.push(offsets[index]! + (heights.get(id) ?? estimate) +
      (index < ids.length - 1 ? gap : 0));
  });
  return { ids, offsets, indexById };
};

export const findMessageIndex = (layout: MessageLayout, offset: number): number => {
  if (offset < 0 || layout.ids.length === 0) return -1;
  let low = 0;
  let high = layout.ids.length;
  while (low < high) {
    const middle = (low + high) >>> 1;
    if (layout.offsets[middle]! <= offset) low = middle + 1;
    else high = middle;
  }
  return low - 1;
};

export const captureMessageAnchor = (
  layout: MessageLayout,
  offset: number,
): MessageAnchor | null => {
  if (layout.ids.length === 0) return null;
  const index = Math.max(0, findMessageIndex(layout, offset));
  return { id: layout.ids[index]!, offset: offset - layout.offsets[index]! };
};

export const restoreMessageAnchor = (
  layout: MessageLayout,
  anchor: MessageAnchor | null,
): number | null => {
  if (!anchor) return null;
  const index = layout.indexById.get(anchor.id);
  return index === undefined ? null : layout.offsets[index]! + anchor.offset;
};

export const selectMessageWindow = (
  layout: MessageLayout,
  top: number,
  viewportHeight: number,
  { overscan, tail, pinnedIds }: {
    overscan: number;
    tail: number;
    pinnedIds: ReadonlySet<string>;
  },
): MessageWindowItem[] => {
  const { ids, offsets } = layout;
  if (ids.length === 0) return [];
  const start = Math.max(0, findMessageIndex(layout, top - overscan));
  const end = Math.max(start, findMessageIndex(layout, top + viewportHeight + overscan));
  const visible = new Set(ids.slice(start, end + 1));
  for (const id of pinnedIds) visible.add(id);
  const mounted = selectMountedMessageIds(ids, visible, { tail });
  const items: MessageWindowItem[] = [];
  let previousEnd = 0;
  ids.forEach((id, index) => {
    if (!mounted.has(id)) return;
    if (offsets[index]! > previousEnd) {
      items.push({ type: "spacer", id: `before-${id}`, height: offsets[index]! - previousEnd });
    }
    items.push({ type: "message", id, index });
    previousEnd = offsets[index + 1]!;
  });
  const total = offsets[ids.length]!;
  if (total > previousEnd) {
    items.push({ type: "spacer", id: "after-last", height: total - previousEnd });
  }
  return items;
};
