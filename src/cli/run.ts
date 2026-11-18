import path from "node:path";
import { loadGraph, saveGraph } from "../graph/store.ts";
import { ensureProposition, measure, plan, practice, teach } from "../session/runner.ts";

export async function runDemo(dir: string): Promise<string> {
  const graph = await loadGraph(dir, "local-demo");
  ensureProposition(graph, "prior", "A definition used by the next claim");
  ensureProposition(graph, "claim", "The claim that depends on the definition");
  if (!graph.dependencies.some((edge) => edge.targetId === "claim")) {
    graph.dependencies.push({ id: "dep-1", prerequisiteId: "prior", targetId: "claim" });
  }
  measure(graph, "prior", "learner restated the definition");
  const next = plan(graph, "claim");
  teach(graph, next.nextId, "the definition has to be stable before the claim");
  practice(graph, next.nextId, "restate the definition without looking", "definition", true);
  const file = await saveGraph(dir, graph);
  return path.resolve(file);
}
