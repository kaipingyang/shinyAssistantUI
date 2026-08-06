import { describe, it, expect } from "vitest";
import {
  storageKey, makeThreadId, markStaleToolCalls, stripAttachmentData,
  extractAttachments, expandSlashCommands, safeUrl, parseFileRef,
  preprocessStreamingMarkdown, detectSlashTrigger, applyEdit,
  computeToolDepth, themeToCssVars, formatMessageTime, detectMentionTrigger,
  matchSlashAction, mergeSlashCommands, rankMentionItems, mentionInsertText,
  toolHistoryDefaultOpen, toolCallSummary, resolveToolFileReference,
} from "./helpers";

describe("storageKey", () => {
  it("拼接前缀", () => {
    expect(storageKey("chat", "threads")).toBe("shinyAssistantUI:chat:threads");
    expect(storageKey("c2", "msgs:t1")).toBe("shinyAssistantUI:c2:msgs:t1");
  });
});

describe("makeThreadId", () => {
  it("格式 t_<ts>_<rand>", () => {
    expect(makeThreadId()).toMatch(/^t_\d+_[a-z0-9]{1,5}$/);
  });
  it("连续两次不相等", () => {
    expect(makeThreadId()).not.toBe(makeThreadId());
  });
});

describe("expandSlashCommands", () => {
  const cmds = [
    { name: "test", prompt: "RUN TEST" },
    { name: "test2", prompt: "RUN TEST2" },
    { name: "deploy", prompt: "DO DEPLOY" },
  ];
  it("/test2 不被 /test 命中（前缀冲突 + 长度降序）", () => {
    expect(expandSlashCommands("/test2", cmds)).toBe("RUN TEST2");
  });
  it("/test 精确展开", () => {
    expect(expandSlashCommands("/test", cmds)).toBe("RUN TEST");
  });
  it("词边界：/testing 不展开", () => {
    expect(expandSlashCommands("/testing", cmds)).toBe("/testing");
  });
  it("/test 后接空格展开", () => {
    expect(expandSlashCommands("hi /test now", cmds)).toBe("hi RUN TEST now");
  });
  it("prompt 含 $1 不被替换模式解释", () => {
    expect(expandSlashCommands("/x", [{ name: "x", prompt: "cost $1.00" }])).toBe("cost $1.00");
  });
  it("空 commands 原样返回", () => {
    expect(expandSlashCommands("/test", [])).toBe("/test");
  });
  it("无匹配原样返回", () => {
    expect(expandSlashCommands("plain text", cmds)).toBe("plain text");
  });
});

describe("safeUrl", () => {
  it("拒绝 javascript:", () => {
    expect(safeUrl("javascript:alert(1)")).toBeNull();
    expect(safeUrl("  JavaScript:alert(1)")).toBeNull();
  });
  it("拒绝 data:", () => {
    expect(safeUrl("data:text/html,<script>")).toBeNull();
  });
  it("拒绝 vbscript:", () => {
    expect(safeUrl("vbscript:msgbox")).toBeNull();
  });
  it("接受 http/https", () => {
    expect(safeUrl("https://example.com")).toBe("https://example.com");
    expect(safeUrl("http://x.io")).toBe("http://x.io");
  });
  it("接受 mailto/tel", () => {
    expect(safeUrl("mailto:a@b.com")).toBe("mailto:a@b.com");
    expect(safeUrl("tel:+123")).toBe("tel:+123");
  });
  it("接受相对路径/锚点", () => {
    expect(safeUrl("/path")).toBe("/path");
    expect(safeUrl("./rel")).toBe("./rel");
    expect(safeUrl("#anchor")).toBe("#anchor");
  });
});

