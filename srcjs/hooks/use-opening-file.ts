import { useCallback, useEffect, useRef, useState } from "react";

const OPENING_FEEDBACK_MS = 1500;

export function useOpeningFile(
  onOpenFile?: (path: string, line?: number) => void,
  feedbackMs = OPENING_FEEDBACK_MS,
) {
  const [opening, setOpening] = useState(false);
  const openingRef = useRef(false);
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(
    () => () => {
      if (timerRef.current !== null) clearTimeout(timerRef.current);
    },
    [],
  );

  const open = useCallback(
    (path: string, line?: number) => {
      if (!onOpenFile || !path || openingRef.current) return;
      openingRef.current = true;
      setOpening(true);
      if (line === undefined) onOpenFile(path);
      else onOpenFile(path, line);
      timerRef.current = setTimeout(() => {
        timerRef.current = null;
        openingRef.current = false;
        setOpening(false);
      }, feedbackMs);
    },
    [feedbackMs, onOpenFile],
  );

  return { opening, open };
}
