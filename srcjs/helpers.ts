// 纯函数 helper（无 React / DOM / localStorage 依赖），从 runtime.ts 和 AssistantUI.tsx
// 抽出以便单元测试。仅做数据变换 / 字符串处理。
import type { ThreadMessageLike } from "@assistant-ui/core";
import type { AttachmentData } from "./bridge";

// localStorage key 前缀生成
export function storageKey(inputId: string, suffix: string): string {
  return `shinyAssistantUI:${inputId}:${suffix}`;
}

export function makeThreadId(): string {
  return `t_${Date.now()}_${Math.random().toString(36).slice(2, 7)}`;
}

// 把所有未完成（result === undefined）的 tool-call part 标记为中断。
// 用于：① localStorage 历史恢复（session 已结束）；② 运行中取消/完成时清理半截卡片。
// 不假设 tool-call 一定在 content[0]——按 type 定位，兼容未来多 part 消息。
export function markStaleToolCalls(
  msgs: ThreadMessageLike[],
  resultText: string,
): { messages: ThreadMessageLike[]; changed: boolean } {
  let changed = false;
  const messages = msgs.map((m): ThreadMessageLike => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const content = m.content as any[];
    if (!Array.isArray(content)) return m;
    let touched = false;
    const newContent = content.map((part) => {
      if (part?.type !== "tool-call" || part.result !== undefined) return part;
      touched = true;
      return { ...part, result: resultText, isError: true };
    });
    if (!touched) return m;
    changed = true;
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    return { ...m, content: newContent } as any;
  });
  return { messages, changed };
}

// 落盘前剥离附件里的大体积 base64 data（image/file），只保留元信息。
// 原因：一张几 MB 的图片 base64 会撑爆 localStorage 配额（通常 5-10MB），
// 触发 QuotaExceededError → 整个 thread 历史无法落盘 → 刷新丢失。
// 内存态（当前会话显示 + 发往 R 的 attachmentData）仍持完整 data，仅持久化精简。
export function stripAttachmentData(msgs: ThreadMessageLike[]): ThreadMessageLike[] {
  return msgs.map((m) => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const att = (m as any).attachments;
    if (!Array.isArray(att) || att.length === 0) return m;
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const slimmed = att.map((a: any) => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const content = Array.isArray(a.content)
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        ? a.content.map((p: any) =>
            p?.type === "image" ? { ...p, image: "" }
            : p?.type === "file" ? { ...p, data: "" }
            : p,
          )
        : a.content;
      return { ...a, file: undefined, content };
    });
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    return { ...m, attachments: slimmed } as any;
  });
}