describe("parseFileRef", () => {
  it("recognizes relative paths and bare filenames with known extensions", () => {
    expect(parseFileRef("R/app.R")).toEqual({ path: "R/app.R" });
    expect(parseFileRef("config.R")).toEqual({ path: "config.R" });
    expect(parseFileRef("src/foo.tsx")).toEqual({ path: "src/foo.tsx" });
  });
  it("captures an optional :line suffix", () => {
    expect(parseFileRef("bgtm_download_all.R:14")).toEqual({ path: "bgtm_download_all.R", line: 14 });
  });
  it("rejects non-file tokens (no known extension)", () => {
    expect(parseFileRef("modules_metadata")).toBeNull();
    expect(parseFileRef("run_module_select()")).toBeNull();
    expect(parseFileRef("plyr::rbind.fill")).toBeNull();
    expect(parseFileRef("1.5")).toBeNull();
    expect(parseFileRef("e.g")).toBeNull();
  });
  it("rejects tokens with spaces/quotes/parens or over-long input", () => {
    expect(parseFileRef("a file.R")).toBeNull();
    expect(parseFileRef("'foo.R'")).toBeNull();
    expect(parseFileRef("x".repeat(201) + ".R")).toBeNull();
  });
});

describe("markStaleToolCalls", () => {
  it("标记 result===undefined 的 tool-call", () => {
    const msgs = [{ id: "m1", role: "assistant", content: [{ type: "tool-call", toolCallId: "t1" }] }] as any;
    const { messages, changed } = markStaleToolCalls(msgs, "Interrupted");
    expect(changed).toBe(true);
    expect(messages[0].content[0].result).toBe("Interrupted");
    expect(messages[0].content[0].isError).toBe(true);
  });
  it("已有 result 的不动，changed=false", () => {
    const msgs = [{ id: "m1", role: "assistant", content: [{ type: "tool-call", toolCallId: "t1", result: "done" }] }] as any;
    const { changed } = markStaleToolCalls(msgs, "Interrupted");
    expect(changed).toBe(false);
  });
  it("非 tool-call part 不动", () => {
    const msgs = [{ id: "m1", role: "assistant", content: [{ type: "text", text: "hi" }] }] as any;
    const { changed } = markStaleToolCalls(msgs, "X");
    expect(changed).toBe(false);
  });
  it("多 part：只标记 tool-call", () => {
    const msgs = [{ id: "m1", role: "assistant", content: [
      { type: "text", text: "x" },
      { type: "tool-call", toolCallId: "t1" },
    ] }] as any;
    const { messages, changed } = markStaleToolCalls(msgs, "Interrupted");
    expect(changed).toBe(true);
    expect(messages[0].content[0].type).toBe("text");
    expect(messages[0].content[1].result).toBe("Interrupted");
  });
  it("content 非数组不崩", () => {
    const msgs = [{ id: "m1", role: "assistant", content: "raw" }] as any;
    expect(() => markStaleToolCalls(msgs, "X")).not.toThrow();
  });
});

describe("stripAttachmentData", () => {
  it("清空 image.image 和 file.data，保留元信息", () => {
    const msgs = [{ id: "u1", role: "user", content: [], attachments: [
      { name: "a.png", content: [{ type: "image", image: "BIGBASE64" }] },
      { name: "b.pdf", content: [{ type: "file", data: "BIGDATA" }] },
    ] }] as any;
    const out = stripAttachmentData(msgs);
    expect(out[0].attachments[0].content[0].image).toBe("");
    expect(out[0].attachments[0].name).toBe("a.png");
    expect(out[0].attachments[1].content[0].data).toBe("");
  });
  it("无附件消息不动", () => {
    const msgs = [{ id: "m1", role: "assistant", content: [{ type: "text", text: "x" }] }] as any;
    const out = stripAttachmentData(msgs);
    expect(out[0]).toBe(msgs[0]); // 同引用
  });
  it("strip File 对象", () => {
    const msgs = [{ id: "u1", role: "user", content: [], attachments: [
      { name: "a.txt", file: { fake: true }, content: [{ type: "text", text: "keep" }] },
    ] }] as any;
    const out = stripAttachmentData(msgs);
    expect(out[0].attachments[0].file).toBeUndefined();
    expect(out[0].attachments[0].content[0].text).toBe("keep"); // text 不剥离
  });
});

