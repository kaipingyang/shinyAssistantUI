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


export interface SlashActionLike {
  id: string;
  command?: string;
  label?: string;
  section?: string;
  description?: string;
}

export interface SlashCommandLike {
  name: string;
  description?: string;
  prompt: string;
  category?: string;
  source?: string;
  kind?: string;
}

// Local actions are deterministic controls, not prompts. Only intercept an exact,
// standalone command so `/compact focus on tests` can still reach Claude Code,
// which owns argument parsing for built-in commands.
export function matchSlashAction(
  text: string,
  actions: SlashActionLike[],
): SlashActionLike | undefined {
  const match = text.trim().match(/^\/([^\s]+)$/);
  if (!match) return undefined;
  const command = match[1].toLowerCase();
  return actions.find((action) =>
    (action.command ?? action.id).toLowerCase() === command,
  );
}

// Configured commands (including locally discovered skills) retain their source
// metadata. Live Agent SDK commands fill the remaining names, while deterministic
// local actions win collisions such as /compact and /context.
export function mergeSlashCommands(
  configured: SlashCommandLike[],
  serverCommands: Array<{ name: string; description?: string }>,
  actions: SlashActionLike[],
): SlashCommandLike[] {
  const blocked = new Set(actions.map((action) =>
    (action.command ?? action.id).toLowerCase(),
  ));
  const dedupedConfigured: SlashCommandLike[] = [];
  const seen = new Set<string>();
  for (const command of configured) {
    const name = command.name.toLowerCase();
    if (!name || blocked.has(name) || seen.has(name)) continue;
    seen.add(name);
    dedupedConfigured.push(command);
  }
  const live = serverCommands
    .filter((command) => {
      const name = command.name.toLowerCase();
      if (!name || seen.has(name) || blocked.has(name)) return false;
      seen.add(name);
      return true;
    })
    .map((command) => ({
      name: command.name,
      description: command.description,
      prompt: `/${command.name}`,
      category: "Claude Code",
    }));
  return [...dedupedConfigured, ...live];
}
export function safeUrl(url: string): string | null {
  const trimmed = url.trim();
  // 相对路径 / 锚点 / 协议相对：安全
  if (/^(\/|\.{0,2}\/|#|\?)/.test(trimmed)) return trimmed;
  // 绝对 URL：仅白名单 scheme
  if (/^(https?:|mailto:|tel:)/i.test(trimmed)) return trimmed;
  return null;
}

// 行内 `code` 是否长得像"可打开的文件引用"（addin 里点击可在 RStudio 打开）。
// 最稳妥策略：必须有已知代码/文本扩展名（避免把 1.5 / e.g / modules_metadata 之类误判），
// 允许可选 :行号；含空格/引号/括号一律不算。返回 {path,line} 或 null。
const FILE_REF_EXT =
  /\.(R|r|Rmd|rmd|qmd|Rnw|py|pyi|js|jsx|ts|tsx|mjs|cjs|json|ya?ml|toml|ini|cfg|xml|csv|tsv|sql|sh|bash|zsh|md|markdown|txt|c|h|cc|cpp|hpp|hxx|java|kt|go|rs|rb|php|cs|swift|css|scss|sass|less|html?|vue|svelte|lua|pl|jl|dart|scala|clj)$/i;
export function parseFileRef(raw: string): { path: string; line?: number } | null {
  if (!raw) return null;
  const text = raw.trim();
  if (text.length === 0 || text.length > 200) return null;
  const m = text.match(/^([^\s`'"()<>]+?)(?::(\d+))?$/);
  if (!m) return null;
  const path = m[1]!;
  if (!FILE_REF_EXT.test(path)) return null;   // 必须有已知扩展名
  const line = m[2] ? Number(m[2]) : undefined;
  return line !== undefined ? { path, line } : { path };
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
): ThreadMessageLike[] {
  let cutIdx: number;
  if (parentId === null) {
    cutIdx = 0;
  } else {
    const idx = threadMsgs.findIndex((m) => m.id === parentId);
    if (idx < 0) {
      // parentId 找不到(如历史加载 / 工具轮次后消息 id 方案不一致):把编辑后的消息追加到
      // 末尾并照常重发(不静默丢弃,否则"编辑后 Update 无反应")。
      return [...threadMsgs, newUserMessage];
    }
    cutIdx = idx + 1;
  }
  return [...threadMsgs.slice(0, cutIdx), newUserMessage];
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

// ── 工具参数美化：合法 JSON → 缩进后交语法高亮；流式半截/非 JSON → 原样(raw) ──────
export function formatToolArgs(
  argsText: string | undefined,
): { kind: "json"; text: string } | { kind: "raw"; text: string } | null {
  if (!argsText) return null;
  try {
    const parsed = JSON.parse(argsText);
    // 仅对象/数组值得 pretty；标量(如 "abc"/42)直接 raw，避免徒增引号缩进。
    if (parsed !== null && typeof parsed === "object")
      return { kind: "json", text: JSON.stringify(parsed, null, 2) };
    return { kind: "raw", text: argsText };
  } catch {
    return { kind: "raw", text: argsText };
  }
}

// ── Edit/MultiEdit 工具 → 改前/改后内容（供工具卡渲染 git 式 diff）──────────────
// Claude Code：Edit tool_input = {file_path, old_string, new_string}；
// MultiEdit = {file_path, edits:[{old_string,new_string}]}。Write 只有新内容（无旧内容）→ null，
// 不臆造 diff。缺字段（流式中 args 不全）→ null，调用方回退显示原始参数。
export function getEditDiff(
  toolName: string | undefined,
  args: unknown,
): { oldContent: string; newContent: string; fileName?: string } | null {
  const a = (args ?? {}) as Record<string, unknown>;
  const fileName =
    typeof a.file_path === "string" && a.file_path ? a.file_path
    : typeof a.path === "string" && a.path ? a.path
    : undefined;
  if (toolName === "Edit") {
    const o = a.old_string, n = a.new_string;
    if (typeof o === "string" && typeof n === "string")
      return { oldContent: o, newContent: n, fileName };
    return null;
  }
  if (toolName === "MultiEdit") {
    const edits = Array.isArray(a.edits) ? a.edits : null;
    if (!edits || edits.length === 0) return null;
    const olds: string[] = [];
    const news: string[] = [];
    for (const e of edits) {
      const eo = (e as Record<string, unknown>)?.old_string;
      const en = (e as Record<string, unknown>)?.new_string;
      if (typeof eo !== "string" || typeof en !== "string") return null;
      olds.push(eo);
      news.push(en);
    }
    return { oldContent: olds.join("\n"), newContent: news.join("\n"), fileName };
  }
  return null;
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


export type WorkspaceMentionItem = {
  kind: "file" | "folder";
  path: string;
  label?: string;
  insertText?: string;
};

function isSubsequence(needle: string, haystack: string): boolean {
  if (!needle) return true;
  let at = 0;
  for (const char of haystack) {
    if (char === needle[at]) at += 1;
    if (at === needle.length) return true;
  }
  return false;
}

/** Deterministic file/folder fuzzy ranking shared by tests and mention UI. */
export function rankMentionItems(
  items: WorkspaceMentionItem[],
  query: string,
  limit = 50,
): WorkspaceMentionItem[] {
  const q = query.trim().toLowerCase().replace(/#l\d+(?:-l?\d*)?$/i, "");
  return items
    .map((item) => {
      const path = item.path.toLowerCase();
      const base = item.path.replace(/\/$/, "").split("/").pop()?.toLowerCase() ?? path;
      const score = !q ? 0
        : base.startsWith(q) ? 0
        : base.includes(q) ? 1
        : path.startsWith(q) ? 2
        : path.includes(q) ? 3
        : isSubsequence(q, base) ? 4
        : isSubsequence(q, path) ? 5
        : Number.POSITIVE_INFINITY;
      return { item, score, depth: (item.path.match(/\//g) ?? []).length };
    })
    .filter((entry) => Number.isFinite(entry.score))
    .sort((a, b) =>
      a.score - b.score ||
      a.depth - b.depth ||
      Number(a.item.kind === "file") - Number(b.item.kind === "file") ||
      a.item.path.length - b.item.path.length ||
      a.item.path.localeCompare(b.item.path),
    )
    .slice(0, Math.max(1, limit))
    .map((entry) => entry.item);
}

/** Format a literal Claude Code file/folder mention without reading file content. */
export function mentionInsertText(
  item: WorkspaceMentionItem,
  lines?: { startLine?: number; endLine?: number },
): string {
  const escaped = item.path.replace(/"/g, '\\"');
  const base = /\s/.test(item.path) ? `@"${escaped}"` : `@${item.path}`;
  if (item.kind === "folder" || !lines?.startLine) return base;
  const start = Math.max(1, Math.trunc(lines.startLine));
  const end = lines.endLine ? Math.max(start, Math.trunc(lines.endLine)) : start;
  return `${base}#L${start}${end === start ? "" : `-L${end}`}`;
}

export function toolHistoryDefaultOpen(
  options: { defaultOpen?: boolean } | undefined,
  requiresAction: boolean,
): boolean {
  if (typeof options?.defaultOpen === "boolean") return options.defaultOpen;
  return requiresAction;
}


// 工具卡标题里的参数摘要:优先取有意义的主字段(文件名走 basename),跳过布尔/数字,
// 回退到第一个非空字符串值。修复 `Edit(false)`(旧逻辑盲取 Object.values()[0])。
function clipSummary(s: string): string {
  const t = s.replace(/\s+/g, " ").trim();
  return t.length > 50 ? t.slice(0, 50) + "\u2026" : t;
}
export function toolCallSummary(
  _toolName: string | undefined,
  args: unknown,
): string | undefined {
  if (args == null || typeof args !== "object") return undefined;
  const a = args as Record<string, unknown>;
  const str = (v: unknown): string | undefined =>
    typeof v === "string" && v.trim() ? v : undefined;
  const basename = (p: string) => p.replace(/[\\/]+$/, "").split(/[\\/]/).pop() || p;

  const file = str(a.file_path) ?? str(a.path);
  if (file) return clipSummary(basename(file));

  const primary =
    str(a.command) ?? str(a.pattern) ?? str(a.query) ?? str(a.url) ?? str(a.code);
  if (primary) return clipSummary(primary);

  for (const v of Object.values(a)) {
    const s = str(v);
    if (s) return clipSummary(s);
  }
  return undefined;
}
