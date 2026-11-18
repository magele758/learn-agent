import { askAboutHighlight } from "../reading/ask.ts";
import { addAnnotation, getAnnotation, listAnnotations, recordTurn } from "../reading/annotations.ts";
import { importPdf, listDocuments, loadDocument } from "../reading/import-pdf.ts";
import { startReader } from "../reading/server.ts";

const VALUE_FLAGS = new Set([
  "--dir",
  "--doc",
  "--page",
  "--quote",
  "--note",
  "--id",
  "--question",
  "--port",
]);

export type ReadingCommand =
  | { kind: "import-pdf"; dir: string; file: string }
  | { kind: "documents"; dir: string }
  | { kind: "highlight"; dir: string; documentId: string; page: number; quote: string; note?: string }
  | { kind: "highlights"; dir: string; documentId?: string }
  | { kind: "ask"; dir: string; annotationId: string; question: string }
  | { kind: "read"; dir: string; documentId: string; port: number };

export function usageText(): string {
  return [
    "usage: demo [directory]",
    "       import-pdf <file.pdf> [--dir dir]",
    "       documents [--dir dir]",
    "       highlight --doc <id> --page <n> --quote <text> [--note <text>] [--dir dir]",
    "       highlights [--doc <id>] [--dir dir]",
    "       ask --id <annotationId> --question <text> [--dir dir]",
    "       read --doc <id> [--port 4173] [--dir dir]",
  ].join("\n");
}

export function parseReadingCommand(argv: readonly string[]): ReadingCommand {
  const { positionals, flags } = splitArgs(argv);
  const name = positionals[0];
  const dir = flags.get("--dir") ?? process.cwd();
  switch (name) {
    case "import-pdf": {
      const file = positionals[1];
      if (file === undefined) throw new Error("missing pdf path");
      rejectExtra(positionals, 2);
      return { kind: "import-pdf", dir, file };
    }
    case "documents":
      rejectExtra(positionals, 1);
      return { kind: "documents", dir };
    case "highlight": {
      rejectExtra(positionals, 1);
      const note = flags.get("--note");
      return {
        kind: "highlight",
        dir,
        documentId: requireFlag(flags, "--doc"),
        page: parsePage(requireFlag(flags, "--page")),
        quote: requireFlag(flags, "--quote"),
        ...(note === undefined ? {} : { note }),
      };
    }
    case "highlights": {
      rejectExtra(positionals, 1);
      const documentId = flags.get("--doc");
      return documentId === undefined ? { kind: "highlights", dir } : { kind: "highlights", dir, documentId };
    }
    case "ask":
      rejectExtra(positionals, 1);
      return {
        kind: "ask",
        dir,
        annotationId: requireFlag(flags, "--id"),
        question: requireFlag(flags, "--question"),
      };
    case "read": {
      rejectExtra(positionals, 1);
      const port = flags.get("--port");
      return {
        kind: "read",
        dir,
        documentId: requireFlag(flags, "--doc"),
        port: port === undefined ? 4173 : parsePort(port),
      };
    }
    default:
      throw new Error(usageText());
  }
}

export async function executeReadingCommand(command: ReadingCommand): Promise<void> {
  switch (command.kind) {
    case "import-pdf":
      await printImport(command);
      return;
    case "documents":
      await printDocuments(command);
      return;
    case "highlight":
      await printHighlight(command);
      return;
    case "highlights":
      await printHighlights(command);
      return;
    case "ask":
      await printAsk(command);
      return;
    case "read":
      await printRead(command);
      return;
    default: {
      const unreachable: never = command;
      throw new Error(`unknown command ${JSON.stringify(unreachable)}`);
    }
  }
}

export async function runReadingCli(argv: readonly string[]): Promise<void> {
  try {
    await executeReadingCommand(parseReadingCommand(argv));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}

function splitArgs(argv: readonly string[]): { positionals: string[]; flags: Map<string, string> } {
  const positionals: string[] = [];
  const flags = new Map<string, string>();
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (token === undefined) continue;
    if (!VALUE_FLAGS.has(token)) {
      if (token.startsWith("--")) throw new Error(`unexpected argument: ${token}`);
      positionals.push(token);
      continue;
    }
    const value = argv[index + 1];
    if (value === undefined) throw new Error(`missing ${token}`);
    flags.set(token, value);
    index += 1;
  }
  return { positionals, flags };
}

