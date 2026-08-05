"use client";

import { Fragment, memo, useEffect, useRef, type ComponentPropsWithoutRef, type FC } from "react";
import {
  ComposerPrimitive,
  unstable_defaultDirectiveFormatter,
  unstable_useTriggerPopoverScopeContext,
  type Unstable_DirectiveFormatter,
  type Unstable_TriggerItem,
} from "@assistant-ui/react";
import { ChevronLeftIcon, ChevronRightIcon, SparklesIcon } from "lucide-react";
import { cn } from "@/lib/utils";

type IconComponent = FC<{ className?: string }>;

type DirectiveBehaviorProps = {
  /** Formatter used to serialize the selected item into composer text. */
  formatter?: Unstable_DirectiveFormatter | undefined;
  /** Called after the directive text has been inserted into the composer. */
  onInserted?: ((item: Unstable_TriggerItem) => void) | undefined;
};

type ActionBehaviorProps = {
  /** Formatter used to serialize the audit-trail chip (when `removeOnExecute` is false). */
  formatter?: Unstable_DirectiveFormatter | undefined;
  /** Invoked with the selected item at the moment of selection. */
  onExecute: (item: Unstable_TriggerItem) => void;
  /** If `true`, strip the trigger text from the composer after executing. @default false */
  removeOnExecute?: boolean | undefined;
};

type ComposerTriggerPopoverBaseProps = Omit<
  ComponentPropsWithoutRef<typeof ComposerPrimitive.Unstable_TriggerPopover>,
  "children"
> & {
  /**
   * Maps icon keys to components. Items look up via `item.metadata?.icon`
   * (string); categories look up via their `id`.
   */
  iconMap?: Record<string, IconComponent>;
  /** Fallback icon when no entry in `iconMap` matches. */
  fallbackIcon?: IconComponent;
  /** Called when this popover's own trigger query/open state changes. */
  onQueryChange?: ((query: string, open: boolean) => void) | undefined;
  /** Registers a Tab-only completion handler that inserts the highlighted item as a directive chip. */
  onTabCompletionChange?: ((handler: (() => boolean) | null) => void) | undefined;
  /** Label shown on the back button. @default "Back" */
  backLabel?: string;
  /** Label shown when no categories are available. @default "No items available" */
  emptyCategoriesLabel?: string;
  /** Label shown when no items match. @default "No matching items" */
  emptyItemsLabel?: string;
  /** Label shown while an async adapter is resolving items. @default "Loading…" */
  loadingLabel?: string;
};

type ComposerTriggerPopoverProps = ComposerTriggerPopoverBaseProps &
  (
    | {
        /** Insert-directive behavior. */
        directive: DirectiveBehaviorProps;
        action?: never;
      }
    | {
        /** Action behavior. */
        action: ActionBehaviorProps;
        directive?: never;
      }
  );

function resolveIcon(
  iconKey: string | undefined,
  iconMap: Record<string, IconComponent> | undefined,
  fallback: IconComponent,
): IconComponent {
  if (iconKey && iconMap?.[iconKey]) return iconMap[iconKey]!;
  return fallback;
}

type CategoriesProps = {
  iconMap: Record<string, IconComponent> | undefined;
  fallbackIcon: IconComponent;
  emptyLabel: string;
};

const Categories: FC<CategoriesProps> = ({
  iconMap,
  fallbackIcon,
  emptyLabel,
}) => (
  <ComposerPrimitive.Unstable_TriggerPopoverCategories>
    {(categories) => (
      <div
        data-slot="composer-trigger-popover-categories"
        className="flex flex-col py-1"
      >
        {categories.map((cat) => {
          const Icon = resolveIcon(cat.id, iconMap, fallbackIcon);
          return (
            <ComposerPrimitive.Unstable_TriggerPopoverCategoryItem
              key={cat.id}
              categoryId={cat.id}
              className="hover:bg-accent focus:bg-accent data-[highlighted]:bg-accent flex cursor-pointer items-center justify-between gap-2 px-3 py-2 text-sm transition-colors outline-none"
            >
              <span className="flex items-center gap-2">
                <Icon className="text-muted-foreground size-4" />
                {cat.label}
              </span>
              <ChevronRightIcon className="text-muted-foreground size-4" />
            </ComposerPrimitive.Unstable_TriggerPopoverCategoryItem>
          );
        })}
        {categories.length === 0 && (
          <div className="text-muted-foreground px-3 py-2 text-sm">
            {emptyLabel}
          </div>
        )}
      </div>
    )}
  </ComposerPrimitive.Unstable_TriggerPopoverCategories>
);

