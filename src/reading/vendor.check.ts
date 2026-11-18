import { statSync } from "node:fs";
import path from "node:path";
import { resolveVendorFile } from "./vendor.ts";

const reasons: string[] = [];

function check(ok: boolean, reason: string): void {
  if (!ok) reasons.push(reason);
}

function isFile(file: string): boolean {
  try {
    return statSync(file).isFile();
  } catch {
    return false;
  }
}

const worker = resolveVendorFile("/vendor/build/pdf.worker.mjs");
check(
  worker !== null && isFile(worker.file) && worker.file.endsWith(path.join("build", "pdf.worker.mjs")),
  `worker file=${worker?.file ?? "null"}`,
);
check(worker?.contentType === "text/javascript; charset=utf-8", `worker contentType=${worker?.contentType ?? "null"}`);

const viewer = resolveVendorFile("/vendor/web/pdf_viewer.mjs");
check(
  viewer !== null && isFile(viewer.file) && viewer.file.endsWith(path.join("web", "pdf_viewer.mjs")),
  `viewer file=${viewer?.file ?? "null"}`,
);
check(viewer?.contentType === "text/javascript; charset=utf-8", `viewer contentType=${viewer?.contentType ?? "null"}`);

const css = resolveVendorFile("/vendor/web/pdf_viewer.css");
check(
  css !== null && isFile(css.file) && css.file.endsWith(path.join("web", "pdf_viewer.css")),
  `css file=${css?.file ?? "null"}`,
);
check(css?.contentType === "text/css; charset=utf-8", `css contentType=${css?.contentType ?? "null"}`);

const blocked = [
  "/vendor/../package.json",
  "/vendor/web/../../package.json",
  "/etc/passwd",
  "/vendor/",
  "/vendor/%2e%2e/package.json",
  "/vendor/web/%2e%2e/%2e%2e/package.json",
  "/vendor/build\\pdf.worker.mjs",
  "/vendor/web",
  "/vendor/does-not-exist.mjs",
];
for (const urlPath of blocked) {
  const got = resolveVendorFile(urlPath);
  check(got === null, `${urlPath} => ${JSON.stringify(got)}`);
}

if (reasons.length > 0) {
  for (const reason of reasons) console.log(reason);
  process.exitCode = 1;
} else {
  console.log("ok");
}
