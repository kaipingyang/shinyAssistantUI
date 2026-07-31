import { TextMessagePartProvider } from "@assistant-ui/react";
import { MarkdownText } from "@/components/assistant-ui/markdown-text";
import { SyntaxHighlighter } from "@/components/assistant-ui/syntax-highlighter";

export interface Artifact {
  id: string;
  title: string;
  type: string;
  content: string;
  lang?: string;
}

// Artifacts 右侧面板:markdown / code / html(sandbox iframe)/ text。
export function ArtifactPanel({
  artifact,
  onClose,
}: {
  artifact: Artifact;
  onClose: () => void;
}) {
  let body: React.ReactNode;
  if (artifact.type === "html") {
    body = (
      <iframe
        className="aui-artifact-html h-full w-full border-0 bg-white"
        sandbox=""
        srcDoc={artifact.content}
        title={artifact.title}
      />
    );
  } else if (artifact.type === "code") {
    // A3: real syntax highlighting via the same PrismLight highlighter as chat code blocks,
    // honoring the artifact's `lang` (previously a plain <pre>, lang ignored).
    body = (
      <div className="aui-artifact-code overflow-auto rounded-md">
        <SyntaxHighlighter language={artifact.lang || "text"} code={artifact.content} />
      </div>
    );
  } else if (artifact.type === "markdown") {
    // A3: real Markdown rendering (headings/tables/lists/highlighted code) via the SAME
    // MarkdownText used in chat, fed an arbitrary string through TextMessagePartProvider
    // (MarkdownTextPrimitive is message-context-bound; the provider supplies that context).
    body = (
      <div className="aui-artifact-markdown aui-md">
        <TextMessagePartProvider text={artifact.content} isRunning={false}>
          <MarkdownText />
        </TextMessagePartProvider>
      </div>
    );
  } else {
    body = (
      <pre className="aui-artifact-text text-foreground/90 whitespace-pre-wrap text-sm">
        {artifact.content}
      </pre>
    );
  }

  return (
    <div className="aui-artifact-panel bg-background flex h-full flex-col border-l">
      <div className="flex shrink-0 items-center justify-between border-b px-3 py-2">
        <span className="aui-artifact-title text-foreground text-sm font-semibold">
          {artifact.title}
        </span>
        <button
          onClick={onClose}
          title="Close"
          className="aui-artifact-close text-muted-foreground hover:text-foreground text-lg leading-none"
        >
          ×
        </button>
      </div>
      <div className={"min-h-0 flex-1 overflow-auto " + (artifact.type === "html" ? "" : "p-3")}>
        {body}
      </div>
    </div>
  );
}
