import { readFile } from "node:fs/promises";
import path from "node:path";
import type { Graph } from "../graph/types.ts";
import { runDemo } from "./run.ts";

const reasons: string[] = [];

function check(ok: boolean, reason: string): void {
  if (!ok) reasons.push(reason);
}

try {
  await runDemo(process.cwd());
  const raw = await readFile(path.join(process.cwd(), "data/graph.json"), "utf8");
  const graph = JSON.parse(raw) as Graph;
  const prior = graph.propositions.find((item) => item.id === "prior");
  const claim = graph.propositions.find((item) => item.id === "claim");
  check(prior?.status === "stable", `prior.status=${prior?.status ?? "missing"}`);
  check(claim?.status === "unknown", `claim.status=${claim?.status ?? "missing"}`);
  check(graph.dependencies.length === 1, `dependencies.length=${graph.dependencies.length}`);
  check(graph.reasoning.length >= 1, `reasoning.length=${graph.reasoning.length}`);
  check(graph.practice.length >= 1, `practice.length=${graph.practice.length}`);
} catch (error) {
  reasons.push(error instanceof Error ? error.message : String(error));
}

if (reasons.length > 0) {
  for (const reason of reasons) console.log(reason);
  process.exitCode = 1;
} else {
  console.log("ok");
}
