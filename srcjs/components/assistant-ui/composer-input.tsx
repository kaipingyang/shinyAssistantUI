"use client";

import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  type FocusEventHandler,
  type FC,
  type RefObject,
} from "react";
import {
  ComposerPrimitive,
  INTERNAL,
  useAui,
  type Unstable_DirectiveFormatter,
  type Unstable_DirectiveSegment,
  type Unstable_TriggerAdapter,
  type Unstable_TriggerItem,
} from "@assistant-ui/react";
import {
  DirectiveNode,
  LexicalComposerInput,
  type DirectiveChipProps,
} from "@assistant-ui/react-lexical";
import { useLexicalComposerContext } from "@lexical/react/LexicalComposerContext";
import {
  $getNodeByKey,
  $getRoot,
  $isElementNode,
  $nodesOfType,
  COMMAND_PRIORITY_HIGH,
  KEY_TAB_COMMAND,
  PASTE_COMMAND,
} from "lexical";
import "@/lexical.css";
import { useShinyConfig, type ShinyActionItem, type ShinyCommand } from "@/shiny-config-context";
import { mentionInsertText, rankMentionItems } from "@/helpers";
import { ComposerTriggerPopover } from "./composer-trigger-popover";

const escapeRegExp = (value: string) =>
  value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

/**
 * One formatter handles both slash directives and literal @mentions. Keeping a
 * single parser is important because Lexical's composite parser stops at the
 * first formatter that recognizes any directive in a line.
 */
export function createComposerDirectiveFormatter(
  commands: readonly Pick<ShinyCommand, "name">[],
  actions: readonly Pick<ShinyActionItem, "id" | "command">[] = [],
): Unstable_DirectiveFormatter {
  const commandNamesList = [...new Set(commands.map((command) => command.name).filter(Boolean))];
  // Actions (deterministic controls like /context, /compact) share the same blue
  // chip visual as skills; they only diverge at submit time where matchSlashAction
  // routes an exact standalone command to the local action handler.
  const actionNameByLower = new Map(
    actions
      .map((action) => action.command ?? action.id)
      .filter(Boolean)
      .map((name) => [name.toLowerCase(), name]),
  );
  const commandNames = new Map(commandNamesList.map((name) => [name.toLowerCase(), name]));
  const allNames = [...new Set([...commandNamesList, ...actionNameByLower.values()])]
    .sort((left, right) => right.length - left.length);
  const slashPattern = allNames.length
    ? `/(?:${allNames.map(escapeRegExp).join("|")})(?=$|\\s)`
    : "(?!)";
  const tokenPattern = new RegExp(`(^|\\s)(${slashPattern}|@[^\\s]+)`, "gu");

  return {
    serialize(item) {
      // Both slash skills and slash-action controls serialize back to `/name`
      // so the submit path (expandSlashCommands / matchSlashAction) works on text.
      if (item.type === "slash" || item.type === "slash-action") {
        return item.label?.startsWith("/") ? item.label : `/${item.id}`;
      }
      return item.label;
    },
    parse(text) {
      const segments: Unstable_DirectiveSegment[] = [];
      let lastIndex = 0;
      for (const match of text.matchAll(tokenPattern)) {
        const prefix = match[1] ?? "";
        const token = match[2] ?? "";
        const tokenStart = (match.index ?? 0) + prefix.length;
        if (tokenStart > lastIndex) {
          segments.push({ kind: "text", text: text.slice(lastIndex, tokenStart) });
        }
        if (token.startsWith("/")) {
          const rawName = token.slice(1);
          const lower = rawName.toLowerCase();
          if (actionNameByLower.has(lower)) {
            const name = actionNameByLower.get(lower)!;
            segments.push({ kind: "mention", type: "slash-action", label: `/${name}`, id: name });
          } else {
            const name = commandNames.get(lower) ?? rawName;
            segments.push({ kind: "mention", type: "slash", label: `/${name}`, id: name });
          }
        } else {
          segments.push({
            kind: "mention",
            type: "mention",
            label: token,
            id: token.slice(1),
          });
        }
        lastIndex = tokenStart + token.length;
      }
      if (lastIndex < text.length) {
        segments.push({ kind: "text", text: text.slice(lastIndex) });
      }
      return segments;
    },
  };
}

