"use client";

import {
  createContext,
  memo,
  useCallback,
  useContext,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type ComponentType,
  type RefObject,
} from "react";
import {
  ThreadPrimitive,
  unstable_useThreadMessageIds,
  useAuiState,
} from "@assistant-ui/react";
import {
  buildMessageLayout,
  captureMessageAnchor,
  findMessageIndex,
  restoreMessageAnchor,
  selectMessageWindow,
  type MessageAnchor,
} from "./message-window";

const MESSAGE_GAP = 24;
const SMALL_THREAD = 60;
const TAIL_MOUNTED = 8;
const noop = () => {};

type WindowProps = {
  children: ComponentType;
  viewportRef: RefObject<HTMLDivElement | null>;
  followingRef: RefObject<boolean>;
  onScrollCorrection?: () => void;
  onVisibleMessageChange?: (index: number) => void;
};

const MessageContext = createContext<{
  Message: ComponentType;
  pinEditing: (id: string, editing: boolean) => void;
} | null>(null);

const WindowMessage = () => {
  const context = useContext(MessageContext);
  if (!context) throw new Error("WindowMessage requires a message window");
  const id = useAuiState((s) => s.message.id);
  const editing = useAuiState((s) => s.message.composer.isEditing);
  const { Message, pinEditing } = context;
  useLayoutEffect(() => {
    pinEditing(id, editing);
    return () => pinEditing(id, false);
  }, [id, editing, pinEditing]);
  return <Message />;
};
const MESSAGE_COMPONENTS = { Message: WindowMessage };

export const scrollViewportInstant = (viewport: HTMLDivElement, top: number) => {
  const previous = viewport.style.scrollBehavior;
  viewport.style.scrollBehavior = "auto";
  viewport.scrollTop = top;
  viewport.style.scrollBehavior = previous;
};

const MessageRow = memo(({
  id, index, last, register,
}: {
  id: string;
  index: number;
  last: boolean;
  register: (id: string, element: HTMLDivElement | null) => void;
}) => {
  const ref = useCallback((element: HTMLDivElement | null) => register(id, element), [id, register]);
  return (
    <div
      ref={ref}
      data-slot="aui_message-slot"
      data-message-id={id}
      data-message-index={index}
      style={{ display: "flow-root", paddingBottom: last ? 0 : MESSAGE_GAP }}
    >
      <ThreadPrimitive.Unstable_MessageById messageId={id} components={MESSAGE_COMPONENTS} />
    </div>
  );
});
MessageRow.displayName = "VirtualizedMessageRow";

