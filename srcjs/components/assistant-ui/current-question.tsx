"use client";

import { useState, type FC } from "react";
import { useAuiState } from "@assistant-ui/react";
import { ChevronDownIcon, ChevronUpIcon } from "lucide-react";
import { cn } from "@/lib/utils";
import { useShinyConfig } from "@/shiny-config-context";

// 读取最近一条 user 消息的纯文本。selector 返回 string → Object.is 相等，
// 不随 assistant 流式 token 触发重渲染（只在新提问出现时变化）。
function useLatestUserQuestion(): string {
  return useAuiState((s) => {
    const messages = s.thread?.messages ?? [];
    for (let i = messages.length - 1; i >= 0; i--) {
      const m = messages[i];
      if (m.role !== "user") continue;
      const text = (m.content ?? [])
        .filter((p): p is { type: "text"; text: string } => p?.type === "text")
        .map((p) => p.text)
        .join(" ")
        .trim();
      return text;
    }
    return "";
  });
}

// 所有 user 提问文本,按渲染顺序用 \u0000 连接成【单个字符串】返回 —— selector 返回 string
// 使 Object.is 稳定,流式期间不触发重渲染;调用方 split("\u0000") 得数组。供顶部条 scroll-spy 用。
export function useAllUserQuestions(): string {
  return useAuiState((s) => {
    const parts: string[] = [];
    const messages = s.thread?.messages ?? [];
    for (const m of messages) {
      if (m.role !== "user") continue;
      const text = (m.content ?? [])
        .filter((p): p is { type: "text"; text: string } => p?.type === "text")
        .map((p) => p.text)
        .join(" ")
        .trim();
      parts.push(text);
    }
    return parts.join("\u0000");
  });
}

/**
 * VS Code / Claude Code 式"当前提问"顶部小框：内容长到需要翻页（`visible`，由 Thread 按视口
 * 溢出判定）时，在滚动区顶部 sticky 显示最近一次用户提问。折叠为单行、可展开看全文。
 * 与底部自动跟随互补：流式跟到底部的同时，顶部始终能看到"我问了什么"。
 */
export const ShinyCurrentQuestion: FC<{ visible: boolean; question?: string }> = ({ visible, question }) => {
  const latest = useLatestUserQuestion();
  // scroll-spy 传入当前视口所在轮的提问;缺省(独立使用)回退到最新一次。
  const q = question ?? latest;
  const [expanded, setExpanded] = useState(false);
  const { sidebarCollapsed } = useShinyConfig();

  if (!visible || !q) return null;

  return (
    <div
      data-slot="aui_current_question"
      data-expanded={expanded ? "true" : "false"}
      className="bg-background/85 supports-[backdrop-filter]:bg-background/70 sticky top-0 z-20 -mx-4 mb-2 border-b px-4 py-1.5 backdrop-blur"
    >
      <div
        className={cn(
          "mx-auto flex w-full max-w-(--thread-max-width) items-start gap-2",
          // 折叠时展开按钮浮在左上角（start-2, size-7）→ 让内容从按钮右侧开始，二者并排
          sidebarCollapsed && "ps-9",
        )}
      >
        <span className="text-muted-foreground mt-0.5 shrink-0 text-[10px] font-medium tracking-wide uppercase">
          Question
        </span>
        <p
          className={cn(
            "text-foreground/90 min-w-0 flex-1 text-xs leading-relaxed",
            expanded ? "max-h-40 overflow-y-auto whitespace-pre-wrap" : "truncate",
          )}
        >
          {q}
        </p>
        <button
          type="button"
          data-slot="aui_current_question_toggle"
          aria-label={expanded ? "Collapse question" : "Expand question"}
          onClick={() => setExpanded((v) => !v)}
          className="text-muted-foreground hover:text-foreground hover:bg-accent -mt-0.5 flex size-5 shrink-0 items-center justify-center rounded transition-colors"
        >
          {expanded ? (
            <ChevronUpIcon className="size-3.5" />
          ) : (
            <ChevronDownIcon className="size-3.5" />
          )}
        </button>
      </div>
    </div>
  );
};
