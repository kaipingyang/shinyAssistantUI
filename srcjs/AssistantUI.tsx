import React, { useState, useRef, useEffect, useMemo, createContext, useContext } from "react";
import { AssistantRuntimeProvider } from "@assistant-ui/core/react";
import { Thread, ThreadList } from "@assistant-ui/react-ui";
import {
  ThreadListItemPrimitive, ThreadListPrimitive, makeAssistantToolUI,
  ComposerPrimitive,
  unstable_useToolMentionAdapter,
  unstable_useSlashCommandAdapter,
  useThreadRuntime,
} from "@assistant-ui/react";
import { unstable_defaultDirectiveFormatter } from "@assistant-ui/core";
import type { ToolCallMessagePartProps } from "@assistant-ui/react";
import type { CreateAppendMessage } from "@assistant-ui/core";
import {
  PanelLeftCloseIcon, PanelLeftOpenIcon, ArchiveIcon, Trash2Icon,
  MoreHorizontalIcon, WrenchIcon, ChevronDownIcon, ChevronRightIcon,
  AlertCircleIcon, CheckCircle2Icon, DropletIcon, WindIcon,
  CloudSunIcon, CalculatorIcon, SearchIcon, DatabaseIcon,
  CodeIcon, GlobeIcon, ZapIcon, TerminalIcon, FlaskConicalIcon,
} from "lucide-react";
import type { ComponentType } from "react";

// ── lucide 图标名称映射（供 tool_annotations(icon=...) 使用）─────────────────
type IconComponent = ComponentType<{ size?: number; color?: string; style?: React.CSSProperties }>;
const TOOL_ICONS: Record<string, IconComponent> = {
  "cloud-sun":     CloudSunIcon,
  "calculator":    CalculatorIcon,
  "search":        SearchIcon,
  "database":      DatabaseIcon,
  "code":          CodeIcon,
  "globe":         GlobeIcon,
  "zap":           ZapIcon,
  "terminal":      TerminalIcon,
  "flask":         FlaskConicalIcon,
  "wrench":        WrenchIcon,
};
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

// ── 天气卡片 helpers ──────────────────────────────────────────────────────────
function weatherGradient(condition: string): string {
  const c = condition.toLowerCase();
  if (c.includes("thunder") || c.includes("storm"))
    return "linear-gradient(160deg,#0f172a 0%,#1e293b 55%,#312e81 100%)";
  if (c.includes("heavy rain") || c.includes("downpour"))
    return "linear-gradient(160deg,#0f172a 0%,#1e3a5f 100%)";
  if (c.includes("rain") || c.includes("shower") || c.includes("drizzle"))
    return "linear-gradient(160deg,#1e3a5f 0%,#1e4976 50%,#2563eb 100%)";
  if (c.includes("snow") || c.includes("blizzard") || c.includes("flurr"))
    return "linear-gradient(160deg,#bfdbfe 0%,#eff6ff 100%)";
  if (c.includes("fog") || c.includes("mist") || c.includes("haze"))
    return "linear-gradient(160deg,#9ca3af 0%,#d1d5db 100%)";
  if (c.includes("overcast"))
    return "linear-gradient(160deg,#374151 0%,#4b5563 100%)";
  if (c.includes("cloud") || c.includes("partly"))
    return "linear-gradient(160deg,#1d4ed8 0%,#3b82f6 55%,#93c5fd 100%)";
  if (c.includes("wind"))
    return "linear-gradient(160deg,#0891b2 0%,#0e7490 60%,#164e63 100%)";
  // sunny / clear
  return "linear-gradient(160deg,#0369a1 0%,#0ea5e9 50%,#38bdf8 100%)";
}

function weatherEmoji(condition: string): string {
  const c = condition.toLowerCase();
  if (c.includes("thunder") || c.includes("storm"))  return "⛈️";
  if (c.includes("heavy rain") || c.includes("downpour")) return "🌧️";
  if (c.includes("light rain") || c.includes("drizzle")) return "🌦️";
  if (c.includes("rain") || c.includes("shower"))    return "🌧️";
  if (c.includes("snow") || c.includes("blizzard"))  return "❄️";
  if (c.includes("fog") || c.includes("mist"))       return "🌫️";
  if (c.includes("overcast"))                        return "☁️";
  if (c.includes("partly") || c.includes("cloud"))   return "⛅";
  if (c.includes("wind"))                            return "🌬️";
  return "☀️";
}

