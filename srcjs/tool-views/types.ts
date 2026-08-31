// Tool-card 参数区的富渲染模型(解耦:解析 = 纯数据,渲染 = dumb 组件)。
// 内建结构化参数视图；未知工具仍回落 json。

export type TodoItem = { content: string; status: string; activeForm?: string };
export type QueryField = { label: string; value: string; href?: string };
export type QuestionOptionSummary = { label: string; description?: string };
export type QuestionSummary = {
  question: string;
  header?: string;
  multiSelect: boolean;
  options: QuestionOptionSummary[];
  answer?: string | string[];
};

export type ToolView =
  | { kind: "diff"; oldContent: string; newContent: string; fileName?: string; startLine?: number }
  | { kind: "code"; code: string; lang: string; fileName?: string }
  | {
      kind: "table";
      text: string;
      rows: string[][];
      delimiter: "comma" | "tab";
      truncatedRows: boolean;
      truncatedColumns: boolean;
      truncatedCells: boolean;
      fileName?: string;
    }
  | {
      kind: "markdown";
      text: string;
      defaultMode: "preview" | "source";
      sourceControl: "prominent" | "subtle";
      sourceLanguage?: string;
      fileName?: string;
    }
  | { kind: "todos"; items: TodoItem[] }
  | { kind: "query"; fields: QueryField[] }
  | { kind: "questions"; items: QuestionSummary[] }
  // json 兜底保留原 raw/json 双态:object/array → 缩进 JSON;标量/非 JSON → 原样 pre。
  | { kind: "json"; text: string; raw: boolean };

// R / 任意 MCP 工具可经 on_tool_call 的 annotations 声明富渲染(扩展点)。
// 例:annotations$argsView = list(kind = "code", field = "code", lang = "r")
export type ArgsViewHint =
  | { kind: "code"; field?: string; lang?: string }
  | { kind: "diff"; oldField?: string; newField?: string; fileField?: string }
  | {
      kind: "markdown";
      field?: string;
      defaultMode?: "preview" | "source";
      sourceControl?: "prominent" | "subtle";
    };
