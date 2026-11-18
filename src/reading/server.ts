import { createReadStream } from "node:fs";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { fileURLToPath } from "node:url";
import { addAnnotation, listAnnotations, recordTurn } from "./annotations.ts";
import { askAboutHighlight } from "./ask.ts";
import { loadDocument } from "./import-pdf.ts";
import type { Annotation, ReadingDocument } from "./types.ts";
import { resolveVendorFile } from "./vendor.ts";

const VIEWER_SCRIPT = fileURLToPath(new URL("./viewer-page.js", import.meta.url));

export interface StartReaderOptions {
  dir: string;
  documentId: string;
  port: number;
  complete?: (prompt: string) => Promise<string>;
}

export interface ReaderServer {
  url: string;
  close(): Promise<void>;
}

interface HighlightBody {
  page: number;
  quote: string;
  note: string;
  question: string;
}

class HttpError extends Error {
  readonly status: number;

  constructor(status: number, message: string) {
    super(message);
    this.name = "HttpError";
    this.status = status;
  }
}

export function startReader(options: StartReaderOptions): Promise<ReaderServer> {
  const server = createServer((req, res) => {
    void handle(req, res, options);
  });
  return new Promise((resolve, reject) => {
    const onError = (error: Error) => {
      reject(error);
    };
    server.once("error", onError);
    server.listen(options.port, "127.0.0.1", () => {
      server.off("error", onError);
      const address = server.address();
      if (address === null || typeof address === "string") {
        reject(new Error("reader failed to bind 127.0.0.1"));
        return;
      }
      resolve({
        url: `http://127.0.0.1:${String(address.port)}/`,
        close: () => closeServer(server),
      });
    });
  });
}

async function handle(req: IncomingMessage, res: ServerResponse, options: StartReaderOptions): Promise<void> {
  try {
    const pathname = pathnameOf(req);
    if (req.method === "GET" && pathname === "/") {
      const document = await loadDocument(options.dir, options.documentId);
      sendText(res, 200, readerHtml(document), "text/html; charset=utf-8");
      return;
    }
    if (req.method === "GET" && pathname === "/viewer.js") {
      sendFile(res, VIEWER_SCRIPT, "text/javascript; charset=utf-8");
      return;
    }
    if (req.method === "GET" && pathname === "/document.pdf") {
      const document = await loadDocument(options.dir, options.documentId);
      sendFile(res, document.sourcePath, "application/pdf");
      return;
    }
    if (req.method === "GET" && pathname.startsWith("/vendor/")) {
      const asset = resolveVendorFile(pathname);
      if (!asset) {
        sendText(res, 404, "not found");
        return;
      }
      sendFile(res, asset.file, asset.contentType);
      return;
    }
    if (req.method === "GET" && pathname === "/api/highlights") {
      sendJson(res, 200, await listAnnotations(options.dir, options.documentId));
      return;
    }
    if (req.method === "POST" && pathname === "/api/highlights") {
      await postHighlight(req, res, options);
      return;
    }
    sendText(res, 404, "not found");
  } catch (error) {
    if (res.headersSent) return;
    if (error instanceof HttpError) {
      sendText(res, error.status, error.message);
      return;
    }
    sendText(res, 500, error instanceof Error ? error.message : String(error));
  }
}

async function postHighlight(req: IncomingMessage, res: ServerResponse, options: StartReaderOptions): Promise<void> {
  const body = parseHighlightBody(await readBody(req));
  const document = await loadDocument(options.dir, options.documentId);
  let annotation: Annotation;
  try {
    annotation = await addAnnotation(options.dir, {
      documentId: options.documentId,
      page: body.page,
      quote: body.quote,
      note: body.note,
      document,
    });
  } catch (error) {
    throw new HttpError(400, error instanceof Error ? error.message : String(error));
  }

  const question = body.question.trim();
  if (question.length === 0) {
    sendJson(res, 200, { annotation, error: null });
    return;
  }

  const page = document.pages.find((item) => item.page === annotation.page);
  if (!page) {
    sendJson(res, 200, {
      annotation,
      error: `page ${String(annotation.page)} is missing from document ${document.id}`,
    });
    return;
  }

  try {
    const answer = await askAboutHighlight(
      {
        documentTitle: document.title,
        page: annotation.page,
        pageText: page.text,
        quote: annotation.quote,
        note: annotation.note,
        question,
        priorTurns: annotation.turns.map((turn) => ({ question: turn.question, answer: turn.answer })),
      },
      options.complete ? { complete: options.complete } : undefined,
    );
    annotation = await recordTurn(options.dir, annotation.id, question, answer);
    sendJson(res, 200, { annotation, error: null });
  } catch (error) {
    sendJson(res, 200, {
      annotation,
      error: error instanceof Error ? error.message : String(error),
    });
  }
}

