import { randomUUID } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import type { Annotation, AnnotationTurn, ReadingDocument } from "./types.ts";

export function annotationsFile(dir: string): string {
  return path.join(dir, "data", "reading", "annotations.json");
}

function isEnoent(error: unknown): boolean {
  return (error as NodeJS.ErrnoException).code === "ENOENT";
}

function requireText(value: string, label: string): string {
  const trimmed = value.trim();
  if (trimmed.length === 0) throw new Error(`${label} must not be empty`);
  return trimmed;
}

function requirePage(page: number): void {
  if (!Number.isInteger(page) || page < 1) {
    throw new Error(`page must be an integer >= 1, got ${String(page)}`);
  }
}

async function readAll(dir: string): Promise<Annotation[]> {
  const file = annotationsFile(dir);
  let raw: string;
  try {
    raw = await readFile(file, "utf8");
  } catch (error) {
    if (isEnoent(error)) return [];
    throw error;
  }
  const parsed: unknown = JSON.parse(raw);
  if (!Array.isArray(parsed)) throw new Error(`annotations file is not an array: ${file}`);
  return parsed as Annotation[];
}

async function writeAll(dir: string, annotations: Annotation[]): Promise<void> {
  const file = annotationsFile(dir);
  await mkdir(path.dirname(file), { recursive: true });
  await writeFile(file, `${JSON.stringify(annotations, null, 2)}\n`, "utf8");
}

function compactText(value: string): string {
  return value.replace(/\s+/g, "");
}

function assertQuoteOnPage(document: ReadingDocument, pageNumber: number, quote: string): void {
  const page = document.pages.find((item) => item.page === pageNumber);
  const folded = compactText(quote);
  if (!page || folded.length === 0 || !compactText(page.text).includes(folded)) {
    throw new Error(`quote is not on page ${String(pageNumber)}`);
  }
}

export async function loadAnnotations(dir: string): Promise<Annotation[]> {
  return readAll(dir);
}

export async function addAnnotation(
  dir: string,
  input: {
    documentId: string;
    page: number;
    quote: string;
    note?: string;
    document?: ReadingDocument;
  },
): Promise<Annotation> {
  const quote = requireText(input.quote, "quote");
  requirePage(input.page);
  if (input.document) assertQuoteOnPage(input.document, input.page, quote);

  const annotation: Annotation = {
    id: `ann-${randomUUID()}`,
    documentId: input.documentId,
    page: input.page,
    quote,
    note: input.note?.trim() ?? "",
    createdAt: new Date().toISOString(),
    turns: [],
  };
  const all = await readAll(dir);
  all.push(annotation);
  await writeAll(dir, all);
  return annotation;
}

export async function listAnnotations(dir: string, documentId?: string): Promise<Annotation[]> {
  const all = await readAll(dir);
  if (documentId === undefined) return all;
  return all.filter((item) => item.documentId === documentId);
}

export async function getAnnotation(dir: string, id: string): Promise<Annotation> {
  const found = (await readAll(dir)).find((item) => item.id === id);
  if (!found) throw new Error(`annotation not found: ${id}`);
  return found;
}

export async function recordTurn(
  dir: string,
  annotationId: string,
  question: string,
  answer: string,
): Promise<Annotation> {
  const trimmedQuestion = requireText(question, "question");
  const trimmedAnswer = requireText(answer, "answer");
  const all = await readAll(dir);
  const index = all.findIndex((item) => item.id === annotationId);
  const current = index < 0 ? undefined : all[index];
  if (!current) throw new Error(`annotation not found: ${annotationId}`);

  const turn: AnnotationTurn = {
    id: `turn-${randomUUID()}`,
    question: trimmedQuestion,
    answer: trimmedAnswer,
    createdAt: new Date().toISOString(),
  };
  const updated: Annotation = { ...current, turns: [...current.turns, turn] };
  all[index] = updated;
  await writeAll(dir, all);
  return updated;
}