describe("extractAttachments", () => {
  it("image 类提取 image 字段", () => {
    const { attachmentData } = extractAttachments({ attachments: [
      { name: "a.png", contentType: "image/png", content: [{ type: "image", image: "URL" }] },
    ] });
    expect(attachmentData[0]).toEqual({ type: "image", name: "a.png", data: "URL", contentType: "image/png" });
  });
  it("text 类提取 text 字段", () => {
    const { attachmentData } = extractAttachments({ attachments: [
      { name: "a.txt", contentType: "text/plain", content: [{ type: "text", text: "TXT" }] },
    ] });
    expect(attachmentData[0]).toEqual({ type: "text", name: "a.txt", data: "TXT", contentType: "text/plain" });
  });
  it("file 类提取 data + mimeType fallback", () => {
    const { attachmentData } = extractAttachments({ attachments: [
      { name: "a.bin", content: [{ type: "file", data: "B64", mimeType: "application/octet-stream" }] },
    ] });
    expect(attachmentData[0].type).toBe("file");
    expect(attachmentData[0].data).toBe("B64");
    expect(attachmentData[0].contentType).toBe("application/octet-stream");
  });
  it("无 attachments 返回空", () => {
    const { attachmentData, storedAttachments } = extractAttachments({});
    expect(attachmentData).toEqual([]);
    expect(storedAttachments).toEqual([]);
  });
  it("storedAttachments strip file 对象", () => {
    const { storedAttachments } = extractAttachments({ attachments: [
      { name: "a", file: { x: 1 }, content: [] },
    ] });
    expect((storedAttachments[0] as any).file).toBeUndefined();
  });
});

describe("preprocessStreamingMarkdown", () => {
  it("无 | 短路原样返回", () => {
    const t = "plain text\nno table";
    expect(preprocessStreamingMarkdown(t)).toBe(t);
  });
  it("补全缺 separator 的表格", () => {
    const out = preprocessStreamingMarkdown("| a | b |\n| 1 | 2 |");
    const lines = out.split("\n");
    expect(lines[1]).toMatch(/^\|.*---.*\|$/);
  });
  it("已有 separator 不重复补", () => {
    const t = "| a | b |\n| --- | --- |\n| 1 | 2 |";
    expect(preprocessStreamingMarkdown(t)).toBe(t);
  });
  it("单 | 不误判为表格", () => {
    const t = "value |\nmore";
    expect(preprocessStreamingMarkdown(t)).toBe(t);
  });
  it("|| 不误判", () => {
    const t = "||\nx";
    expect(preprocessStreamingMarkdown(t)).toBe(t);
  });
});

describe("detectSlashTrigger", () => {
  it("行首 /cmd 命中", () => {
    expect(detectSlashTrigger("/dep", 4)).toEqual({ query: "dep", offset: 0 });
  });
  it("空格后 /cmd 命中", () => {
    expect(detectSlashTrigger("hi /dep", 7)).toEqual({ query: "dep", offset: 3 });
  });
  it("光标前遇空白返回 null", () => {
    expect(detectSlashTrigger("/dep now", 8)).toBeNull();
  });
  it("无 / 返回 null", () => {
    expect(detectSlashTrigger("hello", 5)).toBeNull();
  });
  it("/ 前非空白（如 a/b）不命中", () => {
    expect(detectSlashTrigger("a/b", 3)).toBeNull();
  });
});

describe("applyEdit", () => {
  const mk = (id: string, role = "user") => ({ id, role, content: [] }) as any;
  const newMsg = mk("new-user");

  it("parentId=null 从头截断后追加（编辑首条）", () => {
    const msgs = [mk("u1"), mk("a1", "assistant"), mk("u2")];
    const updated = applyEdit(msgs, null, newMsg);
    expect(updated).toEqual([newMsg]); // 全截断 + 新消息
  });

  it("parentId 命中：截断到其后再追加", () => {
    const msgs = [mk("u1"), mk("a1", "assistant"), mk("u2"), mk("a2", "assistant")];
    const updated = applyEdit(msgs, "a1", newMsg);
    expect(updated.map((m: any) => m.id)).toEqual(["u1", "a1", "new-user"]);
  });

  it("parentId 找不到:追加到末尾并重发(不丢弃)", () => {
    const msgs = [mk("u1"), mk("a1", "assistant")];
    const updated = applyEdit(msgs, "ghost", newMsg);
    // 不再丢弃:追加到末尾并重发(修复"编辑后 Update 无反应")
    expect(updated).toEqual([...msgs, newMsg]);
  });

  it("空 thread + parentId=null：仅追加新消息", () => {
    const updated = applyEdit([], null, newMsg);
    expect(updated).toEqual([newMsg]);
  });
});

