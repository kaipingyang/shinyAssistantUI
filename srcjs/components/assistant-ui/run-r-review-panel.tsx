// Plan 163 — pending R output reviews, shown above the composer.
import { useEffect, useId, useState, useSyncExternalStore, type FC } from "react";
import { ShieldCheckIcon } from "lucide-react";
import { Button } from "@/components/ui/button";
import { useShinyConfig } from "@/shiny-config-context";
import {
  RUN_R_REVIEW_MAX_TEXT,
  type RunRReview,
  type RunRReviewBridge,
  type RunRReviewSnapshot,
} from "@/run-r-review-addon";

const EMPTY: RunRReviewSnapshot = { enabled: true, reviews: [] };
const noopSubscribe = () => () => undefined;

export function useRunRReview(bridge: RunRReviewBridge | undefined): RunRReviewSnapshot {
  return useSyncExternalStore(
    bridge ? bridge.subscribe : noopSubscribe,
    bridge ? bridge.getSnapshot : () => EMPTY,
  );
}

const ReviewCard: FC<{ review: RunRReview; bridge: RunRReviewBridge }> = ({ review, bridge }) => {
  const [text, setText] = useState(review.text);
  const outputId = useId();
  useEffect(() => setText(review.text), [review.id, review.text]);
  const edited = text !== review.text;
  const tooLong = text.length > RUN_R_REVIEW_MAX_TEXT;
  const target = review.source === "local" ? "this conversation" : "Claude";
  return (
    <section
      data-run-r-review={review.id}
      data-run-r-review-source={review.source}
      aria-label="Review R output"
      className="aui-run-r-review bg-background flex flex-col gap-2 rounded-xl border border-amber-500/50 p-3 shadow-sm"
    >
      <div className="flex items-center gap-2">
        <ShieldCheckIcon aria-hidden="true" className="size-4 shrink-0 text-amber-600" />
        <p className="text-sm font-medium">
          {review.source === "local"
            ? "Review console output before sending it"
            : "Review R output before Claude sees it"}
        </p>
      </div>
      <p className="text-muted-foreground text-xs">
        The code has already run in your R session. Only the text below is shared with {target}
        {" "}after you confirm; edit it to remove anything sensitive.
      </p>
      <details className="text-xs">
        <summary className="text-muted-foreground cursor-pointer select-none">Code</summary>
        <pre data-run-r-review-code className="bg-muted/50 mt-1 max-h-32 overflow-auto rounded p-2 font-mono whitespace-pre">
          {review.code}
        </pre>
      </details>
      <label htmlFor={outputId} className="text-muted-foreground text-xs font-medium">
        {review.isError ? "Output (ended with an error)" : "Output"}
      </label>
      <textarea
        id={outputId}
        data-run-r-review-text
        value={text}
        readOnly={review.submitting}
        onChange={(event) => setText(event.target.value)}
        spellCheck={false}
        rows={Math.min(10, Math.max(3, review.text.split("\n").length))}
        className="bg-muted/30 focus-visible:ring-ring max-h-64 w-full resize-y rounded-md border p-2 font-mono text-xs focus-visible:ring-2 focus-visible:outline-none"
      />
      {tooLong && (
        <p role="alert" className="text-destructive text-xs">
          Edited output is limited to {RUN_R_REVIEW_MAX_TEXT.toLocaleString()} characters.
        </p>
      )}
      <div className="flex flex-wrap items-center gap-2">
        <Button
          type="button"
          size="sm"
          data-run-r-review-action={edited ? "edit" : "approve"}
          disabled={tooLong || review.submitting}
          onClick={() => bridge.decide(review.id, edited ? "edit" : "approve", edited ? text : undefined)}
        >
          {edited ? "Send edited output" : "Send output"}
        </Button>
        {review.submitting && (
          <span role="status" className="text-muted-foreground text-xs">Sending decision…</span>
        )}
        {edited && !review.submitting && (
          <Button type="button" size="sm" variant="ghost" data-run-r-review-action="reset"
            onClick={() => setText(review.text)}>
            Reset
          </Button>
        )}
        <Button
          type="button"
          size="sm"
          variant="outline"
          disabled={review.submitting}
          data-run-r-review-action="reject"
          onClick={() => bridge.decide(review.id, "reject")}
        >
          Don't send
        </Button>
      </div>
    </section>
  );
};

export const RunROutputReviewPanel: FC = () => {
  const { runROutputReview: bridge, currentThreadId } = useShinyConfig();
  const { reviews } = useRunRReview(bridge);
  if (!bridge || reviews.length === 0) return null;
  const here = reviews.filter((review) => review.threadId === currentThreadId);
  const elsewhere = reviews.length - here.length;
  return (
    <div data-slot="aui_run_r_review_panel" className="flex flex-col gap-2">
      {here.map((review) => <ReviewCard key={review.id} review={review} bridge={bridge} />)}
      {elsewhere > 0 && (
        <p role="status" data-run-r-review-elsewhere={elsewhere}
          className="rounded-md border border-amber-500/50 px-3 py-2 text-xs">
          {elsewhere === 1
            ? "1 R output is waiting for your review in another conversation."
            : `${elsewhere} R outputs are waiting for your review in other conversations.`}
        </p>
      )}
    </div>
  );
};

export const RunROutputReviewToggle: FC = () => {
  const { runROutputReview: bridge } = useShinyConfig();
  const { enabled, pendingEnabled } = useRunRReview(bridge);
  if (!bridge) return null;
  const saving = pendingEnabled !== undefined;
  return (
    <label className="aui-run-r-review-toggle mt-3 flex cursor-pointer items-start gap-2 text-xs"
      data-slot="aui_run_r_review_toggle">
      <input
        type="checkbox"
        className="mt-0.5"
        checked={saving ? pendingEnabled : enabled}
        disabled={saving}
        aria-busy={saving}
        onChange={(event) => bridge.setEnabled(event.target.checked)}
      />
      <span className="flex flex-col">
        <span className="text-foreground font-medium">Review R output before sending to Claude</span>
        <span className="text-muted-foreground">
          Recommended. When off, run_r and Run in Console output is shared immediately.
        </span>
      </span>
    </label>
  );
};
