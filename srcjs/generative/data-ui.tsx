"use client";

// Plan 47 A0 — Data UI: R-driven display components, keyed by name.
// R pushes a message part `{type:"data-<name>", data}` (auto-converted to
// {type:"data", name, data}); thread.tsx's `case "data"` calls renderDataPart(part),
// which looks up DATA_UI_BY_NAME[part.name] and renders it with the R-sent `data`.
// This is the verified path (see srcjs/generative-ui-proof.test.tsx): a plain
// component table, NOT makeAssistantDataUI/dataRendererUI (that needs a scope we don't wire).
import type { FC, ReactNode } from "react";
import { FlowCanvas, type FlowCanvasEdge } from "@/components/assistant-ui/flow-canvas";

export type DataUIComponent = FC<{ data: any }>;

// A data.frame-like table: `data` may be an array of row-objects, or
// `{ columns?: string[], rows: object[] }`.
const DataTable: DataUIComponent = ({ data }) => {
  const rows: Record<string, unknown>[] = Array.isArray(data?.rows)
    ? data.rows
    : Array.isArray(data)
      ? data
      : [];
  if (!rows.length || typeof rows[0] !== "object" || rows[0] === null) {
    return (
      <pre data-slot="data-table" className="bg-muted/50 rounded-md p-2 text-xs whitespace-pre-wrap">
        {typeof data === "string" ? data : JSON.stringify(data, null, 2)}
      </pre>
    );
  }
  const cols: string[] = Array.isArray(data?.columns) ? data.columns : Object.keys(rows[0]);
  return (
    <div data-slot="data-table" className="aui-data-table max-h-80 overflow-auto rounded-md border">
      <table className="w-full border-collapse text-xs">
        <thead>
          <tr>
            {cols.map((c) => (
              <th key={c} className="bg-muted sticky top-0 border px-2 py-1 text-start font-semibold whitespace-nowrap">
                {c}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((row, ri) => (
            <tr key={ri} className={ri % 2 ? "bg-muted/40" : ""}>
              {cols.map((c) => (
                <td key={c} className="max-w-[240px] truncate border px-2 py-1">
                  {String(row[c] ?? "")}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
};

// A single stat/metric card: `{ label, value }`.
const DataStat: DataUIComponent = ({ data }) => (
  <div data-slot="data-stat" className="aui-data-stat bg-muted/40 inline-flex flex-col rounded-lg border px-3 py-2">
    {data?.label != null && <span className="text-muted-foreground text-xs">{String(data.label)}</span>}
    <span className="text-xl font-semibold">{String(data?.value ?? "")}</span>
  </div>
);

// A flow diagram: `{ nodes: [{id,label}], edges: FlowCanvasEdge[] }`.
// Revives the previously-orphaned FlowCanvas as a real, wired component.
const DataFlow: DataUIComponent = ({ data }) => {
  const nodes: Array<{ id: string; label?: string }> = Array.isArray(data?.nodes) ? data.nodes : [];
  const edges: FlowCanvasEdge[] = Array.isArray(data?.edges) ? data.edges : [];
  return (
    <FlowCanvas data-slot="data-flow" edges={edges} className="aui-data-flow flex flex-col gap-8 p-2">
      {nodes.map((n) => (
        <div
          key={n.id}
          data-flow-id={n.id}
          className="bg-card mx-auto w-fit rounded-md border px-3 py-1.5 text-sm shadow-sm"
        >
          {n.label ?? n.id}
        </div>
      ))}
    </FlowCanvas>
  );
};

// The registry. Add new R-driven display components here (Plan 47 A0/A4).
export const DATA_UI_BY_NAME: Record<string, DataUIComponent> = {
  table: DataTable,
  stat: DataStat,
  flow: DataFlow,
};

// Called from thread.tsx `case "data"`: look up by the part's data-event name.
// Unknown names render nothing (never crash) — the registry is the boundary.
export function renderDataPart(part: { name?: string; data?: unknown }): ReactNode {
  const Comp = part.name ? DATA_UI_BY_NAME[part.name] : undefined;
  return Comp ? <Comp data={part.data} /> : null;
}
