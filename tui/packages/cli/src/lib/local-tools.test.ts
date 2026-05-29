import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdtemp, rm, writeFile } from "fs/promises";
import { tmpdir } from "os";
import { join } from "path";
import { executeLocalTool } from "./local-tools";

let originalCwd: string;
let workspace: string;

beforeEach(async () => {
  originalCwd = process.cwd();
  workspace = await mkdtemp(join(tmpdir(), "nodcode-tools-"));
  process.chdir(workspace);
});

afterEach(async () => {
  process.chdir(originalCwd);
  await rm(workspace, { recursive: true, force: true });
});

describe("local tool executor", () => {
  test("reads, lists, globs, and greps inside the project directory", async () => {
    await writeFile("alpha.txt", "hello from alpha\nneedle here\n", "utf-8");
    await writeFile("beta.md", "hello from beta\n", "utf-8");

    await expect(executeLocalTool("readFile", { path: "alpha.txt" }, "PLAN")).resolves.toEqual({
      content: "hello from alpha\nneedle here\n",
    });

    const listed = await executeLocalTool("listDirectory", { path: "." }, "PLAN");
    expect(listed).toMatchObject({
      path: ".",
      entries: expect.arrayContaining([
        { name: "alpha.txt", type: "file" },
        { name: "beta.md", type: "file" },
      ]),
    });

    await expect(executeLocalTool("glob", { pattern: "*.txt", path: "." }, "PLAN")).resolves.toEqual({
      files: ["alpha.txt"],
    });

    const grep = await executeLocalTool("grep", { pattern: "needle", path: "." }, "PLAN");
    expect(grep).toMatchObject({
      matches: [{ file: "alpha.txt", line: 2, content: "needle here" }],
    });
  });

  test("writes, edits, and runs bash in BUILD mode", async () => {
    await expect(
      executeLocalTool("writeFile", { path: "tmp/tool.txt", content: "alpha\nbeta\n" }, "BUILD"),
    ).resolves.toMatchObject({ success: true, path: "tmp/tool.txt" });

    await expect(
      executeLocalTool(
        "editFile",
        { path: "tmp/tool.txt", oldString: "beta", newString: "gamma" },
        "BUILD",
      ),
    ).resolves.toEqual({ success: true, path: "tmp/tool.txt" });

    await expect(executeLocalTool("readFile", { path: "tmp/tool.txt" }, "BUILD")).resolves.toEqual({
      content: "alpha\ngamma\n",
    });

    await expect(
      executeLocalTool("bash", { command: "printf ok && test -f tmp/tool.txt" }, "BUILD"),
    ).resolves.toMatchObject({ stdout: "ok", stderr: "", exitCode: 0 });
  });

  test("blocks mutating tools in PLAN mode", async () => {
    await expect(
      executeLocalTool("writeFile", { path: "blocked.txt", content: "no" }, "PLAN"),
    ).rejects.toThrow("Tool writeFile is not available in PLAN mode");

    await expect(
      executeLocalTool("bash", { command: "touch blocked.txt" }, "PLAN"),
    ).rejects.toThrow("Tool bash is not available in PLAN mode");
  });

  test("rejects path traversal outside the project directory", async () => {
    await expect(executeLocalTool("readFile", { path: "../secret.txt" }, "PLAN")).rejects.toThrow(
      "Path is outside the project directory",
    );
  });
});
