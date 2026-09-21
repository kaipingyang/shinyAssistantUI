// Generated table for diagnostics-v1. The R-side canonical artifact must generate this file byte-for-byte.
export const DIAGNOSTICS_LIMITS = {"batchRows":100,"queueRows":1000,"rowBytes":16384} as const;
export const DIAGNOSTICS_EVENT_SPEC = {
  frontend_mount: {}, frontend_unmount: {}, shiny_connected: {}, shiny_disconnected: {},
  run_state: { phase: ["queued", "connecting", "running", "complete", "error", "cancelled"] },
  run_stage: { stage: ["streaming", "finalizing"] },
  chunk_summary: { count: "safe-int", bytes: "safe-int" },
  tool_delta_summary: { count: "safe-int", bytes: "safe-int", toolCount: "safe-int" },
  tool_summary: { count: "safe-int", durationUs: "safe-int", outcome: ["success", "error", "cancelled", "denied", "unknown"] },
  ui_counts: { messageCount: "safe-int", toolCardCount: "safe-int", domCardCount: "safe-int" },
  owned_commit_summary: { messageCount: "safe-int", toolCount: "safe-int" },
  owned_markdown_preprocess_summary: { count: "safe-int", durationUs: "safe-int", maxUs: "safe-int" },
  longtask_summary: { count: "safe-int", durationUs: "safe-int", maxUs: "safe-int" },
  frame_summary: { count: "safe-int", p95IntervalUs: "safe-int", maxIntervalUs: "safe-int", jankCount: "safe-int" },
  page_js_heap_sample: { pageJsHeapBytes: "safe-int" },
  memory_guard_sample: {
    state: ["normal", "soft", "hard", "unknown", "unsupported"],
    pssBytes: "safe-int", rssBytes: "safe-int",
    privateDirtyBytes: "safe-int", anonymousBytes: "safe-int",
    cgroupCurrentBytes: "safe-int", cgroupMaxBytes: "safe-int",
    cgroupLimit: ["limited", "unlimited", "unknown"],
    cgroupHighEvents: "safe-int", cgroupMaxEvents: "safe-int",
    cgroupOomEvents: "safe-int", cgroupOomKillEvents: "safe-int",
    rHeapAfterGcBytes: "safe-int", guardGcCount: "safe-int",
    sdkClientCount: "safe-int", sdkConsumerCount: "safe-int", sdkRouteCount: "safe-int",
    sdkMessagesSeen: "safe-int", sdkMessageBytesSeen: "safe-int", sdkMaxBatchBytes: "safe-int",
    sdkBufferedMessageCount: "safe-int",
    sdkWaiterCount: "safe-int", sdkUsageProbePendingCount: "safe-int", activeTurnCount: "safe-int",
    softPssBytes: "safe-int", hardPssBytes: "safe-int",
    softRssBytes: "safe-int", hardRssBytes: "safe-int",
  },
  window_error_category: { category: ["resource", "script", "network", "shiny", "unknown"] },
  unhandled_rejection_category: { category: ["promise", "unknown"] },
  telemetry_batch_drop: {
    count: "safe-int",
    reason: ["invalid_config", "invalid_event", "invalid_metric", "oversize", "queue_full", "serialize", "write", "rotation", "payload", "permission", "random", "name_collision", "dependency", "closed", "unsupported"],
  },
  storage_outcome: {
    operation: ["startup", "rotation", "close", "retention", "clear", "export"],
    outcome: ["ok", "busy", "unsupported", "io_error", "invalid", "partial"],
    count: "safe-int", bytes: "safe-int",
  },
} as const;

export const DIAGNOSTICS_FORBIDDEN_NAMES = new Set([
  "content", "text", "message", "prompt", "response", "args", "argsText", "result", "filename", "path",
  "cwd", "home", "env", "model", "tool", "toolName", "threadId", "runId", "sessionId", "protocolId",
  "ownerId", "openId", "revision", "pid", "url", "error", "errorText", "condition", "stack", "source",
  "ordinal", "instance",
]);