function createFlatAdapter(items: readonly Unstable_TriggerItem[]): Unstable_TriggerAdapter {
  return {
    categories: () => [],
    categoryItems: () => [],
    search: (query) => {
      const lower = query.toLowerCase();
      return items.filter((item) =>
        item.id.toLowerCase().includes(lower)
        || item.label.toLowerCase().includes(lower)
        || item.description?.toLowerCase().includes(lower),
      );
    },
  };
}

function createSlashItems(
  commands: readonly ShinyCommand[],
  actions: readonly ShinyActionItem[],
): readonly Unstable_TriggerItem[] {
  return [
    ...actions.map((action) => ({
      id: action.id,
      type: "slash-action",
      label: `/${action.command ?? action.id}`,
      description: action.description ?? action.label,
      metadata: { section: action.section ?? "Actions" },
    })),
    ...commands.map((command) => ({
      id: command.name,
      type: "slash",
      label: `/${command.name}`,
      description: command.description,
      metadata: { section: command.category ?? "Commands", argumentHint: command.argumentHint },
    })),
  ];
}

const BlueDirectiveChip: FC<DirectiveChipProps> = ({
  directiveId,
  directiveType,
  label,
}) => {
  // Every directive (skill, action control, and @mention) renders the same blue
  // chip. Skills and actions stay functionally distinct at submit time via
  // matchSlashAction (skill → Claude; action → local action handler).
  // The command's argument hint is exposed as a data-* ATTRIBUTE (never a child /
  // text node), so a CSS ::after ghost (see lexical.css, gated by data-cmd-bare)
  // can show "/skill [args]" WITHOUT entering the editor content / selection /
  // submitted text. This is the fix for the earlier bug where the hint was a real
  // DOM span inside the decorator and corrupted the input.
  const { commands } = useShinyConfig();
  const argumentHint =
    directiveType === "slash"
      ? commands.find((command) => command.name === directiveId)?.argumentHint
      : undefined;
  return (
    <span
      className="aui-directive-chip inline-flex items-center rounded bg-blue-100 px-1.5 py-0.5 text-[13px] font-medium leading-none text-blue-700 dark:bg-blue-950/60 dark:text-blue-300"
      // RStudio Viewer 中外部 tailwind 工具类不可靠生效（与 contenteditable 边框同源问题）；
      // inline 写入关键蓝色作为兜底，className 仍保留以在正常环境走主题/暗色增强。
      style={{
        backgroundColor: "rgb(219, 234, 254)",
        color: "rgb(29, 78, 216)",
        borderRadius: "0.25rem",
        padding: "0.125rem 0.375rem",
      }}
      data-directive-type={directiveType}
      data-directive-id={directiveId}
      data-arg-hint={argumentHint || undefined}
    >
      {label}
    </span>
  );
};

const SlashPopover: FC<{
  formatter: Unstable_DirectiveFormatter;
  onTabCompletionChange: (handler: (() => boolean) | null) => void;
}> = ({ formatter, onTabCompletionChange }) => {
  const { commands, actionItems } = useShinyConfig();
  const items = useMemo(
    () => createSlashItems(commands, actionItems),
    [commands, actionItems],
  );
  const adapter = useMemo(() => createFlatAdapter(items), [items]);

  if (items.length === 0) return null;
  return (
    <ComposerTriggerPopover
      char="/"
      adapter={adapter}
      directive={{ formatter }}
      className="aui-slash-popover max-h-72 overflow-auto p-1"
      emptyItemsLabel="No matching commands"
      onTabCompletionChange={onTabCompletionChange}
      onMouseDown={(event) => event.preventDefault()}
    />
  );
};

