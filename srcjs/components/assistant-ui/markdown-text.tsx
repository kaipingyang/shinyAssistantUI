"use client";

import "@assistant-ui/react-markdown/styles/dot.css";

import {
  type CodeHeaderProps,
  MarkdownTextPrimitive,
  escapeCurrencyDollars,
  normalizeMathDelimiters,
  unstable_memoizeMarkdownComponents as memoizeMarkdownComponents,
  useIsMarkdownCodeBlock,
} from "@assistant-ui/react-markdown";
import remarkGfm from "remark-gfm";
import remarkMath from "remark-math";
import rehypeKatex from "rehype-katex";
import { type FC, memo, useState, useMemo } from "react";
import { CheckIcon, CopyIcon, LoaderCircleIcon, PlayIcon } from "lucide-react";

import { TooltipIconButton } from "@/components/assistant-ui/tooltip-icon-button";
import { SyntaxHighlighter, resolveCodeLanguage } from "@/components/assistant-ui/syntax-highlighter";
import { DiffCodeBlock } from "@/components/assistant-ui/diff-viewer";
import { cn } from "@/lib/utils";
import { safeUrl, parseFileRef } from "@/helpers";
import { useShinyConfig } from "@/shiny-config-context";
import { useOpeningFile } from "@/hooks/use-opening-file";
import { useResolvedFileReference } from "@/file-reference";

export const preprocessLatexMarkdown = (text: string): string =>
  escapeCurrencyDollars(normalizeMathDelimiters(text));

export const timedOwnedMarkdownPreprocess = (
  text: string,
  preprocess: (value: string) => string,
  reportDurationUs: (durationUs: number) => void,
  now: () => number = () => performance.now(),
): string => {
  const started = now();
  const result = preprocess(text);
  const durationUs = Math.min(
    Number.MAX_SAFE_INTEGER,
    Math.max(0, Math.round((now() - started) * 1000)),
  );
  try { reportDurationUs(durationUs); } catch { /* optional telemetry is fail-open */ }
  return result;
};

const MarkdownTextImpl = () => {
  // LaTeX 数学(Plan 34,opt-in via assistantUIServer(latex=TRUE))。默认关。
  const { latex, recordOwnedMarkdownPreprocess } = useShinyConfig();
  const remarkPlugins = useMemo(
    () => (latex ? [remarkGfm, remarkMath] : [remarkGfm]),
    [latex],
  );
  const rehypePlugins = useMemo(
    () => (latex ? [[rehypeKatex, { strict: false }]] : []),
    [latex],
  );
  const preprocess = useMemo(() => {
    if (!latex) return undefined;
    if (!recordOwnedMarkdownPreprocess) return preprocessLatexMarkdown;
    return (text: string) => timedOwnedMarkdownPreprocess(
      text, preprocessLatexMarkdown, recordOwnedMarkdownPreprocess,
    );
  }, [latex, recordOwnedMarkdownPreprocess]);
  return (
    <MarkdownTextPrimitive
      preprocess={preprocess}
      remarkPlugins={remarkPlugins}
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      rehypePlugins={rehypePlugins as any}
      className="aui-md"
      components={defaultComponents}
      componentsByLanguage={{
        diff: { SyntaxHighlighter: DiffCodeBlock },
        patch: { SyntaxHighlighter: DiffCodeBlock },
      }}
      defer
    />
  );
};

export const MarkdownText = memo(MarkdownTextImpl);

const CodeHeader: FC<CodeHeaderProps> = ({ language, code }) => {
  const { isCopied, copyToClipboard } = useCopyToClipboard();
  const { onRunInConsole } = useShinyConfig();
  const onCopy = () => {
    if (!code || isCopied) return;
    copyToClipboard(code);
  };
  // 仅对明确的 R 代码块、且 addin 提供了 console 执行能力时,显示"在 R Console 运行"。
  const isR = typeof language === "string" && /^(r|rscript)$/i.test(language.trim());
  const canRun = isR && !!onRunInConsole && !!code;

  return (
    <div className="aui-code-header-root border-border/50 bg-muted/50 mt-3 flex items-center justify-between rounded-t-xl border border-b-0 px-3.5 py-1.5 text-xs">
      <span className="aui-code-header-language text-muted-foreground font-medium lowercase">
        {resolveCodeLanguage(language)}
      </span>
      <span className="flex items-center gap-1">
        {canRun && (
          <TooltipIconButton
            tooltip="Run in R Console"
            data-run-in-console=""
            onClick={() => onRunInConsole!(code!)}
          >
            <PlayIcon className="animate-in zoom-in-75 fade-in duration-150" />
          </TooltipIconButton>
        )}
        <TooltipIconButton tooltip="Copy" onClick={onCopy}>
          {!isCopied && (
            <CopyIcon className="animate-in zoom-in-75 fade-in duration-150" />
          )}
          {isCopied && (
            <CheckIcon className="animate-in zoom-in-50 fade-in duration-200 ease-out" />
          )}
        </TooltipIconButton>
      </span>
    </div>
  );
};

