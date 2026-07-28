// Tool-card 参数区的富渲染模型(解耦:解析 = 纯数据,渲染 = dumb 组件)。
// Phase 1 kinds: diff | code | json。后续可加 todos | query,call site 不变。

export type ToolView =
  | { kind: "diff"; oldContent: string; newContent: string; fileName?: string }
  | { kind: "code"; code: string; lang: string; fileName?: string }
  // json 兜底保留原 raw/json 双态:object/array → 缩进 JSON;标量/非 JSON → 原样 pre。
  | { kind: "json"; text: string; raw: boolean };

// R / 任意 MCP 工具可经 on_tool_call 的 annotations 声明富渲染(扩展点)。
// 例:annotations$argsView = list(kind = "code", field = "code", lang = "r")
export type ArgsViewHint =
  | { kind: "code"; field?: string; lang?: string }
  | { kind: "diff"; oldField?: string; newField?: string; fileField?: string };
