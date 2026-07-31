"use client";

// Plan 47 A1 — Generative-UI primitive allowlist (model/R-composed layouts).
// R (or a model that emits them) sends a message part:
//   {type:"generative-ui", spec:{root:{component, props, children}}}
// thread.tsx's `case "generative-ui"` renders <MessagePrimitive.GenerativeUI components={shinyAllowlist}/>.
// These are plain, display-only React components (the allowlist is the security boundary:
// only these names may render; props are untrusted — no dangerouslySetInnerHTML, no raw href/src).
import type { ComponentType, PropsWithChildren, ReactNode } from "react";

const Card: ComponentType<PropsWithChildren<{ title?: string; description?: string }>> = ({
  title,
  description,
  children,
}) => (
  <div data-slot="gui-card" className="bg-card text-card-foreground rounded-xl border p-4 shadow-sm">
    {title ? <div className="text-base font-semibold">{title}</div> : null}
    {description ? <div className="text-muted-foreground mt-1 text-sm">{description}</div> : null}
    {children ? <div className="mt-3">{children}</div> : null}
  </div>
);

const Stack: ComponentType<PropsWithChildren<{ gap?: "sm" | "md" | "lg"; direction?: "row" | "column" }>> = ({
  gap = "md",
  direction = "column",
  children,
}) => {
  const gapClass = gap === "sm" ? "gap-2" : gap === "lg" ? "gap-6" : "gap-4";
  const dirClass = direction === "row" ? "flex-row" : "flex-col";
  return <div data-slot="gui-stack" className={`flex ${dirClass} ${gapClass}`}>{children}</div>;
};

const Heading: ComponentType<PropsWithChildren<{ level?: 1 | 2 | 3 }>> = ({ level = 2, children }) => {
  const cls = level === 1 ? "text-xl font-bold" : level === 2 ? "text-lg font-semibold" : "text-base font-semibold";
  const Tag = `h${level}` as "h1" | "h2" | "h3";
  return (
    <Tag data-slot="gui-heading" className={cls}>
      {children}
    </Tag>
  );
};

const Text: ComponentType<PropsWithChildren> = ({ children }) => (
  <p data-slot="gui-text" className="text-foreground text-sm leading-6">
    {children}
  </p>
);

const Stat: ComponentType<{ label?: string; value?: string | number }> = ({ label, value }) => (
  <div data-slot="gui-stat" className="bg-muted/40 flex flex-col rounded-lg border p-3">
    {label != null && <span className="text-muted-foreground text-xs">{String(label)}</span>}
    <span className="text-xl font-semibold">{String(value ?? "")}</span>
  </div>
);

// The consumer allowlist passed to <MessagePrimitive.GenerativeUI components={...} />.
export const shinyAllowlist = { Card, Stack, Heading, Text, Stat } as const;

// Soft-fail for a component name not in the allowlist (instead of throwing GenerativeUIRenderError).
export const GenerativeUiFallback = ({ component }: { component: string }): ReactNode => (
  <span data-slot="gui-unknown" className="bg-muted text-muted-foreground rounded px-1.5 py-0.5 font-mono text-xs">
    unknown component: {component}
  </span>
);