describe("computeToolDepth", () => {
  it("顶层工具（无 parent）深度为 0", () => {
    const m = new Map<string, string | null | undefined>([["a", undefined]]);
    expect(computeToolDepth("a", m)).toBe(0);
  });

  it("parent 为 null 视为顶层", () => {
    const m = new Map<string, string | null | undefined>([["a", null]]);
    expect(computeToolDepth("a", m)).toBe(0);
  });

  it("单层嵌套深度为 1", () => {
    const m = new Map<string, string | null | undefined>([
      ["parent", undefined],
      ["child", "parent"],
    ]);
    expect(computeToolDepth("child", m)).toBe(1);
    expect(computeToolDepth("parent", m)).toBe(0);
  });

  it("多层嵌套逐级递增", () => {
    const m = new Map<string, string | null | undefined>([
      ["a", undefined],
      ["b", "a"],
      ["c", "b"],
      ["d", "c"],
    ]);
    expect(computeToolDepth("d", m)).toBe(3);
    expect(computeToolDepth("c", m)).toBe(2);
    expect(computeToolDepth("b", m)).toBe(1);
  });

  it("环引用不死循环（封顶返回）", () => {
    const m = new Map<string, string | null | undefined>([
      ["x", "y"],
      ["y", "x"],
    ]);
    // x→y→x 成环，seen 命中即停止，深度有限
    expect(computeToolDepth("x", m)).toBeLessThanOrEqual(2);
  });

  it("未知 parent（尚未注册）按当前累计深度返回", () => {
    const m = new Map<string, string | null | undefined>([
      ["child", "notyet"], // parent 尚未注册
    ]);
    // child→notyet(未知，get 返回 undefined 停止) → 深度 1
    expect(computeToolDepth("child", m)).toBe(1);
  });

  it("maxDepth 封顶防御超深链", () => {
    const m = new Map<string, string | null | undefined>();
    for (let i = 0; i < 100; i++) {
      m.set(`n${i}`, i === 0 ? undefined : `n${i - 1}`);
    }
    expect(computeToolDepth("n99", m, 16)).toBe(16);
  });
});

describe("themeToCssVars", () => {
  it("null/undefined/非对象返回空数组", () => {
    expect(themeToCssVars(null)).toEqual([]);
    expect(themeToCssVars(undefined)).toEqual([]);
  });

  it("token 加 --aui- 前缀,下划线转连字符", () => {
    const out = themeToCssVars({ primary: "217 91% 60%", primary_foreground: "0 0% 100%" });
    expect(out).toContainEqual(["--primary", "217 91% 60%"]);
    expect(out).toContainEqual(["--primary-foreground", "0 0% 100%"]);
  });

  it("radius 也走前缀映射", () => {
    expect(themeToCssVars({ radius: "0.75rem" })).toEqual([["--radius", "0.75rem"]]);
  });

  it("跳过 null/空字符串值", () => {
    const out = themeToCssVars({ primary: "1 2% 3%", accent: null, muted: "" } as Record<string, unknown>);
    expect(out).toEqual([["--primary", "1 2% 3%"]]);
  });

  it("数值转字符串", () => {
    expect(themeToCssVars({ foo: 42 } as Record<string, unknown>)).toEqual([["--foo", "42"]]);
  });
});

