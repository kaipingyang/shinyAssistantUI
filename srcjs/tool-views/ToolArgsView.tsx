// Dumb 渲染:按 ToolView.kind 复用现有渲染件(DiffViewer / SyntaxHighlighter /
// JsonHighlighter),不含任何工具判定逻辑(那在 resolve.ts)。data-arg-view / data-arg-lang
// 供无头断言。
import { useState, type FC } from "react";
import { TextMessagePartProvider } from "@assistant-ui/react";
import type { ToolView } from "./types";
import { MarkdownText } from "@/components/assistant-ui/markdown-text";
import { useCopyToClipboard } from "@/hooks/use-copy-to-clipboard";
import { CheckIcon, CopyIcon } from "lucide-react";
import { DiffViewer } from "@/components/assistant-ui/diff-viewer";
import {
  SyntaxHighlighter,
  JsonHighlighter,
} from "@/components/assistant-ui/syntax-highlighter";

type MarkdownView = Extract<ToolView, { kind: "markdown" }>;

const MarkdownToolView: FC<{ view: MarkdownView; isRunning: boolean }> = ({ view, isRunning }) => {
  const [mode, setMode] = useState<"preview" | "source">(view.defaultMode);
  const { isCopied, copyToClipboard } = useCopyToClipboard();
  const previewLabel = view.defaultMode === "source" ? "Preview as Markdown" : "Preview";
  const sourceProminent = view.sourceControl === "prominent";
  const controlClass = "rounded-md px-2 py-1 text-[11px] font-medium transition-colors";

  return (
    <div
      data-arg-view="markdown"
      data-args-streaming={isRunning ? "true" : "false"}
      data-markdown-mode={mode}
      data-source-control={view.sourceControl}
      data-slot="tool-fallback-args"
      className="aui-tool-markdown mt-1 overflow-hidden rounded-md border"
    >
      <div className="bg-muted/40 flex items-center justify-between gap-2 border-b px-2 py-1.5">
        <div className="flex items-center gap-1" role="group" aria-label="Markdown view">
          <button
            type="button"
            aria-pressed={mode === "preview"}
            className={`${controlClass} ${
              mode === "preview" ? "bg-background text-foreground shadow-sm" : "text-muted-foreground hover:text-foreground"
            }`}
            onClick={() => setMode("preview")}
          >
            {previewLabel}
          </button>
          <button
            type="button"
            aria-pressed={mode === "source"}
            data-prominent={sourceProminent ? "true" : "false"}
            className={`${controlClass} ${
              mode === "source"
                ? "bg-background text-foreground shadow-sm"
                : sourceProminent
                  ? "border-primary/40 text-primary border bg-background"
                  : "text-muted-foreground hover:text-foreground"
            }`}
            onClick={() => setMode("source")}
          >
            Source
          </button>
        </div>
        <button
          type="button"
          aria-label="Copy source"
          title={isCopied ? "Copied" : "Copy source"}
          className="text-muted-foreground hover:bg-accent hover:text-foreground inline-flex items-center gap-1 rounded-md px-2 py-1 text-[11px]"
          onClick={() => copyToClipboard(view.text)}
        >
          {isCopied ? <CheckIcon className="size-3" /> : <CopyIcon className="size-3" />}
          <span>{isCopied ? "Copied" : "Copy"}</span>
        </button>
      </div>
      {mode === "preview" ? (
        <div data-markdown-preview="true" className="max-h-96 overflow-auto p-3 text-sm">
          <TextMessagePartProvider text={view.text} isRunning={isRunning}>
            <MarkdownText />
          </TextMessagePartProvider>
        </div>
      ) : (
        <div
          data-markdown-source="true"
          data-source-language={view.sourceLanguage ?? "markdown"}
          className="bg-muted/30 text-foreground/90 max-h-96 overflow-auto p-3 font-mono text-xs"
        >
          {(view.sourceLanguage ?? "markdown") === "text" ? (
            <pre className="whitespace-pre-wrap">{view.text}</pre>
          ) : (
            <SyntaxHighlighter language={view.sourceLanguage ?? "markdown"} code={view.text} />
          )}
        </div>
      )}
    </div>
  );
};

type TableView = Extract<ToolView, { kind: "table" }>;

