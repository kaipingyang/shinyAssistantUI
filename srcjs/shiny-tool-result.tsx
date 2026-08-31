import type { ReactNode } from "react";
import { safeUrl } from "./helpers";
import {
  JsonHighlighter,
  SyntaxHighlighter,
} from "./components/assistant-ui/syntax-highlighter";

// inline markdown: **bold** *italic* `code` [link](url)（safeUrl 过滤 scheme）
function parseInline(text: string): ReactNode[] {
  const pattern = /(\*\*([^*\n]+)\*\*|\*([^*\n]+)\*|`([^`\n]+)`|\[([^\]\n]+)\]\(([^)\n]+)\))/g;
  const nodes: ReactNode[] = [];
  let lastIndex = 0, key = 0;
  let m: RegExpExecArray | null;
  while ((m = pattern.exec(text)) !== null) {
    if (m.index > lastIndex) nodes.push(text.slice(lastIndex, m.index));
    if (m[2] !== undefined) nodes.push(<strong key={key++}>{m[2]}</strong>);
    else if (m[3] !== undefined) nodes.push(<em key={key++}>{m[3]}</em>);
    else if (m[4] !== undefined) nodes.push(<code key={key++} className="bg-muted rounded px-1 py-0.5 font-mono text-xs">{m[4]}</code>);
    else if (m[5] !== undefined && m[6] !== undefined) {
      const href = safeUrl(m[6]);
      nodes.push(href === null
        ? <span key={key++}>{m[5]}</span>
        : <a key={key++} href={href} target="_blank" rel="noopener noreferrer" className="text-primary underline">{m[5]}</a>);
    }
    lastIndex = pattern.lastIndex;
  }
  if (lastIndex < text.length) nodes.push(text.slice(lastIndex));
  return nodes;
}

function SimpleMarkdown({ text }: { text: string }) {
  const nodes: ReactNode[] = [];
  const lines = text.split("\n");
  let i = 0, key = 0;
  while (i < lines.length) {
    const line = lines[i];
    if (line.startsWith("```")) {
      const lang = line.slice(3).trim() || "text";
      const code: string[] = []; i++;
      while (i < lines.length && !lines[i].startsWith("```")) { code.push(lines[i]); i++; }
      i++;
      nodes.push(
        <div key={key++} className="bg-muted/50 my-1.5 overflow-x-auto rounded-md p-2.5 text-xs">
          <SyntaxHighlighter language={lang} code={code.join("\n")} />
        </div>,
      );
      continue;
    }
    const hm = line.match(/^(#{1,3})\s+(.+)/);
    if (hm) { const L = hm[1].length; const Tag = `h${L}` as "h1"|"h2"|"h3"; nodes.push(<Tag key={key++} className="mt-2 mb-1 font-semibold" style={{fontSize: L===1?"15px":L===2?"14px":"13px"}}>{parseInline(hm[2])}</Tag>); i++; continue; }
    if (/^---+$/.test(line.trim())) { nodes.push(<hr key={key++} className="my-2 border-border" />); i++; continue; }
    if (/^[-*+]\s/.test(line)) { const it: ReactNode[] = []; while (i < lines.length && /^[-*+]\s/.test(lines[i])) { it.push(<li key={i}>{parseInline(lines[i].slice(2))}</li>); i++; } nodes.push(<ul key={key++} className="my-1 list-disc ps-5 text-sm">{it}</ul>); continue; }
    if (/^\d+\.\s/.test(line)) { const it: ReactNode[] = []; while (i < lines.length && /^\d+\.\s/.test(lines[i])) { it.push(<li key={i}>{parseInline(lines[i].replace(/^\d+\.\s/, ""))}</li>); i++; } nodes.push(<ol key={key++} className="my-1 list-decimal ps-5 text-sm">{it}</ol>); continue; }
    if (line.trim() === "") { i++; continue; }
    const para: string[] = [];
    while (i < lines.length && lines[i].trim() !== "" && !lines[i].startsWith("#") && !lines[i].startsWith("```") && !/^[-*+]\s/.test(lines[i]) && !/^\d+\.\s/.test(lines[i]) && !/^---+$/.test(lines[i].trim())) { para.push(lines[i]); i++; }
    if (para.length) nodes.push(<p key={key++} className="my-1 text-sm leading-relaxed">{parseInline(para.join(" "))}</p>);
  }
  return <div className="aui-tool-md">{nodes}</div>;
}