const MessageWindow = memo(({
  ids, children: Message, viewportRef, followingRef,
  onScrollCorrection = noop, onVisibleMessageChange = noop,
}: WindowProps & { ids: readonly string[] }) => {
  const listRef = useRef<HTMLDivElement>(null);
  const rowsRef = useRef(new Map<string, HTMLDivElement>());
  const observerRef = useRef<ResizeObserver | null>(null);
  const heightsRef = useRef(new Map<string, number>());
  const anchorRef = useRef<MessageAnchor | null>(null);
  const listTopRef = useRef(0);
  const [heightRevision, setHeightRevision] = useState(0);
  const [view, setView] = useState({ top: 0, height: 600 });
  const [editingIds, setEditingIds] = useState<ReadonlySet<string>>(() => new Set());
  const [focusedId, setFocusedId] = useState<string | null>(null);
  const layout = useMemo(
    () => buildMessageLayout(ids, heightsRef.current, 120, MESSAGE_GAP),
    [ids, heightRevision],
  );
  const layoutRef = useRef(layout);
  const anchor = layout !== layoutRef.current ? anchorRef.current : null;
  const windowTop = restoreMessageAnchor(layout, anchor) ?? view.top;
  const items = useMemo(() => {
    const pinnedIds = new Set(editingIds);
    if (focusedId) pinnedIds.add(focusedId);
    // Select the corrected window before React can unmount the reading anchor.
    if (anchor) pinnedIds.add(anchor.id);
    return selectMessageWindow(layout, windowTop, view.height, {
      overscan: ids.length <= SMALL_THREAD
        ? Number.POSITIVE_INFINITY : Math.min(300, view.height / 2),
      tail: TAIL_MOUNTED,
      pinnedIds,
    });
  }, [layout, windowTop, view.height, ids.length, editingIds, focusedId, anchor]);

  const pinEditing = useCallback((id: string, editing: boolean) => {
    setEditingIds((previous) => {
      if (previous.has(id) === editing) return previous;
      const next = new Set(previous);
      if (editing) next.add(id);
      else next.delete(id);
      return next;
    });
  }, []);
  const context = useMemo(() => ({ Message, pinEditing }), [Message, pinEditing]);

  const updateViewport = useCallback(() => {
    const viewport = viewportRef.current;
    const list = listRef.current;
    if (!viewport || !list) return;
    const listTop = list.getBoundingClientRect().top -
      viewport.getBoundingClientRect().top + viewport.scrollTop;
    listTopRef.current = listTop;
    const top = viewport.scrollTop - listTop;
    const height = viewport.clientHeight;
    anchorRef.current = captureMessageAnchor(layoutRef.current, top);
    setView((previous) => previous.top === top && previous.height === height
      ? previous : { top, height });
    onVisibleMessageChange(findMessageIndex(layoutRef.current, top + 40));
  }, [viewportRef, onVisibleMessageChange]);

  const correctScroll = useCallback(() => {
    const viewport = viewportRef.current;
    const list = listRef.current;
    if (!viewport || !list || viewport.clientWidth === 0) return;
    const listTop = list.getBoundingClientRect().top -
      viewport.getBoundingClientRect().top + viewport.scrollTop;
    const restored = restoreMessageAnchor(layoutRef.current, anchorRef.current);
    const target = followingRef.current
      ? viewport.scrollHeight - viewport.clientHeight
      : restored === null ? viewport.scrollTop : listTop + restored;
    if (Math.abs(viewport.scrollTop - Math.max(0, target)) > 0.5) {
      scrollViewportInstant(viewport, target);
      onScrollCorrection();
    }
    updateViewport();
  }, [viewportRef, followingRef, onScrollCorrection, updateViewport]);

  const register = useCallback((id: string, element: HTMLDivElement | null) => {
    const previous = rowsRef.current.get(id);
    if (previous) observerRef.current?.unobserve(previous);
    if (element) {
      rowsRef.current.set(id, element);
      observerRef.current?.observe(element);
    } else {
      rowsRef.current.delete(id);
    }
  }, []);

  const measureRows = useCallback(() => {
    let changed = false;
    for (const [id, element] of rowsRef.current) {
      if (!element.isConnected) continue;
      const rect = element.getBoundingClientRect();
      if (rect.width === 0) continue;
      const height = Math.max(0, rect.height - Number.parseFloat(element.style.paddingBottom || "0"));
      const previous = heightsRef.current.get(id);
      if (previous === undefined || Math.abs(height - previous) > 0.5) {
        heightsRef.current.set(id, height);
        changed = true;
      }
    }
    if (changed) setHeightRevision((revision) => revision + 1);
    return changed;
  }, []);

  useLayoutEffect(() => {
    layoutRef.current = layout;
    for (const id of heightsRef.current.keys()) {
      if (!layout.indexById.has(id)) heightsRef.current.delete(id);
    }
    correctScroll();
  }, [layout, correctScroll]);

  useLayoutEffect(() => {
    measureRows();
  }, [items, measureRows]);

  // Ancestor DOM refs are attached after child layout effects.
  useEffect(() => {
    const viewport = viewportRef.current;
    if (!viewport) return;
    let frame: number | null = null;
    let resizePending = false;
    let width = viewport.clientWidth;
    const schedule = (resize: boolean) => {
      resizePending ||= resize;
      if (frame !== null) return;
      frame = window.requestAnimationFrame(() => {
        frame = null;
        const resized = resizePending;
        resizePending = false;
        if (resized) {
          const nextWidth = viewport.clientWidth;
          if (nextWidth > 0 && nextWidth !== width) {
            heightsRef.current.clear();
            width = nextWidth;
          }
          if (measureRows()) return;
          correctScroll();
        } else {
          updateViewport();
        }
      });
    };
    const onScroll = () => {
      anchorRef.current = captureMessageAnchor(
        layoutRef.current, viewport.scrollTop - listTopRef.current,
      );
      schedule(false);
    };
    viewport.addEventListener("scroll", onScroll, { passive: true });
    const observer = typeof ResizeObserver === "undefined"
      ? null : new ResizeObserver(() => schedule(true));
    observerRef.current = observer;
    observer?.observe(viewport);
    const containers = new Set<Element>();
    const observeContainers = () => {
      for (const element of containers) {
        if (element.parentElement !== viewport) {
          observer?.unobserve(element);
          containers.delete(element);
        }
      }
      for (const element of viewport.children) {
        if (!containers.has(element)) observer?.observe(element);
        containers.add(element);
      }
      schedule(true);
    };
    observeContainers();
    const childrenObserver = new MutationObserver(observeContainers);
    childrenObserver.observe(viewport, { childList: true });
    for (const element of rowsRef.current.values()) observer?.observe(element);
    return () => {
      if (frame !== null) window.cancelAnimationFrame(frame);
      viewport.removeEventListener("scroll", onScroll);
      childrenObserver.disconnect();
      observer?.disconnect();
      observerRef.current = null;
    };
  }, [viewportRef, updateViewport, correctScroll, measureRows]);

  return (
    <MessageContext.Provider value={context}>
      <div
        ref={listRef}
        data-slot="aui_virtualized-messages"
        data-message-count={ids.length}
        style={{ display: "flow-root", overflowAnchor: "none" }}
        onFocusCapture={(event) => {
          if (!(event.target instanceof HTMLElement)) return;
          setFocusedId(event.target.closest<HTMLElement>("[data-message-id]")?.dataset.messageId ?? null);
        }}
        onBlurCapture={(event) => {
          if (event.relatedTarget instanceof Node && event.currentTarget.contains(event.relatedTarget)) return;
          setFocusedId(null);
        }}
      >
        {items.map((item) => item.type === "spacer" ? (
          <div
            key={`spacer-${item.id}`}
            data-slot="aui_message-spacer"
            aria-hidden="true"
            style={{ height: item.height }}
          />
        ) : (
          <MessageRow
            key={item.id}
            id={item.id}
            index={item.index}
            last={item.index === ids.length - 1}
            register={register}
          />
        ))}
      </div>
    </MessageContext.Provider>
  );
});
MessageWindow.displayName = "MessageWindow";

// Keep the experimental upstream API and thread-scoped height cache in one adapter.
export const VirtualizedMessages = memo((props: WindowProps) => {
  const ids = unstable_useThreadMessageIds();
  const threadId = useAuiState((s) => s.threads.mainThreadId);
  if (ids.length === 0) return null;
  return <MessageWindow key={threadId} {...props} ids={ids} />;
});
VirtualizedMessages.displayName = "VirtualizedMessages";
