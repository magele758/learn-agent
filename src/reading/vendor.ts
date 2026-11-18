import { realpathSync, statSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";

const require = createRequire(import.meta.url);
const VENDOR_PREFIX = "/vendor/";

// Physical path. A node_modules symlink must not widen the containment check.
const packageRoot = realpathSync(path.dirname(require.resolve("pdfjs-dist/package.json")));

const CONTENT_TYPES: Record<string, string> = {
  ".mjs": "text/javascript; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".gif": "image/gif",
  ".map": "application/json",
  ".json": "application/json",
};

export function resolveVendorFile(urlPath: string): { file: string; contentType: string } | null {
  if (!urlPath.startsWith(VENDOR_PREFIX)) return null;
  let decoded: string;
  try {
    decoded = decodeURIComponent(urlPath.slice(VENDOR_PREFIX.length));
  } catch {
    return null;
  }
  if (decoded.length === 0 || decoded.includes("..") || decoded.includes("\\") || decoded.includes("\0")) {
    return null;
  }

  const resolved = path.resolve(packageRoot, decoded);
  if (!isInside(packageRoot, resolved)) return null;

  let file: string;
  try {
    if (!statSync(resolved).isFile()) return null;
    file = realpathSync(resolved);
  } catch {
    return null;
  }
  if (!isInside(packageRoot, file)) return null;

  const contentType = CONTENT_TYPES[path.extname(file).toLowerCase()] ?? "application/octet-stream";
  return { file, contentType };
}

function isInside(root: string, target: string): boolean {
  const prefix = root.endsWith(path.sep) ? root : root + path.sep;
  return target === root || target.startsWith(prefix);
}