interface WeatherResult {
  city: string;
  temperature: number;
  unit?: string;
  condition: string;
  high: number;
  low: number;
  humidity?: number;
  wind?: number;
  forecast?: Array<{ day: string; high: number; low: number; condition: string }>;
}

function WeatherCard({ args, result, isError }: ToolCallMessagePartProps) {
  const city = (args as Record<string, unknown>)?.city as string | undefined;

  // ── 加载中 ──
  if (result === undefined) {
    return (
      <div style={{
        background: "linear-gradient(160deg,#334155 0%,#475569 100%)",
        padding: "20px 22px", color: "white",
        opacity: 0.8,
      }}>
        <div style={{ fontSize: "13px", opacity: 0.8 }}>{city ?? "—"}</div>
        <div style={{ fontSize: "52px", fontWeight: 200, lineHeight: 1.1, marginTop: "4px" }}>
          —°
        </div>
        <div style={{ fontSize: "13px", opacity: 0.6, marginTop: "4px" }}>
          Fetching weather…
        </div>
      </div>
    );
  }

  // 错误由外层 WeatherToolCard 处理，这里不会到达
  if (isError) return null;

  const d = result as WeatherResult;
  const unit = d.unit ?? "F";
  const gradient = weatherGradient(d.condition);
  const emoji = weatherEmoji(d.condition);
  const isSnow = d.condition.toLowerCase().includes("snow");
  const textColor = isSnow ? "#1e3a5f" : "white";
  const mutedColor = isSnow ? "rgba(30,58,95,0.65)" : "rgba(255,255,255,0.70)";
  const dividerColor = isSnow ? "rgba(30,58,95,0.18)" : "rgba(255,255,255,0.22)";

  return (
    <div style={{
      background: gradient,
      boxShadow: "0 4px 20px rgba(0,0,0,0.18)",
    }}>
      {/* ── 主区域 ── */}
      <div style={{ padding: "20px 22px 16px" }}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start" }}>
          <div>
            <div style={{ fontSize: "14px", color: textColor, fontWeight: 500 }}>
              {d.city}
            </div>
            <div style={{
              fontSize: "68px", fontWeight: 200, lineHeight: 1,
              color: textColor, marginTop: "4px", letterSpacing: "-2px",
            }}>
              {d.temperature}°{unit}
            </div>
            <div style={{ marginTop: "6px", display: "flex", gap: "10px", fontSize: "13px", color: mutedColor }}>
              <span>↑ {d.high}°</span>
              <span>↓ {d.low}°</span>
            </div>
            <div style={{ marginTop: "6px", fontSize: "14px", color: textColor }}>
              {d.condition}
            </div>
          </div>
          <div style={{ fontSize: "52px", lineHeight: 1, marginTop: "2px" }}>
            {emoji}
          </div>
        </div>

        {/* 湿度 + 风速 */}
        {(d.humidity !== undefined || d.wind !== undefined) && (
          <div style={{
            display: "flex", gap: "16px", marginTop: "14px",
            fontSize: "12px", color: mutedColor,
          }}>
            {d.humidity !== undefined && (
              <span style={{ display: "flex", alignItems: "center", gap: "4px" }}>
                <DropletIcon size={12} /> {d.humidity}%
              </span>
            )}
            {d.wind !== undefined && (
              <span style={{ display: "flex", alignItems: "center", gap: "4px" }}>
                <WindIcon size={12} /> {d.wind} mph
              </span>
            )}
          </div>
        )}
      </div>

      {/* ── 预报行 ── */}
      {d.forecast && d.forecast.length > 0 && (
        <div style={{
          borderTop: `1px solid ${dividerColor}`,
          display: "flex",
          padding: "12px 22px 16px",
          gap: "0",
        }}>
          {d.forecast.map((f) => (
            <div key={f.day} style={{
              flex: 1, textAlign: "center",
              fontSize: "12px", color: textColor,
            }}>
              <div style={{ color: mutedColor, marginBottom: "4px", fontSize: "11px" }}>{f.day}</div>
              <div style={{ fontSize: "18px", lineHeight: 1, marginBottom: "4px" }}>
                {weatherEmoji(f.condition)}
              </div>
              <div style={{ fontWeight: 500 }}>{f.high}°</div>
              <div style={{ color: mutedColor }}>{f.low}°</div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

// ── get_weather 专属：GenericToolCard 小条 + 独立天气卡片 ─────────────────────
function WeatherToolCard(props: ToolCallMessagePartProps) {
  const { toolName, args, argsText, result, isError, artifact } = props;
  return (
    <>
      {/* 1. 复用 GenericToolCard 作为工具调用状态条 */}
      <GenericToolCard {...props} />

      {/* 2. 天气卡片：独立元素，固定宽度，仅 done/pending 时显示 */}
      {!isError && (
        <div style={{ marginTop: "6px", maxWidth: "360px" }}>
          <div style={{ borderRadius: "14px", overflow: "hidden",
                        boxShadow: "0 4px 20px rgba(0,0,0,0.18)" }}>
            <WeatherCard args={args} result={result} isError={isError}
              artifact={artifact} argsText={argsText} toolName={toolName}
              addResult={() => {}} resume={() => {}}
              status={{ type: result === undefined ? "running" : "complete" } as never}
            />
          </div>
        </div>
      )}
    </>
  );
}

// 注册为 get_weather 专属 UI
const WeatherToolUI = makeAssistantToolUI({
  toolName: "get_weather",
  render: WeatherToolCard,
});

// ── 通用 Tool Call 卡片 ──────────────────────────────────────────────────────
function GenericToolCard({ toolName, argsText, args, result, isError, artifact }: ToolCallMessagePartProps) {
  const [open, setOpen] = useState(false);
  const pending  = result === undefined;
  const done     = !pending && !isError;
  const errored  = !pending && !!isError;

  // annotations 存在 artifact 字段（由 runtime.ts 从 ToolCallPayload.annotations 写入）
  const annotations = artifact as Record<string, unknown> | undefined;
  const iconName = annotations?.icon as string | undefined;
  const toolTitle = (annotations?.title as string | undefined) ?? toolName;

  // 成功时：tool 定义的图标，或 CheckCircle2；失败时：AlertCircle
  const SuccessIcon: IconComponent = (iconName && TOOL_ICONS[iconName]) ?? CheckCircle2Icon;
  const HeaderIcon: IconComponent  = errored ? AlertCircleIcon
    : pending ? WrenchIcon
    : SuccessIcon;
  const iconColor = errored ? "#dc2626" : pending ? "#9ca3af" : "#16a34a";

  // 卡片整体背景
  const cardBg = errored ? "#fef2f2"
    : done    ? "hsl(0,0%,97%)"
    : "#ffffff";
  const cardBorder = errored ? "#fecaca"
    : done    ? "#e5e7eb"
    : "#e5e7eb";

  // argsText 防御性 stringify（Shiny 可能把 json class 内联为对象）
  const argsDisplay = typeof argsText === "string"
    ? argsText : JSON.stringify(args ?? argsText, null, 2);
  const resultDisplay = pending ? ""
    : typeof result === "string" ? result
    : JSON.stringify(result, null, 2);

  return (
    <div style={{
      border: `1px solid ${cardBorder}`,
      borderRadius: "8px",
      fontSize: "13px",
      overflow: "hidden",
      marginBottom: "4px",
      background: cardBg,
    }}>
      {/* 头部：图标 + 工具名 + 展开箭头 */}
      <button
        onClick={() => setOpen((v) => !v)}
        style={{
          width: "100%", display: "flex", alignItems: "center", gap: "7px",
          padding: "7px 10px", background: "none", border: "none",
          cursor: "pointer", textAlign: "left",
          color: "var(--aui-foreground, #111827)",
        }}
      >
        <HeaderIcon size={14} style={{ flexShrink: 0 }} color={iconColor} />
        <span style={{ fontWeight: 500, flex: 1 }}>{toolTitle}</span>
        {pending && (
          <span style={{ fontSize: "11px", color: "#9ca3af" }}>running…</span>
        )}
        {open ? <ChevronDownIcon size={13} color="#9ca3af" />
               : <ChevronRightIcon size={13} color="#9ca3af" />}
      </button>

      {/* 展开：参数 + 结果 */}
      {open && (
        <div style={{
          borderTop: `1px solid ${cardBorder}`,
          padding: "8px 10px",
        }}>
          <div style={{ color: "#9ca3af", marginBottom: "4px", fontSize: "11px",
                        textTransform: "uppercase", letterSpacing: "0.05em" }}>
            Arguments
          </div>
          <pre style={{
            margin: 0, padding: "6px 8px", borderRadius: "4px",
            background: "rgba(0,0,0,0.04)", fontSize: "12px",
            overflowX: "auto", whiteSpace: "pre-wrap", wordBreak: "break-all",
          }}>
            {argsDisplay}
          </pre>

          {!pending && (
            <>
              <div style={{ color: "#9ca3af", marginTop: "10px", marginBottom: "4px",
                            fontSize: "11px", textTransform: "uppercase", letterSpacing: "0.05em" }}>
                Result
              </div>
              <pre style={{
                margin: 0, padding: "6px 8px", borderRadius: "4px",
                background: errored ? "rgba(220,38,38,0.06)" : "rgba(0,0,0,0.04)",
                color: errored ? "#991b1b" : undefined,
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

// ── ShinyComposer：自定义输入框（@ mention / / commands / + 上传）────────────
interface ComposerConfigCtx {
  tools:    Array<{ name: string; description: string }>;
  commands: Array<{ name: string; description: string; prompt: string }>;
}
const ShinyComposerCtx = createContext<ComposerConfigCtx>({ tools: [], commands: [] });

function ShinyComposer() {
  const { tools, commands } = useContext(ShinyComposerCtx);
  const thread = useThreadRuntime();

  const mentionAdapter = unstable_useToolMentionAdapter({
    tools: tools.map(t => ({
      id: t.name, type: "tool" as const, label: t.name, description: t.description,
    })),
    includeModelContextTools: false,
  });

  const slashAdapter = unstable_useSlashCommandAdapter({
    commands: commands.map(c => ({
      name: c.name,
      label: c.name,
      description: c.description,
      execute: () => {
        thread.append({
          role: "user",
          content: [{ type: "text", text: c.prompt }],
        } as CreateAppendMessage);
      },
    })),
  });

  const popoverStyle: React.CSSProperties = {
    position: "absolute",
    bottom: "calc(100% + 6px)",
    left: 0,
    background: "white",
    border: "1px solid #e5e7eb",
    borderRadius: "10px",
    boxShadow: "0 4px 16px rgba(0,0,0,0.12)",
    minWidth: "260px",
    maxWidth: "340px",
    padding: "6px",
    zIndex: 200,
  };

  const itemStyle: React.CSSProperties = {
    display: "flex",
    alignItems: "flex-start",
    gap: "10px",
    padding: "8px 10px",
    borderRadius: "6px",
    cursor: "pointer",
    fontSize: "13px",
    background: "none",
    border: "none",
    width: "100%",
    textAlign: "left",
  };

  const hasTools    = tools.length > 0;
  const hasCommands = commands.length > 0;

  // placeholder 根据实际功能动态生成
  const hints = [
    hasTools    && "@ to mention",
    hasCommands && "/ for commands",
  ].filter(Boolean).join(", ");
  const placeholder = hints
    ? `Send a message… (${hints})`
    : "Send a message…";

  // ── 输入框 + 底部按钮（始终渲染）─────────────────────────────────────────
  const inputBox = (
    <div style={{
      border: "1px solid #e5e7eb",
      borderRadius: "12px",
      background: "white",
      padding: "10px 12px",
      width: "100%",
      boxSizing: "border-box",
    }}>
      <ComposerPrimitive.Input
        placeholder={placeholder}
        style={{
          width: "100%", border: "none", outline: "none",
          resize: "none", fontSize: "14px",
          background: "transparent", fontFamily: "inherit",
        }}
      />
      <div style={{ display: "flex", alignItems: "center",
                    justifyContent: "space-between", marginTop: "8px" }}>
        <ComposerPrimitive.AddAttachment
          style={{
            background: "none", border: "none", cursor: "pointer",
            fontSize: "20px", color: "#6b7280", padding: "2px 6px",
            lineHeight: 1, display: "flex", alignItems: "center",
          }}
        >
          +
        </ComposerPrimitive.AddAttachment>

        <ComposerPrimitive.Send
          style={{
            background: "#374151", border: "none", borderRadius: "50%",
            width: "30px", height: "30px", cursor: "pointer",
            display: "flex", alignItems: "center", justifyContent: "center",
            color: "white", fontSize: "14px", flexShrink: 0,
          }}
        >
          ↑
        </ComposerPrimitive.Send>
      </div>
    </div>
  );

  // ── / 命令弹窗（只在有 commands 时渲染）──────────────────────────────────
  const slashPopover = hasCommands ? (
    <ComposerPrimitive.Unstable_TriggerPopoverPopover style={popoverStyle}>
      <ComposerPrimitive.Unstable_TriggerPopoverItems>
        {(items) => (
          <div>
            {items.map((item, index) => (
              <ComposerPrimitive.Unstable_TriggerPopoverItem
                key={item.id} item={item} index={index}
                style={itemStyle}
              >
                <span style={{ fontWeight: 500 }}>/{item.label}</span>
                {item.description && (
                  <span style={{ color: "#6b7280", flex: 1 }}>{item.description}</span>
                )}
              </ComposerPrimitive.Unstable_TriggerPopoverItem>
            ))}
          </div>
        )}
      </ComposerPrimitive.Unstable_TriggerPopoverItems>
    </ComposerPrimitive.Unstable_TriggerPopoverPopover>
  ) : null;

  // ── @ 工具弹窗（只在有 tools 时渲染）────────────────────────────────────
  const mentionPopover = hasTools ? (
    <ComposerPrimitive.Unstable_MentionPopover style={{ ...popoverStyle, minWidth: "280px" }}>
      <ComposerPrimitive.Unstable_MentionBack
        style={{
          display: "flex", alignItems: "center", gap: "6px",
          padding: "4px 8px", fontSize: "12px", color: "#6b7280",
          background: "none", border: "none", cursor: "pointer",
          marginBottom: "4px", width: "100%",
        }}
      >
        ← BACK
      </ComposerPrimitive.Unstable_MentionBack>
      <ComposerPrimitive.Unstable_MentionItems>
        {(items) => (
          <div>
            {items.map((item, index) => (
              <ComposerPrimitive.Unstable_MentionItem
                key={item.id} item={item} index={index}
                style={{
                  display: "flex", flexDirection: "column", gap: "2px",
                  padding: "8px 10px", borderRadius: "6px", cursor: "pointer",
                  background: "none", border: "none", width: "100%",
                  textAlign: "left",
                }}
              >
                <span style={{ fontSize: "13px", fontWeight: 500 }}>{item.label}</span>
                {item.description && (
                  <span style={{ fontSize: "12px", color: "#6b7280" }}>
                    {item.description}
                  </span>
                )}
              </ComposerPrimitive.Unstable_MentionItem>
            ))}
          </div>
        )}
      </ComposerPrimitive.Unstable_MentionItems>
    </ComposerPrimitive.Unstable_MentionPopover>
  ) : null;

  // ── 按需包裹 SlashCommandRoot / MentionRoot ───────────────────────────────
  // 只有配置了对应数据时才包裹，避免空列表时弹出空白框
  const withSlash = hasCommands ? (
    <ComposerPrimitive.Unstable_SlashCommandRoot adapter={slashAdapter}>
      {inputBox}
      {slashPopover}
    </ComposerPrimitive.Unstable_SlashCommandRoot>
  ) : inputBox;

  const withMention = hasTools ? (
    <ComposerPrimitive.Unstable_MentionRoot
      adapter={mentionAdapter}
      trigger="@"
      formatter={unstable_defaultDirectiveFormatter}
    >
      {withSlash}
      {mentionPopover}
    </ComposerPrimitive.Unstable_MentionRoot>
  ) : withSlash;

  return (
    <div style={{ padding: "0 16px 16px", position: "relative", width: "100%" }}>
      {withMention}
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

  // composer context — tools 和 commands 从 R 的 config 读取
  const composerCtx = useMemo<ComposerConfigCtx>(() => ({
    tools:    (config?.tools    as ComposerConfigCtx["tools"])    ?? [],
    commands: (config?.commands as ComposerConfigCtx["commands"]) ?? [],
  }), [config]);

  // starter suggestions — 传给 Thread welcome.suggestions
  const suggestions = useMemo(() => {
    const raw = config?.suggestions as Array<{ prompt: string; text?: string }> | undefined;
    return (raw ?? []).map(s => ({ prompt: s.prompt, text: s.text ?? s.prompt }));
  }, [config]);

  return (
    <AssistantRuntimeProvider runtime={runtime}>
      <ShinyComposerCtx.Provider value={composerCtx}>
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
                tools={[WeatherToolUI]}
                welcome={{ suggestions }}
                components={{ Composer: ShinyComposer }}
                assistantMessage={{
                  components: { ToolFallback: GenericToolCard },
                }}
              />
            </div>
          </div>

        </div>
      </ShinyComposerCtx.Provider>
    </AssistantRuntimeProvider>
  );
}
