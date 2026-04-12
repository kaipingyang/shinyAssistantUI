import React, { useState, useRef, useEffect } from "react";
import { AssistantRuntimeProvider } from "@assistant-ui/core/react";
import { Thread, ThreadList } from "@assistant-ui/react-ui";
import { ThreadListItemPrimitive, ThreadListPrimitive } from "@assistant-ui/react";
import type { ToolCallMessagePartProps } from "@assistant-ui/react";
import {
  PanelLeftCloseIcon, PanelLeftOpenIcon, ArchiveIcon,
  Trash2Icon, MoreHorizontalIcon, WrenchIcon, ChevronDownIcon, ChevronRightIcon,
} from "lucide-react";
import "@assistant-ui/react-ui/styles/index.css";
import { useShinyRuntime } from "./runtime";

// ── 自定义 ThreadListItem：hover 时显示三点菜单 ──────────────────────────────
function CustomThreadListItem() {
  const [hovered, setHovered] = useState(false);
  const [menuOpen, setMenuOpen] = useState(false);
  const menuRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!menuOpen) return;
    const handler = (e: MouseEvent) => {
      if (menuRef.current && !menuRef.current.contains(e.target as Node)) {
        setMenuOpen(false);
      }
    };
    document.addEventListener("mousedown", handler);
    return () => document.removeEventListener("mousedown", handler);
  }, [menuOpen]);

  return (
    <ThreadListItemPrimitive.Root
      className="aui-thread-list-item"
      onMouseEnter={() => setHovered(true)}
      onMouseLeave={() => { setHovered(false); }}
      style={{ position: "relative" }}
    >
      <ThreadListItemPrimitive.Trigger
        className="aui-thread-list-item-trigger"
        style={{ flex: 1, minWidth: 0 }}
      >
        <p className="aui-thread-list-item-title" style={{ margin: 0 }}>
          <ThreadListItemPrimitive.Title fallback="New Chat" />
        </p>
      </ThreadListItemPrimitive.Trigger>

      {/* 三点按钮：hover 或菜单打开时显示 */}
      <div
        ref={menuRef}
        style={{
          position: "relative",
          flexShrink: 0,
          visibility: hovered || menuOpen ? "visible" : "hidden",
        }}
      >
        <button
          onClick={(e) => { e.stopPropagation(); setMenuOpen((v) => !v); }}
          style={{
            background: "none",
            border: "none",
            cursor: "pointer",
            padding: "2px 4px",
            borderRadius: "4px",
            color: "var(--aui-muted-foreground, #6b7280)",
            display: "flex",
            alignItems: "center",
          }}
          title="More options"
        >
          <MoreHorizontalIcon size={14} />
        </button>

        {/* 下拉菜单 */}
        {menuOpen && (
          <div style={{
            position: "absolute",
            right: 0,
            top: "calc(100% + 4px)",
            zIndex: 100,
            background: "var(--aui-background, white)",
            border: "1px solid var(--aui-border, #e5e7eb)",
            borderRadius: "6px",
            boxShadow: "0 4px 12px rgba(0,0,0,0.12)",
            minWidth: "140px",
            padding: "4px",
          }}>
            <ThreadListItemPrimitive.Archive
              onClick={() => setMenuOpen(false)}
              style={{
                display: "flex",
                alignItems: "center",
                gap: "8px",
                width: "100%",
                padding: "6px 10px",
                background: "none",
                border: "none",
                cursor: "pointer",
                borderRadius: "4px",
                fontSize: "13px",
                textAlign: "left",
                color: "var(--aui-foreground, #111827)",
              }}
            >
              <ArchiveIcon size={13} />
              Archive
            </ThreadListItemPrimitive.Archive>

            <ThreadListItemPrimitive.Delete
              onClick={() => setMenuOpen(false)}
              style={{
                display: "flex",
                alignItems: "center",
                gap: "8px",
                width: "100%",
                padding: "6px 10px",
                background: "none",
                border: "none",
                cursor: "pointer",
                borderRadius: "4px",
                fontSize: "13px",
                textAlign: "left",
                color: "#ef4444",
              }}
            >
              <Trash2Icon size={13} />
              Delete
            </ThreadListItemPrimitive.Delete>
          </div>
        )}
      </div>
    </ThreadListItemPrimitive.Root>
  );
}