describe("formatMessageTime", () => {
  it("从 user-<ms> 解析出 HH:MM", () => {
    const ms = new Date(2024, 0, 1, 9, 5).getTime();
    expect(formatMessageTime(`user-${ms}`)).toBe("09:05");
  });
  it("从 assistant-<ms> 解析", () => {
    const ms = new Date(2024, 5, 1, 23, 59).getTime();
    expect(formatMessageTime(`assistant-${ms}`)).toBe("23:59");
  });
  it("无时间戳的 id 返回 null", () => {
    expect(formatMessageTime("tool-abc123")).toBeNull();
    expect(formatMessageTime("some-session-uuid")).toBeNull();
  });
  it("null/undefined 返回 null", () => {
    expect(formatMessageTime(null)).toBeNull();
    expect(formatMessageTime(undefined)).toBeNull();
  });
});

describe("detectMentionTrigger", () => {
  it("检测 @ 触发词", () => {
    expect(detectMentionTrigger("@calc", 5)).toEqual({ query: "calc", offset: 0 });
    expect(detectMentionTrigger("use @get", 8)).toEqual({ query: "get", offset: 4 });
  });
  it("无 @ 或 @ 前非空白返回 null", () => {
    expect(detectMentionTrigger("hello", 5)).toBeNull();
    expect(detectMentionTrigger("a@b", 3)).toBeNull();
  });
});


describe("matchSlashAction", () => {
  const actions = [
    { id: "compact", command: "compact", label: "Compact conversation" },
    { id: "context", command: "context", label: "Context usage" },
  ];

  it("matches only an exact standalone slash action", () => {
    expect(matchSlashAction("/compact", actions)?.id).toBe("compact");
    expect(matchSlashAction("  /context  ", actions)?.id).toBe("context");
    expect(matchSlashAction("/compact focus on tests", actions)).toBeUndefined();
    expect(matchSlashAction("prefix /compact", actions)).toBeUndefined();
    expect(matchSlashAction("/unknown", actions)).toBeUndefined();
  });
});

describe("mergeSlashCommands", () => {
  it("keeps configured skill metadata, deduplicates server entries, and lets actions win", () => {
    const merged = mergeSlashCommands(
      [
        { name: "github", description: "Personal skill", prompt: "/github", category: "Personal Skills" },
        { name: "compact", description: "Conflicting skill", prompt: "/compact", category: "Personal Skills" },
        { name: "GitHub", description: "Case duplicate", prompt: "/GitHub", category: "Project Skills" },
      ],
      [
        { name: "github", description: "Duplicate" },
        { name: "compact", description: "CLI compact" },
        { name: "doctor", description: "Bundled skill" },
      ],
      [{ id: "compact", command: "compact", label: "Compact conversation" }],
    );

    expect(merged).toEqual([
      { name: "github", description: "Personal skill", prompt: "/github", category: "Personal Skills" },
      { name: "doctor", description: "Bundled skill", prompt: "/doctor", category: "Claude Code" },
    ]);
  });
});


describe("workspace mention ranking and literals", () => {
  const items = [
    { kind: "file" as const, path: "src/components/AssistantUI.tsx" },
    { kind: "file" as const, path: "R/assistant_utils.R" },
    { kind: "folder" as const, path: "src/components/" },
  ];

  it("uses deterministic fuzzy ranking", () => {
    expect(rankMentionItems(items, "aui").map((x) => x.path)).toEqual([
      "R/assistant_utils.R", "src/components/AssistantUI.tsx",
    ]);
    expect(rankMentionItems(items, "components")[0].kind).toBe("folder");
  });

  it("inserts literal file/folder and active selection line ranges", () => {
    expect(mentionInsertText({ kind: "file", path: "R/app.R" })).toBe("@R/app.R");
    expect(mentionInsertText({ kind: "folder", path: "R/" })).toBe("@R/");
    expect(mentionInsertText({ kind: "file", path: "R/app.R" }, { startLine: 5, endLine: 10 }))
      .toBe("@R/app.R#L5-L10");
    expect(mentionInsertText({ kind: "file", path: "dir/my file.R" })).toBe('@"dir/my file.R"');
  });
});