function TableResult({ data }: { data: unknown }) {
  let rows: Record<string, unknown>[];
  try {
    const parsed = typeof data === "string" ? JSON.parse(data) : data;
    if (!Array.isArray(parsed) || parsed.length === 0 || typeof parsed[0] !== "object" || parsed[0] === null) throw new Error("nt");
    rows = parsed as Record<string, unknown>[];
  } catch {
    const d = typeof data === "string" ? data : JSON.stringify(data, null, 2);
    return <pre className="bg-muted/50 rounded-md p-2 text-xs whitespace-pre-wrap">{d}</pre>;
  }
  const cols = Object.keys(rows[0]);
  return (
    <div className="aui-tool-table max-h-64 overflow-auto rounded-md border">
      <table className="w-full border-collapse text-xs">
        <thead><tr>{cols.map((c) => <th key={c} className="bg-muted sticky top-0 border px-2 py-1 text-start font-semibold whitespace-nowrap">{c}</th>)}</tr></thead>
        <tbody>{rows.map((row, ri) => <tr key={ri} className={ri % 2 ? "bg-muted/40" : ""}>{cols.map((c) => <td key={c} className="max-w-[200px] truncate border px-2 py-1">{String(row[c] ?? "")}</td>)}</tr>)}</tbody>
      </table>
    </div>
  );
}

function autoJsonText(result: unknown): string | undefined {
  let value = result;
  if (typeof result === "string") {
    const trimmed = result.trim();
    if (!((trimmed.startsWith("{") && trimmed.endsWith("}")) ||
          (trimmed.startsWith("[") && trimmed.endsWith("]")))) return undefined;
    try {
      value = JSON.parse(trimmed);
    } catch {
      return undefined;
    }
  }
  if (value === null || typeof value !== "object") return undefined;
  try {
    return JSON.stringify(value, null, 2);
  } catch {
    return undefined;
  }
}

function JsonResult({ code }: { code: string }) {
  return (
    <div
      data-result-view="json"
      className="aui-tool-result-json bg-muted/50 overflow-x-auto rounded-md p-2.5 text-xs"
    >
      <JsonHighlighter code={code} />
    </div>
  );
}

export function ShinyToolResult({
  result, resultType, resultLang, isError, annotations,
}: {
  result: unknown; resultType: string; resultLang: string; isError: boolean;
  annotations?: Record<string, unknown>;
}) {
  const display = typeof result === "string" ? result : JSON.stringify(result, null, 2);
  if (isError) return <pre data-result-view="console" className="text-destructive bg-destructive/5 rounded-md p-2 font-mono text-xs whitespace-pre-wrap">{display}</pre>;
  switch (resultType) {
    case "auto": {
      const jsonText = autoJsonText(result);
      if (jsonText !== undefined) return <JsonResult code={jsonText} />;
      return <pre data-result-view="console" className="bg-muted/50 rounded-md p-2 font-mono text-xs whitespace-pre-wrap">{display}</pre>;
    }
    case "json": {
      const jsonText = autoJsonText(result);
      return jsonText !== undefined
        ? <JsonResult code={jsonText} />
        : <pre data-result-view="console" className="bg-muted/50 rounded-md p-2 font-mono text-xs whitespace-pre-wrap">{display}</pre>;
    }
    case "markdown": return <SimpleMarkdown text={display} />;
    case "table": return <TableResult data={result} />;
    case "code": return (
      <div data-result-view="code" className="bg-muted/50 overflow-x-auto rounded-md p-2.5 text-xs">
        <SyntaxHighlighter language={resultLang} code={display} />
      </div>
    );
    case "image": return <img src={typeof result === "string" ? result : ""} alt="tool result" className="max-w-full rounded-md border" />;
    case "file": {
      const filename = (annotations?.resultFilename as string | undefined) ?? "download";
      const src = typeof result === "string" ? result : "";
      return <button onClick={() => { const a = document.createElement("a"); a.href = src; a.download = filename; document.body.appendChild(a); a.click(); a.remove(); }} className="bg-muted hover:bg-muted/70 inline-flex items-center gap-1.5 rounded-md border px-3 py-1.5 text-xs">{filename}</button>;
    }
    case "html": {
      const sandboxed = annotations?.htmlSandbox !== false;
      const hRaw = annotations?.resultHeight as string | number | undefined;
      const height = hRaw == null ? "240px" : typeof hRaw === "number" ? `${hRaw}px` : hRaw;
      if (sandboxed) return <iframe className="aui-html-sandbox w-full rounded-md border bg-white" data-sandboxed="true" sandbox="" srcDoc={display} title="tool result" style={{ height }} />;
      return <div className="aui-html-trusted text-sm" dangerouslySetInnerHTML={{ __html: display }} />;
    }
    default: return <pre data-result-view="console" className="bg-muted/50 rounded-md p-2 font-mono text-xs whitespace-pre-wrap">{display}</pre>;
  }
}