const useCopyToClipboard = ({
  copiedDuration = 3000,
}: {
  copiedDuration?: number;
} = {}) => {
  const [isCopied, setIsCopied] = useState<boolean>(false);

  const copyToClipboard = (value: string) => {
    if (!value || typeof navigator === "undefined" || !navigator.clipboard) {
      return;
    }

    navigator.clipboard.writeText(value).then(
      () => {
        setIsCopied(true);
        setTimeout(() => setIsCopied(false), copiedDuration);
      },
      () => {},
    );
  };

  return { isCopied, copyToClipboard };
};

const defaultComponents = memoizeMarkdownComponents({
  h1: ({ className, ...props }) => (
    <h1
      className={cn(
        "aui-md-h1 mt-5 mb-2 scroll-m-20 text-xl font-semibold first:mt-0 last:mb-0",
        className,
      )}
      {...props}
    />
  ),
  h2: ({ className, ...props }) => (
    <h2
      className={cn(
        "aui-md-h2 mt-5 mb-2 scroll-m-20 text-lg font-semibold first:mt-0 last:mb-0",
        className,
      )}
      {...props}
    />
  ),
  h3: ({ className, ...props }) => (
    <h3
      className={cn(
        "aui-md-h3 mt-4 mb-1.5 scroll-m-20 text-base font-semibold first:mt-0 last:mb-0",
        className,
      )}
      {...props}
    />
  ),
  h4: ({ className, ...props }) => (
    <h4
      className={cn(
        "aui-md-h4 mt-3.5 mb-1 scroll-m-20 text-base font-medium first:mt-0 last:mb-0",
        className,
      )}
      {...props}
    />
  ),
  h5: ({ className, ...props }) => (
    <h5
      className={cn(
        "aui-md-h5 mt-3 mb-1 text-sm font-semibold first:mt-0 last:mb-0",
        className,
      )}
      {...props}
    />
  ),
  h6: ({ className, ...props }) => (
    <h6
      className={cn(
        "aui-md-h6 mt-3 mb-1 text-sm font-medium first:mt-0 last:mb-0",
        className,
      )}
      {...props}
    />
  ),
  p: ({ className, ...props }) => (
    <p
      className={cn(
        "aui-md-p my-3 leading-relaxed first:mt-0 last:mb-0",
        className,
      )}
      {...props}
    />
  ),
  a: ({ className, href, ...props }) => {
    // 外链在新标签打开（RStudio Viewer 会交给系统浏览器），不顶掉聊天界面；
    // safeUrl 过滤 javascript:/data: 等危险 scheme（不安全则渲染为不可点文本）。
    const safe = typeof href === "string" ? safeUrl(href) : null;
    return (
      <a
        className={cn(
          "aui-md-a aui-web-link",
          className,
        )}
        {...(safe ? { href: safe } : {})}
        target="_blank"
        rel="noopener noreferrer"
        {...props}
      />
    );
  },
  blockquote: ({ className, ...props }) => (
    <blockquote
      className={cn(
        "aui-md-blockquote border-muted-foreground/30 text-muted-foreground my-3 border-s-2 ps-4",
        className,
      )}
      {...props}
    />
  ),
  ul: ({ className, ...props }) => (
    <ul
      className={cn(
        "aui-md-ul marker:text-muted-foreground my-3 ms-5 list-disc [&>li]:mt-1",
        className,
      )}
      {...props}
    />
  ),
  ol: ({ className, ...props }) => (
    <ol
      className={cn(
        "aui-md-ol marker:text-muted-foreground my-3 ms-5 list-decimal [&>li]:mt-1",
        className,
      )}
      {...props}
    />
  ),
  hr: ({ className, ...props }) => (
    <hr
      className={cn("aui-md-hr border-muted-foreground/20 my-3", className)}
      {...props}
    />
  ),
  table: ({ className, ...props }) => (
    // 宽表格用横向滚动容器兜底，避免右侧列被消息宽度裁掉（#4）。
    <div className="aui-md-table-wrap my-3 w-full overflow-x-auto">
      <table
        className={cn(
          "aui-md-table min-w-full border-separate border-spacing-0",
          className,
        )}
        {...props}
      />
    </div>
  ),
  th: ({ className, ...props }) => (
    <th
      className={cn(
        "aui-md-th bg-muted px-3 py-1.5 text-start font-medium first:rounded-ss-lg last:rounded-se-lg [[align=center]]:text-center [[align=right]]:text-right",
        className,
      )}
      {...props}
    />
  ),
  td: ({ className, ...props }) => (
    <td
      className={cn(
        "aui-md-td border-muted-foreground/20 border-s border-b px-3 py-1.5 text-start last:border-e [[align=center]]:text-center [[align=right]]:text-right",
        className,
      )}
      {...props}
    />
  ),
  tr: ({ className, ...props }) => (
    <tr
      className={cn(
        "aui-md-tr m-0 border-b p-0 first:border-t [&:last-child>td:first-child]:rounded-es-lg [&:last-child>td:last-child]:rounded-ee-lg",
        className,
      )}
      {...props}
    />
  ),
  li: ({ className, ...props }) => (
    <li className={cn("aui-md-li leading-relaxed", className)} {...props} />
  ),
  strong: ({ className, ...props }) => (
    <strong
      className={cn("aui-md-strong font-semibold", className)}
      {...props}
    />
  ),
  sup: ({ className, ...props }) => (
    <sup
      className={cn("aui-md-sup [&>a]:text-xs [&>a]:no-underline", className)}
      {...props}
    />
  ),
  pre: ({ className, ...props }) => (
    <pre
      className={cn(
        "aui-md-pre border-border/50 bg-muted/30 overflow-x-auto rounded-t-none rounded-b-xl border border-t-0 p-3.5 text-[13px] leading-relaxed",
        className,
      )}
      {...props}
    />
  ),
  code: function Code({ className, children, ...props }) {
    const isCodeBlock = useIsMarkdownCodeBlock();
    const { onOpenFile, fileReferences } = useShinyConfig();
    const { opening, failed, open: openFile } = useOpeningFile(onOpenFile);
    const text = typeof children === "string"
      ? children
      : Array.isArray(children) ? children.filter((c) => typeof c === "string").join("") : "";
    const fileRef = !isCodeBlock ? parseFileRef(text) : null;
    const confirmedPath = useResolvedFileReference(onOpenFile ? fileReferences : undefined, fileRef?.path);
    if (fileRef && confirmedPath && onOpenFile) {
      return (
        <code
          role="button"
          tabIndex={0}
          data-file-ref={fileRef.path}
          data-file-open-state={opening ? "opening" : failed ? "failed" : "idle"}
          aria-busy={opening}
          data-resolved-file={confirmedPath}
          aria-label={opening ? `Opening ${confirmedPath}` : failed ? `Could not open ${confirmedPath}. Retry`
            : `Open ${confirmedPath} in RStudio`}
          title={opening ? `Opening ${confirmedPath}…` : failed ? `Could not open ${confirmedPath}. Click to retry.`
            : `Open ${confirmedPath}${fileRef.line ? ":" + fileRef.line : ""} in RStudio`}
          onClick={() => openFile(confirmedPath, fileRef.line)}
          onKeyDown={(event) => {
            if (event.key === "Enter" || event.key === " ") {
              event.preventDefault();
              openFile(confirmedPath, fileRef.line);
            }
          }}
          className={cn(
            "aui-md-inline-code aui-file-ref bg-blue-500/10 text-blue-700 dark:text-blue-300 hover:bg-blue-500/20 cursor-pointer rounded-md px-1.5 py-0.5 font-mono text-[0.85em] underline decoration-dotted underline-offset-2",
            opening && "inline-flex items-center gap-1",
            failed && "text-destructive",
            className,
          )}
          {...props}
        >
          {opening ? (
            <><LoaderCircleIcon aria-hidden="true" className="size-3 animate-spin" /><span>Opening…</span></>
          ) : children}
        </code>
      );
    }
    return (
      <code
        data-file-ref-candidate={fileRef?.path}
        className={cn(
          !isCodeBlock &&
            "aui-md-inline-code rounded-md px-1.5 py-0.5 font-mono text-[0.85em]",
          !isCodeBlock && (fileRef ? "bg-muted text-foreground" : "bg-blue-500/10 text-blue-700 dark:text-blue-300"),
          className,
        )}
        {...props}
      >
        {children}
      </code>
    );
  },
  CodeHeader,
  SyntaxHighlighter,
});
