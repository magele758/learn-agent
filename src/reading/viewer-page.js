import { getDocument, GlobalWorkerOptions } from "/vendor/build/pdf.mjs";
import { EventBus, PDFLinkService, PDFViewer } from "/vendor/web/pdf_viewer.mjs";

const LOADING_STATUS = "正在按原版排版…";
const MIN_SCALE = 0.4;
const MAX_SCALE = 3;
const SCALE_STEP = 1.15;

GlobalWorkerOptions.workerSrc = "/vendor/build/pdf.worker.mjs";

const status = document.getElementById("status");
const container = document.getElementById("viewerContainer");
const viewerElement = document.getElementById("viewer");
const picked = document.getElementById("picked");
const composer = document.getElementById("composer");

let lastQuote = null;

function writeStatus(message) {
  if (status) status.textContent = message;
}

function pageElement(node) {
  const element = node && node.nodeType === Node.ELEMENT_NODE ? node : node && node.parentElement;
  if (!element || typeof element.closest !== "function") return null;
  return element.closest(".page");
}

function onMouseUp() {
  const selection = window.getSelection();
  if (!selection || selection.rangeCount === 0 || selection.isCollapsed) return;
  const range = selection.getRangeAt(0);
  const startPage = pageElement(range.startContainer);
  const endPage = pageElement(range.endContainer);
  if (!startPage || startPage !== endPage) return;
  const quote = selection.toString();
  if (!quote.trim()) return;
  const page = Number(startPage.getAttribute("data-page-number"));
  if (!Number.isInteger(page) || page < 1) return;
  if (picked) picked.textContent = quote;
  if (composer) composer.classList.add("open");
  window.__pendingHighlight = { page, quote };
  if (lastQuote !== null && quote !== lastQuote) {
    const note = document.getElementById("note");
    if (note && "value" in note) note.value = "";
  }
  lastQuote = quote;
}

function bindZoom(viewer) {
  const zoomIn = document.getElementById("zoom-in");
  const zoomOut = document.getElementById("zoom-out");
  function setScale(next) {
    const current = viewer.currentScale;
    if (!Number.isFinite(current) || current <= 0) return;
    viewer.currentScale = Math.min(MAX_SCALE, Math.max(MIN_SCALE, next));
  }
  if (zoomIn) zoomIn.addEventListener("click", function () {
    setScale(viewer.currentScale * SCALE_STEP);
  });
  if (zoomOut) zoomOut.addEventListener("click", function () {
    setScale(viewer.currentScale / SCALE_STEP);
  });
}

document.addEventListener("mouseup", onMouseUp);

async function openDocument() {
  if (!container || !viewerElement) {
    throw new Error("缺少 #viewerContainer 或 #viewer");
  }
  writeStatus(LOADING_STATUS);
  const eventBus = new EventBus();
  const linkService = new PDFLinkService({ eventBus });
  const viewer = new PDFViewer({
    container,
    viewer: viewerElement,
    eventBus,
    linkService,
    textLayerMode: 1,
    annotationEditorMode: 0,
  });
  linkService.setViewer(viewer);
  eventBus.on("pagesinit", function () {
    viewer.currentScaleValue = "page-width";
    if (status && status.textContent === LOADING_STATUS) status.textContent = "";
  });
  bindZoom(viewer);
  const task = getDocument({
    url: "/document.pdf",
    cMapUrl: "/vendor/cmaps/",
    cMapPacked: true,
    standardFontDataUrl: "/vendor/standard_fonts/",
    disableRange: true,
    disableStream: true,
    isEvalSupported: false,
  });
  const pdf = await task.promise;
  viewer.setDocument(pdf);
  linkService.setDocument(pdf, null);
}

openDocument().catch(function (error) {
  writeStatus(error && error.message ? error.message : String(error));
});
