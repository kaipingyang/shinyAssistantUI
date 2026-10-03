import { Component, type CSSProperties, type FC, type ReactNode } from "react";
import {
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
  "Input", "DatePicker", "Checkbox", "RadioGroup", "Card", "Col", "Row",
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
  dispatch?: GenerativeUIDispatch;
}> = ({ spec, surfaceId, dispatch }) => {
  const filtered = filterA2uiSpec(spec, surfaceId);
  if (filtered === null) return null;
  return (
    <A2uiSurfaceBoundary>
      {renderGenerativeUI(filtered, a2uiRuntimeLibrary, {
        status: "done",
        ...(dispatch ? { dispatch } : {}),
      })}
    </A2uiSurfaceBoundary>
  );
};
