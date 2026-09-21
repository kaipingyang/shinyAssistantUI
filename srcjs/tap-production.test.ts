import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

describe("tap production behavior", () => {
  it("does not restore the retired blanket development override", () => {
    const config = readFileSync(new URL("../vite.config.mts", import.meta.url), "utf8");
    expect(config).not.toContain("patch-tap-is-development");
    expect(config).not.toContain("export const isDevelopment = true");
  });

  it("keeps a stable event callback fresh without development replay", () => {
    const output = execFileSync(process.execPath, [
      "--input-type=module",
      "-e",
      `
        import assert from "node:assert/strict";
        import { createTapRoot, flushTapSync } from "@assistant-ui/tap";
        import { useEffectEvent, useState } from "react";

        let renders = 0;
        const root = createTapRoot(() => {
          renders++;
          const [open, setOpen] = useState(false);
          const onKeyDown = useEffectEvent(() => open);
          return { open, setOpen, onKeyDown };
        });
        try {
          const first = root.getValue();
          assert.equal(renders, 1);
          assert.equal(first.onKeyDown(), false);
          flushTapSync(() => first.setOpen(true));
          const next = root.getValue();
          assert.equal(renders, 2);
          assert.equal(next.open, true);
          assert.equal(next.onKeyDown, first.onKeyDown);
          assert.equal(first.onKeyDown(), true);
          console.log("tap-production-ok");
        } finally {
          root.unmount();
        }
      `,
    ], {
      cwd: new URL("../", import.meta.url),
      env: { ...process.env, NODE_ENV: "production" },
      encoding: "utf8",
      timeout: 10_000,
    });
    expect(output.trim()).toBe("tap-production-ok");
  });
});
