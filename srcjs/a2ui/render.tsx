import type { ToolCallMessagePartComponent } from "@assistant-ui/react";
type A2uiRenderJson =
  | null
  | boolean
  | number
  | string
  | readonly A2uiRenderJson[]
  | { readonly [key: string]: A2uiRenderJson };
type A2uiRenderObject = { readonly [key: string]: A2uiRenderJson };
import { Component, useMemo, useRef, type CSSProperties, type FC, type ReactNode } from "react";
import {
  JSONGenerativeUI,
  createActionRegistry,
  defaultGenerativeUILibrary,
  renderGenerativeUI,
  type GenerativeUIDispatch,
  type GenerativeUILibrary,
} from "@assistant-ui/react-generative-ui";
import { filterA2uiSpec } from "./protocol";


class A2uiSurfaceBoundary extends Component<{ children: ReactNode }, { failed: boolean }> {
  state = { failed: false };
  static getDerivedStateFromError() { return { failed: true }; }
  render() {
    return this.state.failed
      ? <span data-slot="aui_a2ui_render_error" role="alert">A2UI surface unavailable</span>
      : this.props.children;
  }
}
const RUNTIME_COMPONENTS = [
  "Header", "Text", "Caption", "Image", "Divider", "Button", "Select",
  "Input", "DatePicker", "Checkbox", "CheckboxGroup", "RadioGroup", "Slider",
  "Card", "Col", "Row",
  "ListView", "ListViewItem", "Markdown", "Icon",
] as const;

const image = defaultGenerativeUILibrary.Image;
if (!image) throw new Error("assistant-ui A2UI Image vocabulary is unavailable");

const safeImage = {
  ...image,
  render: ({ src, alt, size, round }: {
    src: string;
    alt: string;
    size?: "sm" | "md" | "lg" | number;
    round?: boolean;
  }) => {
    const numericSize = typeof size === "number" ? size : undefined;
    const style: CSSProperties | undefined = numericSize === undefined
      ? undefined
      : round
        ? { width: `${numericSize}px`, height: `${numericSize}px` }
        : { maxWidth: `${numericSize}px` };
    return (
      <img
        data-aui="image"
        data-aui-size={numericSize === undefined ? size : undefined}
        data-aui-round={round || undefined}
        src={src}
        alt={alt}
        style={style}
        referrerPolicy="no-referrer"
      />
    );
  },
};

export const a2uiRuntimeLibrary: GenerativeUILibrary = Object.fromEntries(
  RUNTIME_COMPONENTS.map((name) => {
    const entry = name === "Image" ? safeImage : defaultGenerativeUILibrary[name];
    if (!entry) throw new Error(`assistant-ui A2UI component ${name} is unavailable`);
    return [name, entry];
  }),
);

export const A2uiRuntimeView: FC<{
  spec: unknown;
  surfaceId: string;
  operations?: readonly unknown[];
  dispatch?: GenerativeUIDispatch;
}> = ({ spec, surfaceId, operations, dispatch }) => {
  const filtered = filterA2uiSpec(spec, surfaceId);
  const dispatchRef = useRef(dispatch);
  dispatchRef.current = dispatch;
  const present = useMemo(() => {
    const generative = new JSONGenerativeUI({
      library: a2uiRuntimeLibrary,
      actions: createActionRegistry({
        "a2ui:action": ({ payload }) => dispatchRef.current?.(payload),
      }),
    });
    return generative.present({ display: "standalone" });
  }, []);
  if (filtered === null && !operations) return null;
  if (operations) {
    const Present = present.render as ToolCallMessagePartComponent<
      A2uiRenderObject,
      unknown
    >;
    return (
      <A2uiSurfaceBoundary>
        <Present
          type="tool-call"
          toolCallId={`a2ui:${surfaceId}`}
          toolName="present"
          args={(filtered ?? {}) as A2uiRenderObject}
          argsText={JSON.stringify(filtered ?? {})}
          result={{}}
          artifact={{ a2ui: operations }}
          status={{ type: "complete" }}
          addResult={() => undefined}
          resume={() => undefined}
          respondToApproval={async () => undefined}
        />
      </A2uiSurfaceBoundary>
    );
  }
  return (
    <A2uiSurfaceBoundary>
      {renderGenerativeUI(filtered, a2uiRuntimeLibrary, {
        status: "done",
        ...(dispatch ? { dispatch } : {}),
      })}
    </A2uiSurfaceBoundary>
  );
};