type ItemsProps = {
  iconMap: Record<string, IconComponent> | undefined;
  fallbackIcon: IconComponent;
  backLabel: string;
  emptyLabel: string;
  loadingLabel: string;
};

const Items: FC<ItemsProps> = ({
  iconMap,
  fallbackIcon,
  backLabel,
  emptyLabel,
  loadingLabel,
}) => {
  const { isLoading, highlightedIndex } = unstable_useTriggerPopoverScopeContext();
  const itemRefs = useRef<Map<number, HTMLElement>>(new Map());

  // 官方 TriggerPopoverItem 只翻转 data-highlighted，不做滚动；键盘上下移动时若高亮项滑出
  // max-h 容器需手动 scrollIntoView，否则滚动条不跟随高亮。
  useEffect(() => {
    const el = itemRefs.current.get(highlightedIndex);
    if (el) el.scrollIntoView({ block: "nearest" });
  }, [highlightedIndex]);

  return (
    <ComposerPrimitive.Unstable_TriggerPopoverItems>
      {(items) => (
        <div
          data-slot="composer-trigger-popover-items"
          className="flex flex-col"
        >
          <ComposerPrimitive.Unstable_TriggerPopoverBack className="text-muted-foreground hover:bg-accent flex cursor-pointer items-center gap-1.5 border-b px-3 py-2 text-xs tracking-wide uppercase transition-colors">
            <ChevronLeftIcon className="size-3.5" />
            {backLabel}
          </ComposerPrimitive.Unstable_TriggerPopoverBack>

          <div className="py-1">
            {items.map((item, index) => {
              const iconKey =
                typeof item.metadata?.icon === "string"
                  ? item.metadata.icon
                  : undefined;
              const section = typeof item.metadata?.section === "string"
                ? item.metadata.section
                : undefined;
              const previousSection =
                index > 0 &&
                typeof items[index - 1]?.metadata?.section === "string"
                  ? (items[index - 1]!.metadata!.section as string)
                  : undefined;
              const Icon = resolveIcon(iconKey, iconMap, fallbackIcon);
              return (
                <Fragment key={item.id}>
                  {section && section !== previousSection && (
                    <div
                      data-trigger-section={section}
                      className="text-muted-foreground px-3 pt-2 pb-1 text-[10px] font-semibold tracking-wide uppercase"
                    >
                      {section}
                    </div>
                  )}
                  <ComposerPrimitive.Unstable_TriggerPopoverItem
                    item={item}
                    index={index}
                    ref={(node: HTMLElement | null) => {
                      if (node) itemRefs.current.set(index, node);
                      else itemRefs.current.delete(index);
                    }}
                    data-slash-cmd={
                      item.type === "slash" ? item.id : undefined
                    }
                    data-slash-action={
                      item.type === "slash-action" ? item.id : undefined
                    }
                    data-mention-kind={
                      item.type !== "slash" && item.type !== "slash-action"
                        ? item.type
                        : undefined
                    }
                    className="hover:bg-accent focus:bg-accent data-[highlighted]:bg-accent flex w-full cursor-pointer flex-col items-start gap-0.5 px-3 py-2 text-start transition-colors outline-none"
                  >
                    <span className="flex items-center gap-2 text-sm font-medium">
                      <Icon className="text-primary size-3.5" />
                      {item.label}
                      {typeof item.metadata?.argumentHint === "string" &&
                        item.metadata.argumentHint !== "" && (
                          <span className="text-muted-foreground font-normal">
                            {item.metadata.argumentHint as string}
                          </span>
                        )}
                    </span>
                    {item.description && (
                      <span className="text-muted-foreground ms-5.5 text-xs leading-tight">
                        {item.description}
                      </span>
                    )}
                  </ComposerPrimitive.Unstable_TriggerPopoverItem>
                </Fragment>
              );
            })}
            {items.length === 0 && (
              <div className="text-muted-foreground px-3 py-2 text-sm">
                {isLoading ? loadingLabel : emptyLabel}
              </div>
            )}
          </div>
        </div>
      )}
    </ComposerPrimitive.Unstable_TriggerPopoverItems>
  );
};

