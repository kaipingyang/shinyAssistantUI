// Native-bottom rule shared by the thread's streaming follow, its scroll-to-bottom
// control and approval-card reveal. assistant-ui >= 0.15.30 counts the sticky footer
// as a content inset ("at bottom" earlier); this app keeps one scroll owner and one rule.
export type ViewportMetrics = { scrollTop: number; scrollHeight: number; clientHeight: number };

export const STREAMING_BOTTOM_TOLERANCE = 8;

export function nativeBottomDistance(metrics: ViewportMetrics): number {
  return metrics.scrollHeight - metrics.clientHeight - metrics.scrollTop;
}

export function isAwayFromNativeBottom(metrics: ViewportMetrics): boolean {
  if (metrics.scrollHeight <= metrics.clientHeight + 1) return false;
  return nativeBottomDistance(metrics) > STREAMING_BOTTOM_TOLERANCE;
}