const MentionPopover: FC<{ formatter: Unstable_DirectiveFormatter }> = ({ formatter }) => {
  const {
    tools,
    ideContext,
    selectionVisible,
    workspaceMentions,
    searchWorkspace,
  } = useShinyConfig();

  const items = useMemo<readonly Unstable_TriggerItem[]>(() => {
    const result: Unstable_TriggerItem[] = [];
    const activePath = ideContext?.relativePath;
    if (selectionVisible && ideContext?.hasSelection && activePath) {
      const label = mentionInsertText(
        { kind: "file", path: activePath },
        { startLine: ideContext.startLine, endLine: ideContext.endLine },
      );
      result.push({
        id: `selection:${activePath}`,
        type: "selection",
        label,
        description: "Current IDE selection",
        metadata: { section: "Selection", icon: "selection" },
      });
    }
    for (const item of workspaceMentions.items) {
      result.push({
        id: `${item.kind}:${item.path}`,
        type: item.kind,
        label: item.insertText ?? mentionInsertText(item),
        description: item.path,
        metadata: {
          section: item.kind === "folder" ? "Folders" : "Files",
          icon: item.kind,
        },
      });
    }
    for (const tool of tools) {
      result.push({
        id: tool.name,
        type: "tool",
        label: `@${tool.name}`,
        description: tool.description,
        metadata: { section: "Tools", icon: "tool" },
      });
    }
    return result;
  }, [ideContext, selectionVisible, tools, workspaceMentions.items]);

  const adapter = useMemo<Unstable_TriggerAdapter>(() => ({
    categories: () => [],
    categoryItems: () => [],
    search: (query) => {
      const lower = query.toLowerCase();
      const rankedPaths = new Set(
        rankMentionItems(workspaceMentions.items, query)
          .map((item) => `${item.kind}:${item.path}`),
      );
      return items.filter((item) => {
        if (item.type === "file" || item.type === "folder") {
          return rankedPaths.has(item.id);
        }
        return item.label.toLowerCase().includes(lower)
          || item.description?.toLowerCase().includes(lower);
      });
    },
  }), [items, workspaceMentions.items]);

  const enabled = items.length > 0 || workspaceMentions.enabled;
  const onQueryChange = useCallback((query: string, open: boolean) => {
    if (open && workspaceMentions.enabled) searchWorkspace(query);
  }, [searchWorkspace, workspaceMentions.enabled]);

  if (!enabled) return null;
  return (
    <ComposerTriggerPopover
      char="@"
      adapter={adapter}
      directive={{ formatter }}
      className="aui-mention-popover max-h-72 overflow-auto p-1"
      isLoading={workspaceMentions.loading}
      loadingLabel="Searching workspace…"
      emptyItemsLabel="No matching mentions"
      onQueryChange={onQueryChange}
      onMouseDown={(event) => event.preventDefault()}
    />
  );
};

const TabTriggerPlugin: FC<{
  slashCompletionRef: RefObject<(() => boolean) | null>;
}> = ({ slashCompletionRef }) => {
  const [editor] = useLexicalComposerContext();
  const pluginRegistry = INTERNAL.useComposerInputPluginRegistryOptional();

  useEffect(() => editor.registerCommand(
    KEY_TAB_COMMAND,
    (event) => {
      if (event.shiftKey) return false;
      const slashCompletion = slashCompletionRef.current;
      if (slashCompletion) {
        event.preventDefault();
        return slashCompletion();
      }
      if (!pluginRegistry) return false;
      for (const plugin of pluginRegistry.getPlugins()) {
        if (plugin.handleKeyDown(event)) return true;
      }
      return false;
    },
    COMMAND_PRIORITY_HIGH,
  ), [editor, pluginRegistry, slashCompletionRef]);

  return null;
};

// Paste screenshots/images (Ctrl/Cmd+V) straight into the composer as attachments.
// The custom Lexical input bypasses the stock ComposerPrimitive.Input paste handler,
// so re-add it here: image files on the clipboard -> composer.addAttachment(),
// preventing the raw blob from being dumped into the editable text. Text paste is
// left untouched (return false).
const PasteAttachmentPlugin: FC = () => {
  const [editor] = useLexicalComposerContext();
  const aui = useAui();
  useEffect(
    () =>
      editor.registerCommand(
        PASTE_COMMAND,
        (event: ClipboardEvent | InputEvent) => {
          const cd = (event as ClipboardEvent).clipboardData;
          if (!cd) return false;
          let files = Array.from(cd.files ?? []);
          if (files.length === 0) {
            files = Array.from(cd.items ?? [])
              .filter((it) => it.kind === "file" && it.type.startsWith("image/"))
              .map((it) => it.getAsFile())
              .filter((f): f is File => f != null);
          }
          if (files.length === 0) return false; // no files -> let Lexical paste text
          if (!aui.thread.getState().capabilities.attachments) return false;
          event.preventDefault();
          void Promise.all(
            files.map((file) =>
              Promise.resolve(aui.composer.addAttachment(file)).catch(() => {}),
            ),
          );
          return true;
        },
        COMMAND_PRIORITY_HIGH,
      ),
    [editor, aui],
  );
  return null;
};

