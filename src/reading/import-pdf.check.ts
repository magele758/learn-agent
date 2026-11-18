import { mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { documentPath, importPdf, listDocuments } from "./import-pdf.ts";

const SENTENCE = "Dependency comes before the claim.";
const OTHER = "A second page of a different file.";
const reasons: string[] = [];

function check(ok: boolean, reason: string): void {
  if (!ok) reasons.push(reason);
}

function buildPdfItems(parts: string[]): Buffer {
  const shown = parts.map((part) => `(${part}) Tj`).join("\n");
  const content = `BT\n/F1 12 Tf\n72 720 Td\n${shown}\nET\n`;
  return buildPdfContent(content);
}

function buildPdf(text: string): Buffer {
  return buildPdfItems([text]);
}

function buildPdfContent(content: string): Buffer {
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

const root = await mkdtemp(path.join(os.tmpdir(), "learn-agent-pdf-"));
const writeLine = console.log.bind(console);
// pdfjs logs a standard-font miss with console.log. This script prints its own result later.
console.log = () => {};
try {
  const pdfPath = path.join(root, "note.pdf");
  await writeFile(pdfPath, buildPdf(SENTENCE));
  const first = await importPdf(root, pdfPath);
  const savedPath = documentPath(root, first.id);
  const saved = await readFile(savedPath, "utf8");
  check(first.pages[0]?.text.includes(SENTENCE) === true, `pages[0].text=${JSON.stringify(first.pages[0]?.text)}`);
  check(first.id.startsWith("doc-"), `id=${first.id}`);
  check(saved.includes(first.id), `missing file ${savedPath}`);
  const second = await importPdf(root, pdfPath);
  const names = (await readdir(path.dirname(savedPath))).filter((name) => name.endsWith(".json"));
  const listed = await listDocuments(root);
  check(second.id === first.id, `id changed from ${first.id} to ${second.id}`);
  check(names.length === 1 && names[0] === `${first.id}.json`, `documents=${names.join(",")}`);
  check(listed.length === 1 && listed[0]?.id === first.id, `list=${listed.map((item) => item.id).join(",")}`);
  check(first.id !== "doc-e3b0c44298fc", `id hashed empty bytes: ${first.id}`);
  const otherPath = path.join(root, "other.pdf");
  await writeFile(otherPath, buildPdf(OTHER));
  const other = await importPdf(root, otherPath);
  check(other.id !== first.id, `different pdfs share id ${first.id}`);
  check(other.pages[0]?.text.includes(OTHER) === true, `other text=${JSON.stringify(other.pages[0]?.text)}`);
  const spacedPath = path.join(root, "spaced.pdf");
  await writeFile(spacedPath, buildPdfItems(["Hello", " ", "world"]));
  const spaced = await importPdf(root, spacedPath);
  check(spaced.pages[0]?.text === "Hello world", `spaced text=${JSON.stringify(spaced.pages[0]?.text)}`);
} catch (error) {
  reasons.push(error instanceof Error ? error.stack ?? error.message : String(error));
} finally {
  console.log = writeLine;
  await rm(root, { recursive: true, force: true });
}

if (reasons.length > 0) {
  for (const reason of reasons) console.log(reason);
  process.exitCode = 1;
} else {
  console.log("ok");
}
