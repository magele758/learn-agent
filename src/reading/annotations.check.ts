import { access, mkdtemp, readFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import {
  addAnnotation,
  annotationsFile,
  getAnnotation,
  listAnnotations,
  loadAnnotations,
  recordTurn,
} from "./annotations.ts";
import type { ReadingDocument } from "./types.ts";

const reasons: string[] = [];

function check(ok: boolean, reason: string): void {
  if (!ok) reasons.push(reason);
}

async function rejects(run: () => Promise<unknown>, reason: string): Promise<void> {
  try {
    await run();
    reasons.push(reason);
  } catch (error) {
    check(error instanceof Error, `${reason} threw a non-Error`);
  }
}

function isEnoent(error: unknown): boolean {
  return (error as NodeJS.ErrnoException).code === "ENOENT";
}

const document: ReadingDocument = {
  id: "doc-1",
  title: "Sample",
  sourcePath: "sample.pdf",
  importedAt: "2026-01-01T00:00:00.000Z",
  pages: [
    { page: 1, text: "The quick brown fox" },
    { page: 2, text: "jumps over the lazy dog" },
  ],
};

try {
  const dir = await mkdtemp(path.join(os.tmpdir(), "annotations-"));
  const file = annotationsFile(dir);
  if (!file.startsWith(`${dir}${path.sep}`)) {
    throw new Error(`annotations file is outside the temp dir: ${file}`);
  }

  await rejects(
    () => addAnnotation(dir, { documentId: "doc-1", page: 1, quote: "   " }),
    "empty quote was accepted",
  );
  await rejects(
    () =>
      addAnnotation(dir, {
        documentId: "doc-1",
        page: 1,
        quote: "not on this page",
        document,
      }),
    "quote missing from page text was accepted",
  );

  try {
    await access(file);
    reasons.push("annotations file exists after rejected quote");
  } catch (error) {
    if (!isEnoent(error)) reasons.push(`expected missing file, got ${String(error)}`);
  }

  const wrapped = await addAnnotation(dir, {
    documentId: "doc-1",
    page: 1,
    quote: "quick\nbrown",
    document,
  });
  check(wrapped.quote === "quick\nbrown", `wrapped quote was rewritten: ${JSON.stringify(wrapped.quote)}`);

  const first = await addAnnotation(dir, {
    documentId: "doc-1",
    page: 1,
    quote: "  quick brown  ",
    note: "  margin  ",
    document,
  });
  const second = await addAnnotation(dir, {
    documentId: "doc-2",
    page: 2,
    quote: "other doc",
  });
  const third = await addAnnotation(dir, {
    documentId: "doc-1",
    page: 1,
    quote: "The quick",
    document,
  });

  check(first.id.startsWith("ann-"), `id=${first.id}`);
  check(first.quote === "quick brown", `quote=${first.quote}`);
  check(first.note === "margin", `note=${first.note}`);
  check(first.page === 1, `page=${String(first.page)}`);
  check(first.documentId === "doc-1", `documentId=${first.documentId}`);
  check(first.turns.length === 0, `turns=${String(first.turns.length)}`);
  check(Number.isFinite(Date.parse(first.createdAt)), `createdAt=${first.createdAt}`);

  const listed = await listAnnotations(dir, "doc-1");
  check(
    listed.map((item) => item.id).join(",") === [wrapped.id, first.id, third.id].join(","),
    `list filter=${listed.map((item) => item.id).join(",")}`,
  );

  await rejects(() => recordTurn(dir, first.id, "   ", "because"), "blank question was accepted");

  const withTurn = await recordTurn(dir, first.id, "  why this line?  ", "  because it anchors the claim  ");
  check(withTurn.turns.length === 1, `turn count=${String(withTurn.turns.length)}`);
  const turn = withTurn.turns[0];
  check(turn?.id.startsWith("turn-") === true, `turn id=${turn?.id ?? "missing"}`);
  check(turn?.question === "why this line?", `question=${turn?.question ?? "missing"}`);
  check(turn?.answer === "because it anchors the claim", `answer=${turn?.answer ?? "missing"}`);
  check(withTurn.id === first.id, "recordTurn returned a different annotation");

  const others = await listAnnotations(dir, "doc-2");
  check(
    others.length === 1 && others[0]?.id === second.id && others[0].turns.length === 0,
    "other annotation changed",
  );

  const raw = await readFile(file, "utf8");
  const stored: unknown = JSON.parse(raw);
  check(Array.isArray(stored) && stored.length === 4, `stored length=${Array.isArray(stored) ? stored.length : "not-array"}`);
  check(raw === `${JSON.stringify(stored, null, 2)}\n`, "file is not pretty JSON with a trailing newline");

  const again = await loadAnnotations(dir);
  const reloaded = again.find((item) => item.id === first.id);
  check(reloaded?.quote === "quick brown", `reloaded quote=${reloaded?.quote ?? "missing"}`);
  check(reloaded?.turns.length === 1, `reloaded turns=${String(reloaded?.turns.length ?? "missing")}`);
  check(reloaded?.turns[0]?.answer === "because it anchors the claim", "reloaded answer mismatch");
  check(reloaded?.createdAt === first.createdAt, "reloaded createdAt mismatch");
  check(
    again.map((item) => item.id).join(",") === [wrapped.id, first.id, second.id, third.id].join(","),
    "reload order changed",
  );

  const fetched = await getAnnotation(dir, first.id);
  check(fetched.turns[0]?.id === turn?.id, `getAnnotation turn=${fetched.turns[0]?.id ?? "missing"}`);

  try {
    await getAnnotation(dir, "ann-missing");
    reasons.push("missing annotation was returned");
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    check(message.includes("ann-missing"), `missing id error=${message}`);
  }
} catch (error) {
  reasons.push(error instanceof Error ? error.message : String(error));
}

if (reasons.length > 0) {
  for (const reason of reasons) console.log(reason);
  process.exitCode = 1;
} else {
  console.log("ok");
}
