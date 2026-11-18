import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { annotationsFile, listAnnotations } from "../reading/annotations.ts";
import { importPdf } from "../reading/import-pdf.ts";
import { startReader, type ReaderServer } from "../reading/server.ts";
import { executeReadingCommand, parseReadingCommand } from "./reading.ts";

const SENTENCE = "Dependency comes before the claim.";
const ANSWER = "because the definition is first";
const OFF_PAGE = "this sentence is not on the page";
const reasons: string[] = [];

function check(ok: boolean, reason: string): void {
  if (!ok) reasons.push(reason);
}

function buildPdf(text: string): Buffer {
  const content = `BT\n/F1 12 Tf\n72 720 Td\n(${text}) Tj\nET\n`;
  const objects = [
    "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
    "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
    "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n",
    `4 0 obj\n<< /Length ${Buffer.byteLength(content)} >>\nstream\n${content}endstream\nendobj\n`,
    "5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n",
  ];
  const chunks: Buffer[] = [Buffer.from("%PDF-1.4\n")];
  const offsets = [0];
  let cursor = chunks[0].length;
  for (const object of objects) {
    offsets.push(cursor);
    const chunk = Buffer.from(object);
    chunks.push(chunk);
    cursor += chunk.length;
  }
  let xref = "xref\n0 6\n0000000000 65535 f \n";
  for (let index = 1; index <= 5; index += 1) {
    xref += `${String(offsets[index]).padStart(10, "0")} 00000 n \n`;
  }
  xref += `trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n${cursor}\n%%EOF\n`;
  chunks.push(Buffer.from(xref));
  return Buffer.concat(chunks);
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function assertRejected(argv: readonly string[], includes: string): void {
  try {
    parseReadingCommand(argv);
    reasons.push(`accepted: ${argv.join(" ")}`);
  } catch (error) {
    const message = messageOf(error);
    check(message.includes(includes), `argv=${argv.join(" ")} message=${message}`);
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

async function captureLog(run: () => Promise<void>): Promise<string[]> {
  const lines: string[] = [];
  const original = console.log;
  console.log = (...args: unknown[]) => {
    lines.push(args.map((item) => String(item)).join(" "));
  };
  try {
    await run();
  } finally {
    console.log = original;
  }
  return lines;
}

delete process.env.OPENAI_API_KEY;
delete process.env.OPENAI_BASE_URL;
delete process.env.OPENAI_MODEL;

assertRejected(["nope"], "usage: demo [directory]");
assertRejected(["nope"], "import-pdf");
assertRejected(["nope"], "read --doc");
assertRejected(["highlight", "--page", "1", "--quote", "x"], "missing --doc");

const parsedDir = parseReadingCommand(["documents", "--dir", "/first", "--dir", "/second"]);
check(parsedDir.kind === "documents" && parsedDir.dir === "/second", `dir=${parsedDir.dir}`);

const root = await mkdtemp(path.join(os.tmpdir(), "learn-agent-reading-"));
const stored = annotationsFile(root);
check(stored.startsWith(`${root}${path.sep}`), `annotations file left the temp dir: ${stored}`);

let reader: ReaderServer | undefined;
const writeLine = console.log.bind(console);
console.log = () => {};
try {
  const pdfPath = path.join(root, "note.pdf");
  await writeFile(pdfPath, buildPdf(SENTENCE));
  const document = await importPdf(root, pdfPath);

  const badCommand = parseReadingCommand([
    "highlight",
    "--doc",
    document.id,
    "--page",
    "1",
    "--quote",
    OFF_PAGE,
    "--dir",
    root,
  ]);
  try {
    await executeReadingCommand(badCommand);
    reasons.push("off-page highlight was saved");
  } catch (error) {
    check(messageOf(error).includes("quote is not on page"), messageOf(error));
  }
  check((await listAnnotations(root, document.id)).length === 0, "off-page highlight wrote a record");

  const highlightCommand = parseReadingCommand([
    "highlight",
    "--doc",
    document.id,
    "--page",
    "1",
    "--quote",
    SENTENCE,
    "--note",
    "check",
    "--dir",
    root,
  ]);
  const printed = await captureLog(() => executeReadingCommand(highlightCommand));
  const saved = await listAnnotations(root, document.id);
  const savedOne = saved[0];
  check(printed.length === 1 && printed[0] === savedOne?.id, `highlight stdout=${printed.join("|")}`);
  check(savedOne?.quote === SENTENCE, `saved quote=${savedOne?.quote ?? "missing"}`);
  check(savedOne?.note === "check", `saved note=${savedOne?.note ?? "missing"}`);

  let calls = 0;
  let seenPrompt = "";
  reader = await startReader({
    dir: root,
    documentId: document.id,
    port: 0,
    complete: async (prompt) => {
      calls += 1;
      seenPrompt = prompt;
      return ANSWER;
    },
  });

  const pageResponse = await fetch(reader.url);
  const html = await pageResponse.text();
  check(pageResponse.status === 200, `page status=${String(pageResponse.status)}`);
  check(html.includes('id="viewerContainer"') && html.includes('class="pdfViewer"'), "pdf viewer is missing");
  check(html.includes("/viewer.js") && html.includes("/vendor/web/pdf_viewer.css"), "pdf.js assets are missing");
  check(html.includes("保存批注") && html.includes("保存并提问"), "page is missing save buttons");
  const pdfResponse = await fetch(`${reader.url}document.pdf`);
  const pdfBytes = Buffer.from(await pdfResponse.arrayBuffer());
  check(pdfResponse.status === 200 && pdfBytes.subarray(0, 5).toString() === "%PDF-", `pdf status=${String(pdfResponse.status)}`);
  check(pdfBytes.includes(Buffer.from(SENTENCE)), "served pdf is missing the sentence");
  const worker = await fetch(`${reader.url}vendor/build/pdf.worker.mjs`);
  check(worker.status === 200 && (worker.headers.get("content-type") ?? "").includes("javascript"), `worker status=${String(worker.status)}`);
  const scriptStart = html.indexOf("<script>");
  const scriptEnd = html.lastIndexOf("</script>");
  try {
    new Function(html.slice(scriptStart + "<script>".length, scriptEnd));
  } catch (error) {
    reasons.push(`page script: ${messageOf(error)}`);
  }

  const question = "why is the definition first?";
  const created = await fetch(`${reader.url}api/highlights`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ page: 1, quote: SENTENCE, note: "from the page", question }),
  });
  const payload: unknown = await created.json();
  check(created.status === 200, `create status=${String(created.status)}`);
  check(isRecord(payload) && payload.error === null, `create error=${JSON.stringify(payload)}`);
  const annotation = isRecord(payload) ? payload.annotation : undefined;
  check(isRecord(annotation) && annotation.quote === SENTENCE, `create quote=${JSON.stringify(annotation)}`);
  const turns = isRecord(annotation) && Array.isArray(annotation.turns) ? annotation.turns : [];
  const turn = turns[0];
  check(turns.length === 1 && isRecord(turn) && turn.answer === ANSWER, `turns=${JSON.stringify(turns)}`);
  check(calls === 1 && seenPrompt.includes(SENTENCE) && seenPrompt.includes(question), `complete calls=${String(calls)}`);
  const createdId = isRecord(annotation) && typeof annotation.id === "string" ? annotation.id : "";

  const listedResponse = await fetch(`${reader.url}api/highlights`);
  const listed: unknown = await listedResponse.json();
  const found = Array.isArray(listed) && listed.some((item) => isRecord(item) && item.id === createdId);
  check(listedResponse.status === 200 && found, `list missing ${createdId}`);
  const onDisk = await listAnnotations(root, document.id);
  check(onDisk.some((item) => item.id === createdId && item.turns[0]?.answer === ANSWER), "saved turn missing on disk");

  const before = onDisk.length;
  const rejected = await fetch(`${reader.url}api/highlights`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ page: 1, quote: OFF_PAGE, note: "", question: "should not ask" }),
  });
  const rejectedText = await rejected.text();
  check(rejected.status === 400, `off-page status=${String(rejected.status)} body=${rejectedText}`);
  check(rejectedText.includes("quote is not on page"), `off-page body=${rejectedText}`);
  const after = await listAnnotations(root, document.id);
  check(after.length === before, `off-page wrote a record ${String(before)} -> ${String(after.length)}`);
  check(calls === 1, `off-page called complete ${String(calls)}`);

  const plain = await startReader({ dir: root, documentId: document.id, port: 0 });
  try {
    const failed = await fetch(`${plain.url}api/highlights`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ page: 1, quote: SENTENCE, note: "kept", question: "still ask" }),
    });
    const failedBody: unknown = await failed.json();
    const kept = isRecord(failedBody) ? failedBody.annotation : undefined;
    const keptId = isRecord(kept) && typeof kept.id === "string" ? kept.id : "";
    check(failed.status === 200, `model failure status=${String(failed.status)}`);
    check(
      isRecord(failedBody) && typeof failedBody.error === "string" && failedBody.error.includes("OPENAI_API_KEY"),
      `model failure body=${JSON.stringify(failedBody)}`,
    );
    check(
      isRecord(kept) && kept.quote === SENTENCE && Array.isArray(kept.turns) && kept.turns.length === 0,
      `kept annotation=${JSON.stringify(kept)}`,
    );
    const keptOnDisk = await listAnnotations(root, document.id);
    check(
      keptOnDisk.some((item) => item.id === keptId && item.turns.length === 0),
      "failed ask dropped the annotation",
    );
  } finally {
    await plain.close();
  }
} catch (error) {
  console.log = writeLine;
  reasons.push(error instanceof Error ? error.stack ?? error.message : String(error));
} finally {
  console.log = writeLine;
  if (reader) await reader.close();
  await rm(root, { recursive: true, force: true });
}

if (reasons.length > 0) {
  for (const reason of reasons) console.log(reason);
  process.exitCode = 1;
} else {
  console.log("ok");
}
