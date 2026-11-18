import { createHash } from "node:crypto";
import { mkdir, readFile, readdir, rename, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import path from "node:path";
import { pathToFileURL } from "node:url";
import type { ReadingDocument, ReadingPage } from "./types.ts";

const require = createRequire(import.meta.url);
const DOCUMENTS_DIR = path.join("data", "reading", "documents");

type PdfSource = {
  data: Uint8Array;
  disableWorker: true;
  isEvalSupported: false;
  standardFontDataUrl: string;
};

type PdfDocument = {
  numPages: number;
  getPage: (pageNumber: number) => Promise<unknown>;
  destroy: () => Promise<unknown>;
};

const PDFJS_ENTRY = "pdfjs-dist/legacy/build/pdf.mjs";

export function documentPath(dir: string, id: string): string {
  return path.join(dir, DOCUMENTS_DIR, `${id}.json`);
}

export async function importPdf(dir: string, pdfPath: string): Promise<ReadingDocument> {
  const sourcePath = path.resolve(pdfPath);
  const bytes = await readPdfBytes(sourcePath);
  // pdfjs detaches this buffer while opening the file. Hash first.
  const id = documentId(bytes);
  const pdf = await openPdf(bytes);
  try {
    const document: ReadingDocument = {
      id,
      title: titleFromPath(sourcePath),
      sourcePath,
      importedAt: new Date().toISOString(),
      pages: await readPages(pdf),
    };
    await writeDocument(dir, document);
    return document;
  } finally {
    await closePdf(pdf);
  }
}

export async function loadDocument(dir: string, id: string): Promise<ReadingDocument> {
  const file = documentPath(dir, id);
  try {
    return parseDocument(await readFile(file, "utf8"), file);
  } catch (error) {
    if (isEnoent(error)) throw new Error(`document not found: ${file}`);
    throw error;
  }
}

export async function listDocuments(
  dir: string,
): Promise<Array<{ id: string; title: string; sourcePath: string; importedAt: string; pageCount: number }>> {
  const folder = path.join(dir, DOCUMENTS_DIR);
  let names: string[];
  try {
    names = await readdir(folder);
  } catch (error) {
    if (isEnoent(error)) return [];
    throw error;
  }
  const listed = [];
  for (const name of names) {
    if (!name.endsWith(".json")) continue;
    const file = path.join(folder, name);
    const document = parseDocument(await readFile(file, "utf8"), file);
    listed.push({
      id: document.id,
      title: document.title,
      sourcePath: document.sourcePath,
      importedAt: document.importedAt,
      pageCount: document.pages.length,
    });
  }
  return listed;
}

function documentId(bytes: Uint8Array): string {
  return `doc-${createHash("sha256").update(bytes).digest("hex").slice(0, 12)}`;
}

function titleFromPath(sourcePath: string): string {
  const base = path.basename(sourcePath);
  return base.toLowerCase().endsWith(".pdf") ? base.slice(0, -4) : base;
}

async function readPdfBytes(sourcePath: string): Promise<Uint8Array> {
  try {
    return new Uint8Array(await readFile(sourcePath));
  } catch (error) {
    if (isEnoent(error)) throw new Error(`PDF not found: ${sourcePath}`);
    throw error;
  }
}

function standardFontDataUrl(): string {
  const pkg = require.resolve("pdfjs-dist/package.json");
  const fontsDir = path.join(path.dirname(pkg), "standard_fonts") + path.sep;
  return pathToFileURL(fontsDir).href;
}

async function loadGetDocument(): Promise<(src: PdfSource) => Promise<unknown>> {
  const mod: unknown = await import(PDFJS_ENTRY);
  if (!isRecord(mod) || typeof mod.getDocument !== "function") {
    throw new Error("pdfjs-dist did not export getDocument");
  }
  const getDocument = mod.getDocument as (src: PdfSource) => unknown;
  return async (src) => {
    const task = getDocument(src);
    if (!isRecord(task) || !isPromise(task.promise)) {
      throw new Error("pdfjs getDocument returned an unexpected task");
    }
    return task.promise;
  };
}

async function openPdf(bytes: Uint8Array): Promise<PdfDocument> {
  const getDocument = await loadGetDocument();
  const loaded: unknown = await getDocument({
    data: bytes,
    // pdfjs 4.10 ignores this flag. Node already forces the fake worker.
    disableWorker: true,
    isEvalSupported: false,
    standardFontDataUrl: standardFontDataUrl(),
  });
  if (!isPdfDocument(loaded)) throw new Error("pdfjs returned an unexpected document");
  return loaded;
}

async function readPages(pdf: PdfDocument): Promise<ReadingPage[]> {
  const pages: ReadingPage[] = [];
  for (let page = 1; page <= pdf.numPages; page += 1) {
    const view: unknown = await pdf.getPage(page);
    if (!isRecord(view) || typeof view.getTextContent !== "function") {
      throw new Error(`pdfjs returned an unexpected page ${String(page)}`);
    }
    const content: unknown = await view.getTextContent();
    if (!isRecord(content) || !Array.isArray(content.items)) {
      throw new Error(`pdfjs page ${String(page)} has no text items`);
    }
    pages.push({ page, text: textFromItems(content.items) });
  }
  return pages;
}

function textFromItems(items: readonly unknown[]): string {
  let text = "";
  for (const item of items) {
    if (!isRecord(item) || typeof item.str !== "string") continue;
    text += item.str;
    if (item.hasEOL === true) text += "\n";
  }
  return text.trim();
}

async function closePdf(pdf: PdfDocument): Promise<void> {
  try {
    await pdf.destroy();
  } catch {
    // Teardown must not replace an import result the caller can already use.
  }
}

async function writeDocument(dir: string, document: ReadingDocument): Promise<void> {
  const file = documentPath(dir, document.id);
  await mkdir(path.dirname(file), { recursive: true });
  const tmp = `${file}.${process.pid}.tmp`;
  await writeFile(tmp, `${JSON.stringify(document, null, 2)}\n`, "utf8");
  await rename(tmp, file);
}

function parseDocument(raw: string, file: string): ReadingDocument {
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`invalid document JSON at ${file}: ${message}`);
  }
  if (!isReadingDocument(value)) throw new Error(`invalid document JSON at ${file}`);
  return value;
}

function isReadingDocument(value: unknown): value is ReadingDocument {
  if (!isRecord(value)) return false;
  return (
    typeof value.id === "string" &&
    typeof value.title === "string" &&
    typeof value.sourcePath === "string" &&
    typeof value.importedAt === "string" &&
    Array.isArray(value.pages) &&
    value.pages.every(isReadingPage)
  );
}

function isReadingPage(value: unknown): value is ReadingPage {
  if (!isRecord(value)) return false;
  return typeof value.page === "number" && Number.isInteger(value.page) && value.page >= 1 && typeof value.text === "string";
}

function isPdfDocument(value: unknown): value is PdfDocument {
  if (!isRecord(value)) return false;
  return typeof value.numPages === "number" && typeof value.getPage === "function" && typeof value.destroy === "function";
}

function isPromise(value: unknown): value is Promise<unknown> {
  return isRecord(value) && typeof value.then === "function";
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function isEnoent(error: unknown): boolean {
  return isRecord(error) && error.code === "ENOENT";
}