function parseHighlightBody(raw: string): HighlightBody {
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    throw new HttpError(400, "invalid JSON");
  }
  if (!isRecord(value)) throw new HttpError(400, "invalid JSON");
  if (!Object.hasOwn(value, "page")) throw new HttpError(400, "missing page");
  if (typeof value.page !== "number" || !Number.isInteger(value.page)) throw new HttpError(400, "invalid page");
  if (typeof value.quote !== "string") throw new HttpError(400, "missing quote");
  const note = Object.hasOwn(value, "note") ? value.note : "";
  const question = Object.hasOwn(value, "question") ? value.question : "";
  if (typeof note !== "string") throw new HttpError(400, "invalid note");
  if (typeof question !== "string") throw new HttpError(400, "invalid question");
  return { page: value.page, quote: value.quote, note, question };
}

function readBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let size = 0;
    req.on("data", (chunk: Buffer | string) => {
      const buffer = typeof chunk === "string" ? Buffer.from(chunk) : chunk;
      size += buffer.length;
      if (size > 1_000_000) {
        reject(new HttpError(400, "body too large"));
        req.destroy();
        return;
      }
      chunks.push(buffer);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

function pathnameOf(req: IncomingMessage): string {
  const url = new URL(req.url ?? "/", "http://127.0.0.1");
  if (url.pathname.length > 1 && url.pathname.endsWith("/")) return url.pathname.slice(0, -1);
  return url.pathname;
}

function sendText(res: ServerResponse, status: number, body: string, contentType = "text/plain; charset=utf-8"): void {
  res.writeHead(status, { "content-type": contentType, "cache-control": "no-store" });
  res.end(body);
}

function sendFile(res: ServerResponse, file: string, contentType: string): void {
  res.writeHead(200, { "content-type": contentType, "cache-control": "no-store" });
  const stream = createReadStream(file);
  stream.on("error", () => {
    if (!res.headersSent) res.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
    res.end();
  });
  stream.pipe(res);
}

function sendJson(res: ServerResponse, status: number, body: unknown): void {
  sendText(res, status, JSON.stringify(body), "application/json; charset=utf-8");
}

function closeServer(server: Server): Promise<void> {
  return new Promise((resolve, reject) => {
    server.close((error) => {
      if (error) reject(error);
      else resolve();
    });
    // fetch keeps the socket open, so close() would wait out the idle timeout.
    server.closeAllConnections();
  });
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function readerHtml(document: ReadingDocument): string {
  return `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHtml(document.title)}</title>
<link rel="stylesheet" href="/vendor/web/pdf_viewer.css">
<style>
${READER_CSS}
</style>
</head>
<body>
<div class="layout">
  <div class="pages">
    <div class="toolbar">
      <button type="button" id="zoom-out">缩小</button>
      <button type="button" id="zoom-in">放大</button>
    </div>
    <div id="viewerContainer"><div id="viewer" class="pdfViewer"></div></div>
  </div>
  <aside>
    <h1>${escapeHtml(document.title)}</h1>
    <p class="help">这是 PDF 原版页面。用鼠标划选文字，再在这里写笔记或提问。</p>
    <div id="composer">
      <p id="picked"></p>
      <label for="note">笔记</label>
      <textarea id="note" rows="3"></textarea>
      <label for="question">问题</label>
      <textarea id="question" rows="3"></textarea>
      <div class="actions">
        <button type="button" id="save">保存批注</button>
        <button type="button" id="ask">保存并提问</button>
      </div>
    </div>
    <p id="status"></p>
    <div id="list"></div>
  </aside>
</div>
<script type="module" src="/viewer.js"></script>
<script>
${READER_SCRIPT}
</script>
</body>
</html>
`;
}

const READER_CSS = `
body {
  margin: 0;
  background: #fff;
  color: #1c1c1c;
  font-family: "Helvetica Neue", Helvetica, Arial, sans-serif;
  font-size: 16px;
  line-height: 1.5;
}
.layout {
  display: grid;
  grid-template-columns: minmax(0, 1fr) 24rem;
  height: 100vh;
}
.pages {
  position: relative;
  min-width: 0;
  height: 100vh;
  background: #3a3a3a;
}
.toolbar {
  position: relative;
  z-index: 2;
  display: flex;
  gap: 0.5rem;
  padding: 0.45rem 0.75rem;
  background: #2b2b2b;
}
.toolbar button {
  color: #f5f5f5;
  border-color: #8d8d8d;
  background: transparent;
}
#viewerContainer {
  position: absolute;
  top: 2.6rem;
  right: 0;
  bottom: 0;
  left: 0;
  overflow: auto;
}
aside {
  box-sizing: border-box;
  border-left: 1px solid #e4e4e4;
  padding: 1.25rem 1.25rem 2rem;
  position: sticky;
  top: 0;
  max-height: 100vh;
  overflow: auto;
}
h1 { font-size: 1.15rem; font-weight: 600; margin: 0 0 0.5rem; }
.help { margin: 0 0 1rem; }
#composer { display: none; margin-bottom: 1rem; }
#composer.open { display: block; }
#picked {
  margin: 0 0 0.75rem;
  padding-left: 0.6rem;
  border-left: 3px solid #f3e2a0;
  white-space: pre-wrap;
}
label { display: block; margin: 0.55rem 0 0.2rem; font-size: 0.85rem; }
textarea {
  width: 100%;
  box-sizing: border-box;
  font: inherit;
  border: 1px solid #c8c8c8;
  background: #fff;
  padding: 0.4rem 0.5rem;
  resize: vertical;
}
.actions { display: flex; gap: 0.5rem; margin-top: 0.75rem; }
button {
  font: inherit;
  background: #fff;
  color: #1c1c1c;
  border: 1px solid #1c1c1c;
  padding: 0.35rem 0.7rem;
}
#status { min-height: 1.2em; margin: 0 0 0.5rem; color: #8d1d1d; }
#list .item { border-top: 1px solid #e4e4e4; padding: 0.8rem 0; }
#list p { margin: 0.2rem 0; }
@media (max-width: 860px) {
  .layout { grid-template-columns: 1fr; }
  aside {
    position: static;
    max-height: none;
    border-left: 0;
    border-top: 1px solid #e4e4e4;
  }
}
`;

const READER_SCRIPT = `
var composer = document.getElementById("composer");
var picked = document.getElementById("picked");
var note = document.getElementById("note");
var question = document.getElementById("question");
var status = document.getElementById("status");
var list = document.getElementById("list");
var saveButton = document.getElementById("save");
var askButton = document.getElementById("ask");
var saving = false;

function renderList(items) {
  list.replaceChildren();
  if (!Array.isArray(items) || items.length === 0) {
    var empty = document.createElement("p");
    empty.textContent = "还没有批注。";
    list.append(empty);
    return;
  }
  for (var index = 0; index < items.length; index += 1) {
    var item = items[index];
    var block = document.createElement("section");
    block.className = "item";
    var quote = document.createElement("p");
    quote.textContent = item.quote;
    var noteLine = document.createElement("p");
    noteLine.textContent = item.note;
    var noteLabel = document.createElement("p");
    noteLabel.textContent = "笔记";
    block.append(quote, noteLabel, noteLine);
    var turns = Array.isArray(item.turns) ? item.turns : [];
    for (var turnIndex = 0; turnIndex < turns.length; turnIndex += 1) {
      var turn = turns[turnIndex];
      var questionLine = document.createElement("p");
      questionLine.textContent = turn.question;
      var questionLabel = document.createElement("p");
      questionLabel.textContent = "问题";
      var answerLine = document.createElement("p");
      answerLine.textContent = turn.answer;
      var answerLabel = document.createElement("p");
      answerLabel.textContent = "回答";
      block.append(questionLabel, questionLine, answerLabel, answerLine);
    }
    list.append(block);
  }
}

async function refresh() {
  var response = await fetch("/api/highlights");
  if (!response.ok) {
    status.textContent = await response.text();
    return;
  }
  renderList(await response.json());
}

async function save(withQuestion) {
  var pending = window.__pendingHighlight;
  if (!pending || saving) return;
  saving = true;
  saveButton.disabled = true;
  askButton.disabled = true;
  var asked = withQuestion && question.value.trim().length > 0;
  try {
    var response = await fetch("/api/highlights", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        page: pending.page,
        quote: pending.quote,
        note: note.value,
        question: withQuestion ? question.value : "",
      }),
    });
    if (!response.ok) {
      status.textContent = await response.text();
      return;
    }
    var payload = await response.json();
    note.value = "";
    question.value = "";
    window.__pendingHighlight = null;
    composer.classList.remove("open");
    picked.textContent = "";
    await refresh();
    if (payload && payload.error) status.textContent = payload.error;
    else if (withQuestion && !asked) status.textContent = "没有写问题，只保存了批注。";
    else status.textContent = "";
  } catch (error) {
    status.textContent = error && error.message ? error.message : String(error);
  } finally {
    saving = false;
    saveButton.disabled = false;
    askButton.disabled = false;
  }
}

saveButton.addEventListener("click", function () { save(false); });
askButton.addEventListener("click", function () { save(true); });
refresh();
`;
