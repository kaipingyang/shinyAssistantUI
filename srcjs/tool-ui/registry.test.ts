import { describe, it, expect } from "vitest";
import { TOOL_UI_BY_NAME } from "./registry";
import { AskUserQuestionToolUI } from "./ask-user-question-tool";

describe("tool-ui registry", () => {
  it("registers AskUserQuestion → AskUserQuestionToolUI", () => {
    expect(TOOL_UI_BY_NAME.AskUserQuestion).toBe(AskUserQuestionToolUI);
  });
  it("has no entry for unregistered tools (falls back)", () => {
    expect(TOOL_UI_BY_NAME.Bash).toBeUndefined();
    expect(TOOL_UI_BY_NAME.Edit).toBeUndefined();
  });
});
