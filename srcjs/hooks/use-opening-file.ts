import { useCallback, useEffect, useRef, useState } from "react";

const OPENING_FEEDBACK_MS = 1500;
const isPromiseLike = (value: unknown): value is PromiseLike<unknown> =>
  value !== null && typeof value === "object" && "then" in value && typeof value.then === "function";

export function useOpeningFile(
  onOpenFile?: (path: string, line?: number) => unknown,
  feedbackMs = OPENING_FEEDBACK_MS,
) {
  const [opening, setOpening] = useState(false);
  const [failed, setFailed] = useState(false);
  const openingRef = useRef(false);
  const mountedRef = useRef(true);
  const sequenceRef = useRef(0);
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(
    () => {
      mountedRef.current = true;
      return () => {
        mountedRef.current = false;
        sequenceRef.current += 1;
        openingRef.current = false;
        if (timerRef.current !== null) clearTimeout(timerRef.current);
      };
    },
    [],
  );

  const open = useCallback(
    (path: string, line?: number) => {
      if (!onOpenFile || !path || openingRef.current) return;
      openingRef.current = true;
      setOpening(true);
      setFailed(false);
      const sequence = ++sequenceRef.current;
      const settle = (ok: boolean) => {
        if (!mountedRef.current || sequence !== sequenceRef.current) return;
        timerRef.current = null;
        openingRef.current = false;
        setOpening(false);
        setFailed(!ok);
      };
      try {
        const result = line === undefined ? onOpenFile(path) : onOpenFile(path, line);
        if (isPromiseLike(result)) {
          Promise.resolve(result).then(
            (value) => settle(value !== false),
            (error) => {
              console.warn("[shinyAssistantUI] File opening failed.", error);
              settle(false);
            },
          );
        } else if (result === false) {
          settle(false);
        } else {
          timerRef.current = setTimeout(() => settle(true), feedbackMs);
        }
      } catch (error) {
        console.warn("[shinyAssistantUI] File opening failed.", error);
        settle(false);
      }
    },
    [feedbackMs, onOpenFile],
  );

  return { opening, failed, open };
}
