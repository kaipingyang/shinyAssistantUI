"use client";

import {
  useCallback,
  useState,
  type ButtonHTMLAttributes,
  type FC,
  type PropsWithChildren,
} from "react";
import { PanelLeftClose, PanelLeftOpen } from "lucide-react";
import { cn } from "@/lib/utils";

function readCollapsed(storageKey?: string): boolean {
  if (!storageKey) return false;
  try {
    return localStorage.getItem(storageKey) === "1";
  } catch {
    return false;
  }
}

/** Collapse state for the thread-list sidebar, optionally persisted (client mode). */
export function useSidebarCollapse(storageKey?: string) {
  const [collapsed, setCollapsed] = useState(() => readCollapsed(storageKey));
  const toggle = useCallback(() => {
    setCollapsed((current) => {
      const next = !current;
      if (storageKey) {
        try {
          localStorage.setItem(storageKey, next ? "1" : "0");
        } catch {
          /* storage disabled — keep in-memory only */
        }
      }
      return next;
    });
  }, [storageKey]);
  return { collapsed, toggle };
}

/**
 * Collapse/expand toggle. Rendered inside the sidebar when expanded, and inside
 * the main panel when collapsed (so a collapsed sidebar leaves no leftover rail).
 */
export const SidebarToggleButton: FC<
  { collapsed: boolean; onToggle: () => void } & Omit<
    ButtonHTMLAttributes<HTMLButtonElement>,
    "onClick" | "type"
  >
> = ({ collapsed, onToggle, className, ...rest }) => (
  <button
    type="button"
    onClick={onToggle}
    aria-label={collapsed ? "展开侧边栏" : "收起侧边栏"}
    title={collapsed ? "展开侧边栏" : "收起侧边栏"}
    data-slot="aui_sidebar_toggle"
    className={cn(
      "text-muted-foreground hover:bg-accent hover:text-accent-foreground flex size-7 shrink-0 items-center justify-center rounded-md transition-colors",
      className,
    )}
    {...rest}
  >
    {collapsed ? (
      <PanelLeftOpen className="size-4" />
    ) : (
      <PanelLeftClose className="size-4" />
    )}
  </button>
);

/**
 * Expanded thread-list sidebar. Renders nothing when collapsed — the caller
 * shows an expand button in the main panel instead, so no narrow leftover rail
 * remains. Editing 10 files and popping them all open helps no one; same spirit:
 * fully get out of the way when collapsed.
 */
export const ThreadSidebar: FC<
  PropsWithChildren<{ collapsed: boolean; onToggle: () => void }>
> = ({ collapsed, onToggle, children }) => {
  if (collapsed) return null;
  return (
    <div
      data-slot="aui_thread_sidebar"
      data-collapsed="false"
      className="aui-thread-list-sidebar relative flex w-56 shrink-0 flex-col overflow-hidden border-r p-2"
    >
      <SidebarToggleButton collapsed={false} onToggle={onToggle} className="mb-1 self-end" />
      {children}
    </div>
  );
};