// Toggle data-cmd-bare on the editor root when the content is a lone slash-command
// chip with no trailing args. Combined with the chip's data-arg-hint ATTRIBUTE + a
// CSS ::after (lexical.css), this shows "/skill [args]" as a pure-visual ghost that
// vanishes once the user types an argument — never touching editor content,
// selection, or the submitted text (the fix for the earlier real-span bug).
const CommandHintPlugin: FC = () => {
  const [editor] = useLexicalComposerContext();
  useEffect(
    () =>
      editor.registerUpdateListener(() => {
        editor.getEditorState().read(() => {
          const directives = $nodesOfType(DirectiveNode);
          const bare =
            directives.length === 1 &&
            $getRoot().getTextContent().trim() ===
              directives[0]!.getTextContent().trim();
          const el = editor.getRootElement();
          if (!el) return;
          if (bare) el.setAttribute("data-cmd-bare", "true");
          else el.removeAttribute("data-cmd-bare");
        });
      }),
    [editor],
  );
  return null;
};

const ShinyLexicalInput: FC<{
  formatter: Unstable_DirectiveFormatter;
  slashCompletionRef: RefObject<(() => boolean) | null>;
  onFocus?: FocusEventHandler<HTMLDivElement>;
}> = ({ formatter, slashCompletionRef, onFocus }) => {
  const shellRef = useRef<HTMLDivElement>(null);

  useLayoutEffect(() => {
    const shell = shellRef.current;
    const input = shell?.querySelector<HTMLElement>(".aui-lexical-input");
    const placeholder = shell?.querySelector<HTMLElement>(".aui-lexical-placeholder");
    if (!shell || !input || !placeholder) return;

    Object.assign(shell.style, { position: "relative", width: "100%" });
    Object.assign(input.style, {
      outline: "none",
      outlineStyle: "none",
      border: "none",
      borderStyle: "none",
      borderWidth: "0px",
      padding: "0px",
      width: "100%",
      minHeight: "48px",
      whiteSpace: "pre-wrap",
      wordBreak: "break-word",
      overflowWrap: "anywhere",
    });
    Object.assign(placeholder.style, {
      position: "absolute",
      top: "0px",
      left: "0px",
      pointerEvents: "none",
      userSelect: "none",
      whiteSpace: "nowrap",
    });
  }, []);

  return (
    <LexicalComposerInput
      ref={shellRef}
      placeholder="Send a message..."
      className="aui-composer-input caret-primary max-h-32 min-h-[var(--composer-min-height,2.5rem)] w-full overflow-y-auto bg-transparent px-2.5 py-1 text-base outline-none"
      autoFocus
      submitMode="enter"
      formatter={formatter}
      directiveChip={BlueDirectiveChip}
      aria-label="Message input"
      onFocus={onFocus}
    >
      <TabTriggerPlugin slashCompletionRef={slashCompletionRef} />
      <PasteAttachmentPlugin />
      <CommandHintPlugin />
    </LexicalComposerInput>
  );
};

export const ShinyComposerInput: FC<{
  onFocus?: FocusEventHandler<HTMLDivElement>;
}> = ({ onFocus }) => {
  const { commands, actionItems } = useShinyConfig();
  const slashCompletionRef = useRef<(() => boolean) | null>(null);
  const onTabCompletionChange = useCallback((handler: (() => boolean) | null) => {
    slashCompletionRef.current = handler;
  }, []);
  // Actions share the slash directive formatter so both skills and controls become
  // blue chips; submit-time routing (runtime matchSlashAction) keeps them functionally
  // distinct (skill → Claude, action → local action handler).
  const formatter = useMemo(
    () => createComposerDirectiveFormatter(commands, actionItems),
    [commands, actionItems],
  );

  return (
    <div className="relative">
      <ComposerPrimitive.Unstable_TriggerPopoverRoot>
        <SlashPopover
          formatter={formatter}
          onTabCompletionChange={onTabCompletionChange}
        />
        <MentionPopover formatter={formatter} />
        <ShinyLexicalInput
          formatter={formatter}
          slashCompletionRef={slashCompletionRef}
          onFocus={onFocus}
        />
      </ComposerPrimitive.Unstable_TriggerPopoverRoot>
    </div>
  );
};
