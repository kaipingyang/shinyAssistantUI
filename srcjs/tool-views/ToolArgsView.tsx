// Dumb 渲染:按 ToolView.kind 复用现有渲染件(DiffViewer / SyntaxHighlighter /
// JsonHighlighter),不含任何工具判定逻辑(那在 resolve.ts)。data-arg-view / data-arg-lang
// 供无头断言。
import type { FC } from "react";
import type { ToolView } from "./types";
import { DiffViewer } from "@/components/assistant-ui/diff-viewer";
import {
  SyntaxHighlighter,
  JsonHighlighter,
} from "@/components/assistant-ui/syntax-highlighter";

export const ToolArgsView: FC<{ view: ToolView }> = ({ view }) => {
  if (view.kind === "diff") {
    return (
      <div
        data-arg-view="diff"
        data-slot="aui_edit_diff"
        className="mt-1 max-h-96 overflow-y-auto"
      >
        <DiffViewer
          oldFile={{ content: view.oldContent, name: view.fileName }}
          newFile={{ content: view.newContent, name: view.fileName }}
          viewMode="unified"
        />
      </div>
    );
  }

  if (view.kind === "code") {
    return (
      <div
        data-arg-view="code"
        data-arg-lang={view.lang}
        data-slot="tool-fallback-args"
        className="aui-tool-fallback-args bg-muted/50 overflow-x-auto rounded-md p-2.5 text-xs"
      >
        <SyntaxHighlighter language={view.lang} code={view.code} />
      </div>
    );
  }

  // json 兜底:保留原 ShinyToolArgs 的 raw/json 双态。
  if (view.raw) {
    return (
      <div
        data-arg-view="json"
        data-slot="tool-fallback-args"
        data-args-format="raw"
        className="aui-tool-fallback-args"
      >
        <pre className="aui-tool-fallback-args-value bg-muted/50 text-foreground/90 rounded-md p-2.5 text-xs whitespace-pre-wrap">
          {view.text}
        </pre>
      </div>
    );
  }
  return (
    <div
      data-arg-view="json"
      data-slot="tool-fallback-args"
      data-args-format="json"
      className="aui-tool-fallback-args bg-muted/50 overflow-x-auto rounded-md p-2.5 text-xs"
    >
      <JsonHighlighter code={view.text} />
    </div>
  );
};