function rejectExtra(positionals: readonly string[], keep: number): void {
  const extra = positionals[keep];
  if (extra !== undefined) throw new Error(`unexpected argument: ${extra}`);
}

function requireFlag(flags: Map<string, string>, name: string): string {
  const value = flags.get(name);
  if (value === undefined) throw new Error(`missing ${name}`);
  return value;
}

function parsePage(raw: string): number {
  if (!/^[1-9]\d*$/.test(raw)) throw new Error("invalid --page");
  const page = Number(raw);
  if (!Number.isSafeInteger(page)) throw new Error("invalid --page");
  return page;
}

function parsePort(raw: string): number {
  if (!/^(0|[1-9]\d*)$/.test(raw)) throw new Error("invalid --port");
  const port = Number(raw);
  if (!Number.isSafeInteger(port) || port > 65535) throw new Error("invalid --port");
  return port;
}

async function printImport(command: Extract<ReadingCommand, { kind: "import-pdf" }>): Promise<void> {
  // pdfjs writes a missing-font warning with console.log. Command stdout is the import result.
  const document = await callWithLogOnStderr(() => importPdf(command.dir, command.file));
  console.log(document.id);
  console.log(document.title);
  console.log(String(document.pages.length));
}

async function callWithLogOnStderr<T>(run: () => Promise<T>): Promise<T> {
  const original = console.log;
  console.log = (...args: unknown[]) => {
    console.error(args.map((item) => String(item)).join(" "));
  };
  try {
    return await run();
  } finally {
    console.log = original;
  }
}

async function printDocuments(command: Extract<ReadingCommand, { kind: "documents" }>): Promise<void> {
  const documents = await listDocuments(command.dir);
  if (documents.length === 0) {
    console.log("no documents");
    return;
  }
  for (const document of documents) {
    console.log(`${document.id} ${document.title} ${String(document.pageCount)}`);
  }
}

async function printHighlight(command: Extract<ReadingCommand, { kind: "highlight" }>): Promise<void> {
  const document = await loadDocument(command.dir, command.documentId);
  const annotation = await addAnnotation(command.dir, {
    documentId: command.documentId,
    page: command.page,
    quote: command.quote,
    note: command.note,
    document,
  });
  console.log(annotation.id);
}

async function printHighlights(command: Extract<ReadingCommand, { kind: "highlights" }>): Promise<void> {
  const annotations = await listAnnotations(command.dir, command.documentId);
  if (annotations.length === 0) {
    console.log("no highlights");
    return;
  }
  for (const annotation of annotations) {
    console.log(`${annotation.id} ${annotation.documentId} ${String(annotation.page)} ${annotation.quote}`);
  }
}

async function printAsk(command: Extract<ReadingCommand, { kind: "ask" }>): Promise<void> {
  const annotation = await getAnnotation(command.dir, command.annotationId);
  const document = await loadDocument(command.dir, annotation.documentId);
  const page = document.pages.find((item) => item.page === annotation.page);
  if (!page) throw new Error(`page ${String(annotation.page)} is missing from document ${document.id}`);
  const answer = await askAboutHighlight({
    documentTitle: document.title,
    page: annotation.page,
    pageText: page.text,
    quote: annotation.quote,
    note: annotation.note,
    question: command.question,
    priorTurns: annotation.turns.map((turn) => ({ question: turn.question, answer: turn.answer })),
  });
  const saved = await recordTurn(command.dir, annotation.id, command.question, answer);
  console.log(saved.id);
  console.log(answer);
}

async function printRead(command: Extract<ReadingCommand, { kind: "read" }>): Promise<void> {
  await loadDocument(command.dir, command.documentId);
  const reader = await startReader({
    dir: command.dir,
    documentId: command.documentId,
    port: command.port,
  });
  console.log(reader.url);
}
