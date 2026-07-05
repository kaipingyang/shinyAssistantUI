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
    body = (
      <pre className="aui-artifact-code bg-muted text-foreground/90 overflow-auto rounded-md p-3 text-xs">
        <code>{artifact.content}</code>
      </pre>
    );
  } else if (artifact.type === "markdown") {
    body = (
      <pre className="aui-artifact-markdown text-foreground/90 whitespace-pre-wrap text-sm leading-relaxed">
        {artifact.content}
      </pre>
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
