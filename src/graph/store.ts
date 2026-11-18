import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { emptyGraph, type Graph } from "./types.ts";

export const GRAPH_FILE = "data/graph.json";

export async function loadGraph(dir: string, topic = "untitled"): Promise<Graph> {
  const file = path.join(dir, GRAPH_FILE);
  try {
    const raw = await readFile(file, "utf8");
    return JSON.parse(raw) as Graph;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return emptyGraph(topic);
    throw error;
  }
}

export async function saveGraph(dir: string, graph: Graph): Promise<string> {
  const file = path.join(dir, GRAPH_FILE);
  await mkdir(path.dirname(file), { recursive: true });
  await writeFile(file, JSON.stringify(graph, null, 2) + "\n");
  return file;
}