describe("toolHistoryDefaultOpen", () => {
  it("keeps ordinary and large restored tool payloads collapsed by default", () => {
    expect(toolHistoryDefaultOpen(undefined, false)).toBe(false);
    expect(toolHistoryDefaultOpen({}, false)).toBe(false);
  });

  it("honors explicit overrides and keeps pending approvals visible", () => {
    expect(toolHistoryDefaultOpen({ defaultOpen: true }, false)).toBe(true);
    expect(toolHistoryDefaultOpen({ defaultOpen: false }, true)).toBe(false);
    expect(toolHistoryDefaultOpen(undefined, true)).toBe(true);
  });
});


describe("toolCallSummary", () => {
  it("uses file_path basename for Edit (not a leading boolean like replace_all)", () => {
    const args = { replace_all: false, file_path: "/mnt/x/R_dev/bgtm_download_all.R",
                    old_string: "a", new_string: "b" };
    expect(toolCallSummary("Edit", args)).toBe("bgtm_download_all.R");
  });
  it("uses command for Bash", () => {
    expect(toolCallSummary("Bash", { command: "ls -la" })).toBe("ls -la");
  });
  it("uses path basename for Read", () => {
    expect(toolCallSummary("Read", { path: "/a/b/config.yml" })).toBe("config.yml");
  });
  it("uses pattern/query/url when present", () => {
    expect(toolCallSummary("Grep", { pattern: "TODO", path: "src" })).toBe("src"); // path wins (file field)
    expect(toolCallSummary("WebSearch", { query: "shiny" })).toBe("shiny");
    expect(toolCallSummary("WebFetch", { url: "https://x.com" })).toBe("https://x.com");
  });
  it("falls back to first non-empty string, skipping booleans/numbers", () => {
    expect(toolCallSummary("X", { flag: false, n: 3, name: "hello" })).toBe("hello");
  });
  it("returns undefined when no string arg (only booleans)", () => {
    expect(toolCallSummary("X", { a: false, b: 1 })).toBeUndefined();
  });
  it("clips long values to 50 chars with ellipsis", () => {
    const long = "x".repeat(80);
    const out = toolCallSummary("Bash", { command: long })!;
    expect(out.length).toBe(51);
    expect(out.endsWith("\u2026")).toBe(true);
  });
});

describe("mergeSlashCommands argumentHint", () => {
  it("normalizes R's argument_hint to argumentHint on configured commands", () => {
    const merged = mergeSlashCommands(
      [{ name: "review", prompt: "/review", argument_hint: "[file]" } as never],
      [],
      [],
    );
    expect(merged[0]!.argumentHint).toBe("[file]");
  });

  it("keeps an already-camelCase argumentHint and populates it for live commands", () => {
    const merged = mergeSlashCommands(
      [{ name: "skillx", prompt: "/skillx", argumentHint: "<arg>" }],
      [{ name: "deploy", description: "d", argument_hint: "[env]" } as never],
      [],
    );
    const byName = Object.fromEntries(merged.map((c) => [c.name, c.argumentHint]));
    expect(byName["skillx"]).toBe("<arg>");
    expect(byName["deploy"]).toBe("[env]");
  });
});


describe("resolveToolFileReference", () => {
  const messages = [
    {
      role: "assistant",
      content: [
        { type: "tool-call", args: { file_path: "/project/old/dm.R" } },
        { type: "tool-call", args: { path: "C:\\project\\ae\\ae.R" } },
      ],
    },
    {
      role: "assistant",
      content: [
        { type: "tool-call", args: { file_path: "/project/latest/dm.R" } },
      ],
    },
  ];

  it("maps a bare filename to the most recent matching tool path", () => {
    expect(resolveToolFileReference("dm.R", messages)).toBe("/project/latest/dm.R");
    expect(resolveToolFileReference("ae.R", messages)).toBe("C:\\project\\ae\\ae.R");
  });

  it("does not rewrite explicit paths and falls back silently when unmatched", () => {
    expect(resolveToolFileReference("subfolder/dm.R", messages)).toBe("subfolder/dm.R");
    expect(resolveToolFileReference("vs.R", messages)).toBe("vs.R");
  });
});