const DelimitedTableToolView: FC<{ view: TableView }> = ({ view }) => {
  const [mode, setMode] = useState<"preview" | "source">("preview");
  const { isCopied, copyToClipboard } = useCopyToClipboard();
  const format = view.delimiter === "comma" ? "csv" : "tsv";
  const label = format.toUpperCase();
  const isTruncated = view.truncatedRows || view.truncatedColumns || view.truncatedCells;
  const width = view.rows.reduce((max, row) => Math.max(max, row.length), 0);
  const header = view.rows[0] ?? [];
  const body = view.rows.slice(1);
  const controlClass = "rounded-md px-2 py-1 text-[11px] font-medium transition-colors";

  return (
    <div
      data-arg-view="table"
      data-table-format={format}
      data-table-mode={mode}
      data-table-truncated-rows={view.truncatedRows ? "true" : "false"}
      data-table-truncated-columns={view.truncatedColumns ? "true" : "false"}
      data-table-truncated-cells={view.truncatedCells ? "true" : "false"}
      data-slot="tool-fallback-args"
      className="aui-tool-table mt-1 overflow-hidden rounded-md border"
    >
      <div className="bg-muted/40 flex items-center justify-between gap-2 border-b px-2 py-1.5">
        <div className="flex items-center gap-1" role="group" aria-label={`${label} view`}>
          <span className="text-muted-foreground px-1 text-[10px] font-semibold tracking-wide">
            {label}
          </span>
          <button
            type="button"
            aria-pressed={mode === "preview"}
            className={`${controlClass} ${
              mode === "preview" ? "bg-background text-foreground shadow-sm" : "text-muted-foreground hover:text-foreground"
            }`}
            onClick={() => setMode("preview")}
          >
            Preview
          </button>
          <button
            type="button"
            aria-pressed={mode === "source"}
            className={`${controlClass} ${
              mode === "source" ? "bg-background text-foreground shadow-sm" : "text-muted-foreground hover:text-foreground"
            }`}
            onClick={() => setMode("source")}
          >
            Source
          </button>
        </div>
        <button
          type="button"
          aria-label="Copy source"
          title={isCopied ? "Copied" : "Copy source"}
          className="text-muted-foreground hover:bg-accent hover:text-foreground inline-flex items-center gap-1 rounded-md px-2 py-1 text-[11px]"
          onClick={() => copyToClipboard(view.text)}
        >
          {isCopied ? <CheckIcon className="size-3" /> : <CopyIcon className="size-3" />}
          <span>{isCopied ? "Copied" : "Copy"}</span>
        </button>
      </div>
      {mode === "source" ? (
        <pre
          data-table-source="true"
          className="bg-muted/30 text-foreground/90 max-h-96 overflow-auto p-3 font-mono text-xs whitespace-pre"
        >
          {view.text}
        </pre>
      ) : view.rows.length === 0 ? (
        <div data-table-empty="true" className="text-muted-foreground p-3 text-xs">
          Empty {label} file
        </div>
      ) : (
        <div data-table-preview="true" className="max-h-96 overflow-auto">
          <table className="w-max min-w-full border-separate border-spacing-0 text-left text-xs">
            <thead>
              <tr>
                {Array.from({ length: width }, (_, index) => (
                  <th
                    key={index}
                    scope="col"
                    className="bg-muted sticky top-0 z-10 max-w-80 border-r border-b px-2.5 py-2 font-semibold whitespace-pre-wrap last:border-r-0"
                  >
                    {header[index] ?? ""}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {body.map((row, rowIndex) => (
                <tr key={rowIndex} className="odd:bg-background even:bg-muted/20">
                  {Array.from({ length: width }, (_, columnIndex) => (
                    <td
                      key={columnIndex}
                      className="max-w-80 border-r border-b px-2.5 py-1.5 align-top whitespace-pre-wrap last:border-r-0"
                    >
                      {row[columnIndex] ?? ""}
                    </td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
          {isTruncated && (
            <div
              data-table-truncation="true"
              className="bg-muted/60 text-muted-foreground sticky bottom-0 border-t px-3 py-1.5 text-[11px]"
            >
              Preview limited to 100 rows, 30 columns, and 500 characters per cell. Source is complete.
            </div>
          )}
        </div>
      )}
    </div>
  );
};


export const ToolArgsView: FC<{ view: ToolView; isRunning?: boolean }> = ({ view, isRunning = false }) => {
  if (view.kind === "markdown") return <MarkdownToolView view={view} isRunning={isRunning} />;
  if (view.kind === "table") return <DelimitedTableToolView view={view} />;
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
          startLine={view.startLine}
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
        {view.lang === "text" ? (
          <pre data-plain-source="true" className="text-foreground/90 font-mono whitespace-pre-wrap">
            {view.code}
          </pre>
        ) : (
          <SyntaxHighlighter language={view.lang} code={view.code} />
        )}
      </div>
    );
  }

  if (view.kind === "questions") {
    return (
      <div
        data-arg-view="questions"
        data-slot="tool-fallback-args"
        className="aui-tool-questions bg-muted/50 mt-1 flex flex-col gap-2 rounded-md p-2.5 text-xs"
      >
        {view.items.map((q, i) => (
          <div
            key={i}
            data-question-kind={q.multiSelect ? "multiple" : "single"}
            className="flex flex-col gap-1"
          >
            <div className="flex flex-wrap items-center gap-1.5">
              <span className="text-muted-foreground font-semibold">
                {q.header || `Question ${i + 1}`}
              </span>
              <span className="bg-background text-muted-foreground rounded-full border px-1.5 py-0.5 text-[10px]">
                {q.multiSelect ? "Multiple choice" : "Single choice"}
              </span>
            </div>
            <p className="text-foreground font-medium">{q.question}</p>
            {q.options.length > 0 && (
              <ul className="flex flex-col gap-0.5 ps-1">
                {q.options.map((option, oi) => {
                  const answers = q.answer === undefined
                    ? []
                    : Array.isArray(q.answer) ? q.answer : [q.answer];
                  const selected = answers.includes(option.label);
                  return (
                    <li
                      key={oi}
                      data-question-option={option.label}
                      data-question-selected={selected ? "true" : "false"}
                      className={`flex items-start gap-1.5 ${selected ? "font-medium" : ""}`}
                    >
                      <span
                        aria-label={selected ? "Selected" : "Not selected"}
                        className={selected ? "text-green-600 dark:text-green-400" : "text-muted-foreground"}
                      >
                        {selected ? (q.multiSelect ? "\u2611" : "\u25C9") : (q.multiSelect ? "\u2610" : "\u25CB")}
                      </span>
                      <span className="text-foreground/90">{option.label}</span>
                      {option.description && (
                        <span className="text-muted-foreground">{option.description}</span>
                      )}
                    </li>
                  );
                })}
              </ul>
            )}
            {q.answer !== undefined && (
              <div data-question-answer className="bg-background/70 mt-0.5 flex gap-1.5 rounded px-2 py-1">
                <span className="text-muted-foreground font-medium">Answer:</span>
                <span className="text-foreground">
                  {Array.isArray(q.answer) ? q.answer.join(", ") : q.answer}
                </span>
              </div>
            )}
          </div>
        ))}
      </div>
    );
  }

  if (view.kind === "todos") {
    return (
      <ul
        data-arg-view="todos"
        className="aui-tool-todos bg-muted/50 mt-1 flex flex-col gap-1 rounded-md p-2.5 text-xs"
      >
        {view.items.map((t, i) => {
          const done = t.status === "completed";
          const active = t.status === "in_progress";
          return (
            <li
              key={i}
              data-todo-status={t.status}
              className="aui-tool-todo flex items-start gap-2"
            >
              <span
                aria-hidden
                className={
                  done
                    ? "text-green-600"
                    : active
                      ? "text-blue-600"
                      : "text-muted-foreground"
                }
              >
                {done ? "\u2713" : active ? "\u25D0" : "\u25CB"}
              </span>
              <span className={done ? "text-muted-foreground line-through" : ""}>
                {(active && t.activeForm) || t.content}
              </span>
            </li>
          );
        })}
      </ul>
    );
  }

  if (view.kind === "query") {
    return (
      <div
        data-arg-view="query"
        className="aui-tool-query bg-muted/50 mt-1 flex flex-col gap-1 rounded-md p-2.5 text-xs"
      >
        {view.fields.map((f, i) => {
          const link = !!f.href && /^https?:\/\//i.test(f.href);
          return (
            <div key={i} data-query-field={f.label} className="flex gap-2">
              <span className="text-muted-foreground min-w-[4rem] shrink-0 font-medium">
                {f.label}
              </span>
              {link ? (
                <a
                  href={f.href}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="break-all text-blue-700 underline dark:text-blue-300"
                >
                  {f.value}
                </a>
              ) : (
                <span className="text-foreground/90 font-mono break-all">
                  {f.value}
                </span>
              )}
            </div>
          );
        })}
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
