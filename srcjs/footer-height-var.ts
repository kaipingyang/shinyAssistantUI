import { useLayoutEffect, type RefObject } from "react";

export const FOOTER_HEIGHT_VAR = "--aui-thread-footer-height";
const FOOTER_SELECTOR = '[data-slot="aui_thread-viewport-footer"]';

// Publish the sticky thread footer's height on the viewport so content that sticks
// to the bottom (a long form's button row) can sit just above the composer.
export function observeFooterHeight(viewport: HTMLElement): () => void {
  const footer = viewport.querySelector<HTMLElement>(FOOTER_SELECTOR);
  if (!footer || typeof ResizeObserver === "undefined") return () => undefined;
  const publish = () => {
    viewport.style.setProperty(FOOTER_HEIGHT_VAR, `${Math.ceil(footer.getBoundingClientRect().height)}px`);
  };
  publish();
  const observer = new ResizeObserver(publish);
  observer.observe(footer);
  return () => {
    observer.disconnect();
    viewport.style.removeProperty(FOOTER_HEIGHT_VAR);
  };
}

export function useFooterHeightVar(viewportRef: RefObject<HTMLElement | null>): void {
  useLayoutEffect(() => {
    const viewport = viewportRef.current;
    return viewport ? observeFooterHeight(viewport) : undefined;
  }, [viewportRef]);
}
