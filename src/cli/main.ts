import { readFile } from "node:fs/promises";
import path from "node:path";
import type { Graph } from "../graph/types.ts";
import { runReadingCli } from "./reading.ts";
import { runDemo } from "./run.ts";

const command = process.argv[2];
if (command !== "demo") {
  await runReadingCli(process.argv.slice(2));
} else {
  const dir = process.argv[3] ?? process.cwd();
  const file = await runDemo(dir);
  const graph = JSON.parse(await readFile(path.join(dir, "data/graph.json"), "utf8")) as Graph;
  const status = (id: string) => graph.propositions.find((row) => row.id === id)?.status;
  const prior = status("prior");
  const claim = status("claim");
  if (!prior || !claim) throw new Error("data/graph.json is missing prior or claim");
  console.log(file);
  console.log(`prior ${prior} claim ${claim}`);
}