const QueryObserver: FC<{
  onQueryChange: (query: string, open: boolean) => void;
}> = ({ onQueryChange }) => {
  const { query, open } = unstable_useTriggerPopoverScopeContext();
  useEffect(() => onQueryChange(query, open), [query, open, onQueryChange]);
  return null;
};

/**
 * Pre-built popover UI for a trigger-driven picker (mentions, slash commands, etc).
 * Pass exactly one of `directive` (inserts a chip) or `action` (fires a handler).
 */
const TabCompletionObserver: FC<{
  onTabCompletionChange: (handler: (() => boolean) | null) => void;
}> = ({ onTabCompletionChange }) => {
  const { open, items, highlightedIndex, selectItem } =
    unstable_useTriggerPopoverScopeContext();

  useEffect(() => {
    if (!open) {
      onTabCompletionChange(null);
      return;
    }
    const handler = () => {
      const completion = items[highlightedIndex] ?? items[0];
      if (!completion) return true;
      // Skills and action controls both complete into a directive chip; their
      // functional difference is resolved at submit time (matchSlashAction).
      selectItem(completion);
      return true;
    };
    onTabCompletionChange(handler);
    return () => onTabCompletionChange(null);
  }, [highlightedIndex, items, onTabCompletionChange, open, selectItem]);

  return null;
};

const ComposerTriggerPopoverImpl: FC<ComposerTriggerPopoverProps> = ({
  iconMap,
  fallbackIcon = SparklesIcon,
  backLabel = "Back",
  emptyCategoriesLabel = "No items available",
  emptyItemsLabel = "No matching items",
  loadingLabel = "Loading…",
  onQueryChange,
  onTabCompletionChange,
  className,
  directive,
  action,
  ...props
}) => {
  const warnedRef = useRef(false);
  if (
    process.env.NODE_ENV !== "production" &&
    !warnedRef.current &&
    Boolean(directive) === Boolean(action)
  ) {
    warnedRef.current = true;
    console.warn(
      "[assistant-ui] ComposerTriggerPopover requires exactly one of `directive` or `action` props.",
    );
  }

  return (
    <ComposerPrimitive.Unstable_TriggerPopover
      data-slot="composer-trigger-popover"
      className={cn(
        "aui-composer-trigger-popover bg-popover text-popover-foreground absolute inset-x-0 bottom-full z-50 mb-2 w-full overflow-hidden rounded-xl border shadow-lg",
        className,
      )}
      {...props}
    >
      {onQueryChange ? <QueryObserver onQueryChange={onQueryChange} /> : null}
      {onTabCompletionChange ? (
        <TabCompletionObserver
          onTabCompletionChange={onTabCompletionChange}
        />
      ) : null}
      {directive ? (
        <ComposerPrimitive.Unstable_TriggerPopover.Directive
          formatter={directive.formatter ?? unstable_defaultDirectiveFormatter}
          onInserted={directive.onInserted}
        />
      ) : action ? (
        <ComposerPrimitive.Unstable_TriggerPopover.Action
          formatter={action.formatter ?? unstable_defaultDirectiveFormatter}
          onExecute={action.onExecute}
          removeOnExecute={action.removeOnExecute}
        />
      ) : null}
      <Categories
        iconMap={iconMap}
        fallbackIcon={fallbackIcon}
        emptyLabel={emptyCategoriesLabel}
      />
      <Items
        iconMap={iconMap}
        fallbackIcon={fallbackIcon}
        backLabel={backLabel}
        emptyLabel={emptyItemsLabel}
        loadingLabel={loadingLabel}
      />
    </ComposerPrimitive.Unstable_TriggerPopover>
  );
};
ComposerTriggerPopoverImpl.displayName = "ComposerTriggerPopover";

export const ComposerTriggerPopover = memo(
  ComposerTriggerPopoverImpl,
) as FC<ComposerTriggerPopoverProps>;