// ── 通用 Tool Call 卡片 ──────────────────────────────────────────────────────
function GenericToolCard({ toolName, argsText, args, result, isError }: ToolCallMessagePartProps) {
  const [open, setOpen] = useState(false);
  const pending = result === undefined;
  // Shiny 可能把 json class 对象内联序列化，做防御性 stringify
  const argsDisplay = typeof argsText === "string"
    ? argsText
    : JSON.stringify(args ?? argsText, null, 2);
  const resultDisplay = result === undefined ? ""
    : typeof result === "string" ? result
    : JSON.stringify(result, null, 2);

  return (
    <div style={{
      border: "1px solid var(--aui-border, #e5e7eb)",
      borderRadius: "8px",
      fontSize: "13px",
      overflow: "hidden",
      marginBottom: "4px",
      background: "var(--aui-background, #fff)",
    }}>
      {/* 头部：工具名 + 状态 */}
      <button
        onClick={() => setOpen((v) => !v)}
        style={{
          width: "100%", display: "flex", alignItems: "center", gap: "6px",
          padding: "6px 10px", background: "none", border: "none",
          cursor: "pointer", textAlign: "left",
          color: "var(--aui-foreground, #111827)",
        }}
      >
        <WrenchIcon size={13} style={{ flexShrink: 0, color: "#6b7280" }} />
        <span style={{ fontWeight: 500, flex: 1 }}>{toolName}</span>
        <span style={{
          fontSize: "11px", padding: "1px 6px", borderRadius: "999px",
          background: pending ? "#fef9c3" : isError ? "#fee2e2" : "#dcfce7",
          color: pending ? "#854d0e" : isError ? "#991b1b" : "#166534",
        }}>
          {pending ? "running…" : isError ? "error" : "done"}
        </span>
        {open ? <ChevronDownIcon size={13} /> : <ChevronRightIcon size={13} />}
      </button>

      {/* 展开：参数 + 结果 */}
      {open && (
        <div style={{ borderTop: "1px solid var(--aui-border, #e5e7eb)", padding: "8px 10px" }}>
          <div style={{ color: "#6b7280", marginBottom: "4px", fontSize: "11px" }}>Arguments</div>
          <pre style={{
            margin: 0, padding: "6px 8px", borderRadius: "4px",
            background: "#f9fafb", fontSize: "12px", overflowX: "auto",
            whiteSpace: "pre-wrap", wordBreak: "break-all",
          }}>
            {argsDisplay}
          </pre>
          {result !== undefined && (
            <>
              <div style={{ color: "#6b7280", marginTop: "8px", marginBottom: "4px", fontSize: "11px" }}>
                Result
              </div>
              <pre style={{
                margin: 0, padding: "6px 8px", borderRadius: "4px",
                background: isError ? "#fef2f2" : "#f9fafb",
                color: isError ? "#991b1b" : undefined,
                fontSize: "12px", overflowX: "auto",
                whiteSpace: "pre-wrap", wordBreak: "break-all",
              }}>
                {resultDisplay}
              </pre>
            </>
          )}
        </div>
      )}
    </div>
  );
}

// ── 侧边栏（不含折叠按钮）───────────────────────────────────────────────────
function ThreadListSidebar() {
  return (
    <div style={{ height: "100%", overflow: "auto", background: "hsl(0, 0%, 98%)" }}>
      <ThreadListPrimitive.Root className="aui-root aui-thread-list-root">
        <ThreadList.New />
        <ThreadList.Items components={{ ThreadListItem: CustomThreadListItem }} />
      </ThreadListPrimitive.Root>
    </div>
  );
}

// ── 主组件 ──────────────────────────────────────────────────────────────────
interface AssistantUIProps {
  inputId: string;
  config: Record<string, unknown>;
}

export default function AssistantUI({ inputId, config }: AssistantUIProps) {
  const runtime = useShinyRuntime(inputId, config);
  const showThreadList = config?.show_thread_list === true;
  const [sidebarOpen, setSidebarOpen] = useState(true);

  return (
    <AssistantRuntimeProvider runtime={runtime}>
      <div style={{ display: "flex", height: "100%" }}>

        {/* 侧边栏 */}
        {showThreadList && (
          <div style={{
            width: sidebarOpen ? 220 : 0,
            minWidth: sidebarOpen ? 220 : 0,
            overflow: "hidden",
            flexShrink: 0,
            transition: "width 0.15s ease, min-width 0.15s ease",
          }}>
            {sidebarOpen && <ThreadListSidebar />}
          </div>
        )}

        {/* 侧边栏和主栏之间无分隔线，靠背景色差区分（同 shadcn/ui sidebar） */}

        {/* 主聊天区 */}
        <div style={{ flex: 1, minWidth: 0, display: "flex", flexDirection: "column" }}>

          {/* 折叠按钮放在主栏顶部 */}
          {showThreadList && (
            <div style={{ padding: "6px 8px", flexShrink: 0 }}>
              <button
                onClick={() => setSidebarOpen((v) => !v)}
                title={sidebarOpen ? "Hide sidebar" : "Show sidebar"}
                style={{
                  background: "none",
                  border: "none",
                  cursor: "pointer",
                  padding: "4px",
                  borderRadius: "4px",
                  color: "var(--aui-muted-foreground, #6b7280)",
                  display: "flex",
                  alignItems: "center",
                }}
              >
                {sidebarOpen
                  ? <PanelLeftCloseIcon size={16} />
                  : <PanelLeftOpenIcon size={16} />
                }
              </button>
            </div>
          )}

          <div style={{
            flex: 1,
            minHeight: 0,
            "--aui-thread-max-width": "9999px",
          } as React.CSSProperties}>
            <Thread
              assistantMessage={{
                components: { ToolFallback: GenericToolCard },
              }}
            />
          </div>
        </div>

      </div>
    </AssistantRuntimeProvider>
  );
}