// 从 AppendMessage 提取附件：返回发往 R 的结构化 attachmentData + 存入消息的 storedAttachments
// （strip 掉无法 JSON 序列化的 File 对象）。onNew / onEdit 共用，避免逻辑重复。
export function extractAttachments(msg: unknown): {
  attachmentData: AttachmentData[];
  storedAttachments: unknown[];
} {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const rawAttachments: any[] = (msg as any)?.attachments ?? [];
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const attachmentData: AttachmentData[] = rawAttachments.map((att: any) => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const content: any[] = att.content ?? [];
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const imgPart  = content.find((p: any) => p.type === "image");
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const textPart = content.find((p: any) => p.type === "text");
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const filePart = content.find((p: any) => p.type === "file");
    if (imgPart)  return { type: "image", name: att.name, data: imgPart.image, contentType: att.contentType };
    if (textPart) return { type: "text",  name: att.name, data: textPart.text, contentType: att.contentType };
    if (filePart) return { type: "file",  name: att.name, data: filePart.data, contentType: att.contentType ?? filePart.mimeType };
    return { type: att.type ?? "file", name: att.name, data: "", contentType: att.contentType };
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const storedAttachments = rawAttachments.map((att: any) => ({ ...att, file: undefined }));
  return { attachmentData, storedAttachments };
}

// 把 /commandName 展开为 cmd.prompt（chip directiveText 是 "/name"，R 需要实际 prompt）。
// 按 name 长度降序处理 + 词边界匹配，避免 "/test2" 被 "/test" 命中（前缀冲突）。
export function expandSlashCommands(
  text: string,
  commands: { name: string; prompt: string }[],
): string {
  let out = text;
  const sorted = [...commands].sort((a, b) => b.name.length - a.name.length);
  for (const cmd of sorted) {
    // 词边界：/name 后必须是字符串末尾或非单词字符（空格/标点），不匹配 /name2
    const escaped = cmd.name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const re = new RegExp(`/${escaped}(?![\\w-])`, "g");
    out = out.replace(re, () => cmd.prompt);
  }
  return out;
}

// 仅允许安全 scheme 的 URL，阻断 javascript:/data:/vbscript: 等 XSS 向量。
// 工具结果 markdown 可能来自不可信源（如抓取的网页内容），必须过滤。
export function safeUrl(url: string): string | null {
  const trimmed = url.trim();
  // 相对路径 / 锚点 / 协议相对：安全
  if (/^(\/|\.{0,2}\/|#|\?)/.test(trimmed)) return trimmed;
  // 绝对 URL：仅白名单 scheme
  if (/^(https?:|mailto:|tel:)/i.test(trimmed)) return trimmed;
  return null;
}

// 流式 markdown 表格补全：补上缺失的 separator 行，使流式中途的表格也能渲染。
export function preprocessStreamingMarkdown(text: string): string {
  // 快速短路：每个流式 token 都会调用本函数，绝大多数 markdown 不含表格。
  // 无 "|" 时直接返回（O(n) 单次扫描），避免对长回复每 token 做 split+遍历的 O(n²)。
  if (text.indexOf("|") === -1) return text;

  const lines = text.split("\n");
  let tableStart = -1;
  let hasSep = false;
  for (let i = 0; i <= lines.length; i++) {
    const line = i < lines.length ? lines[i].trim() : "";
    // 至少 "|x|" 形态（长度 > 2）才算表格行，排除单字符 "|" 或 "||" 误判
    const isTableRow = line.length > 2 && line.startsWith("|") && line.endsWith("|");
    const isSep = isTableRow && /^\|[\s|:_-]+\|$/.test(line);
    if (isTableRow) {
      if (tableStart === -1) { tableStart = i; hasSep = false; }
      if (isSep) hasSep = true;
    } else {
      if (tableStart !== -1 && !hasSep) {
        const cols = lines[tableStart].split("|").filter(s => s.trim()).length;
        if (cols > 0) {
          lines.splice(tableStart + 1, 0, "|" + Array(cols).fill(" --- ").join("|") + "|");
          i++;
        }
      }
      tableStart = -1; hasSep = false;
    }
  }
  return lines.join("\n");
}

// 从光标位置向后扫描，遇到空白停止，找到 "/" 即返回触发位置（与库内 detectTrigger 逻辑一致）
export function detectSlashTrigger(text: string, cursorPos: number): { query: string; offset: number } | null {
  const upToCursor = text.slice(0, cursorPos);
  for (let i = upToCursor.length - 1; i >= 0; i--) {
    const ch = upToCursor[i];
    if (/\s/.test(ch)) return null;
    if (ch === "/" && (i === 0 || /\s/.test(upToCursor[i - 1]))) {
      return { query: upToCursor.slice(i + 1), offset: i };
    }
  }
  return null;
}

// 与 detectSlashTrigger 同理,检测光标前的 @mention 触发词(行首或空白后的 @)。
export function detectMentionTrigger(text: string, cursorPos: number): { query: string; offset: number } | null {
  const upToCursor = text.slice(0, cursorPos);
  for (let i = upToCursor.length - 1; i >= 0; i--) {
    const ch = upToCursor[i];
    if (/\s/.test(ch)) return null;
    if (ch === "@" && (i === 0 || /\s/.test(upToCursor[i - 1]))) {
      return { query: upToCursor.slice(i + 1), offset: i };
    }
  }
  return null;
}

// 监听 el 从 DOM 被移除（modal 反复开关、renderUI/removeUI、navset 切换），触发 onRemove。
// 监听 el.parentNode 的 childList（非 body 全子树）——只关心 el 是否被移除，避免 widget
// 自身流式渲染的高频 DOM 变动持续自触发回调。返回 disconnect 函数。
// el 无父节点或环境无 MutationObserver 时返回 no-op disconnect。
export function createRemovalWatcher(el: Element, onRemove: () => void): () => void {
  if (typeof MutationObserver === "undefined") return () => {};
  const parent = el.parentNode;
  if (!parent) return () => {};
  const observer = new MutationObserver(() => {
    if (!el.isConnected) onRemove();
  });
  observer.observe(parent, { childList: true });
  return () => observer.disconnect();
}

// 计算编辑消息后的新消息数组：截断到 parentId（含）之后，再追加编辑后的 user 消息。
// - parentId === null：从头截断（编辑首条消息）
// - parentId 找不到（陈旧 id / 切线程竞态）：返回 aborted=true，调用方应放弃本次编辑
//   （不截断、不发消息），避免只发 R 却不插 user 气泡导致 UI/R 发散。
// 不在内部构造 id（依赖时钟），由调用方传入 newUserMessage。
export function applyEdit(
  threadMsgs: ThreadMessageLike[],
  parentId: string | null,
  newUserMessage: ThreadMessageLike,
): { updated: ThreadMessageLike[]; aborted: boolean } {
  let cutIdx: number;
  if (parentId === null) {
    cutIdx = 0;
  } else {
    const idx = threadMsgs.findIndex((m) => m.id === parentId);
    if (idx < 0) return { updated: threadMsgs, aborted: true };
    cutIdx = idx + 1;
  }
  return { updated: [...threadMsgs.slice(0, cutIdx), newUserMessage], aborted: false };
}


// ── Sub-agent 层级：从 parentToolCallId 链计算嵌套深度（D2）──────────────────
// parentMap: toolCallId → parentToolCallId（undefined/null 表示顶层）。
// 返回该 toolCallId 的嵌套深度（顶层 = 0）。
// - 带环检测（parent 链意外成环时封顶，不死循环）。
// - 链上出现未知 parent（尚未注册，如子卡片先于父渲染）时按当前累计深度返回，
//   后续父卡片注册 + 重渲染会自动修正。
export function computeToolDepth(
  toolCallId: string,
  parentMap: Map<string, string | null | undefined>,
  maxDepth = 16,
): number {
  let depth = 0;
  let current: string | null | undefined = parentMap.get(toolCallId);
  const seen = new Set<string>([toolCallId]);
  while (current != null && depth < maxDepth) {
    if (seen.has(current)) break; // 环：停止
    seen.add(current);
    depth += 1;
    current = parentMap.get(current);
  }
  return depth;
}

// ── Theme customization（Tailwind v4 token 注入）─────────────────────────────
// 把 R 端 theme 对象（token → 任意 CSS 颜色）转成 [cssVar, value] 对,注入到 widget
// 根元素 inline style,覆盖 globals.css 的 :root token。token 名下划线转连字符,加
// `--` 前缀(primary_foreground → --primary-foreground;radius → --radius),对应
// globals.css 里 @theme inline 映射的 --primary/--background/... 变量。
export function themeToCssVars(
  theme: Record<string, unknown> | null | undefined,
): Array<[string, string]> {
  if (!theme || typeof theme !== "object") return [];
  const out: Array<[string, string]> = [];
  for (const [key, value] of Object.entries(theme)) {
    if (value == null || value === "") continue;
    const cssVar = `--${String(key).replace(/_/g, "-")}`;
    out.push([cssVar, String(value)]);
  }
  return out;
}

// ── 消息时间戳:从消息 id 尾部的 epoch ms 解析并格式化为 HH:MM ────────────────
// 用户/assistant 消息 id 形如 `user-<ms>` / `assistant-<ms>`(含 Date.now())。
// 解析不到(如 R 提供的历史 session id 不含时间戳)返回 null,不显示。
export function formatMessageTime(id: string | null | undefined): string | null {
  if (!id) return null;
  const m = /-(\d{10,})$/.exec(id);
  if (!m) return null;
  const ms = Number(m[1]);
  if (!Number.isFinite(ms)) return null;
  const d = new Date(ms);
  if (isNaN(d.getTime())) return null;
  const hh = String(d.getHours()).padStart(2, "0");
  const mm = String(d.getMinutes()).padStart(2, "0");
  return `${hh}:${mm}`;
}
