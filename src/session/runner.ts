import type { Graph, Proposition } from "../graph/types.ts";
import { agentLoopEntrypoint } from "./agent-loop.ts";

export type Phase = "measure" | "plan" | "teach" | "practice";

export function ensureProposition(graph: Graph, id: string, text: string): Proposition {
  const found = graph.propositions.find((item) => item.id === id);
  if (found) return found;
  const created: Proposition = { id, text, status: "unknown", evidence: [] };
  graph.propositions.push(created);
  return created;
}

export function measure(graph: Graph, id: string, evidence: string): Phase {
  const item = graph.propositions.find((row) => row.id === id);
  if (!item) throw new Error(`missing proposition ${id}`);
  item.status = "learning";
  item.evidence.push(evidence);
  return "plan";
}

export function plan(graph: Graph, targetId: string): { nextId: string; blockedBy: string | null } {
  const edges = graph.dependencies.filter((edge) => edge.targetId === targetId);
  for (const edge of edges) {
    const prior = graph.propositions.find((row) => row.id === edge.prerequisiteId);
    if (!prior || prior.status !== "stable") {
      return { nextId: edge.prerequisiteId, blockedBy: edge.prerequisiteId };
    }
  }
  return { nextId: targetId, blockedBy: null };
}

export function teach(graph: Graph, propositionId: string, because: string): Phase {
  const item = graph.propositions.find((row) => row.id === propositionId);
  if (!item) throw new Error(`missing proposition ${propositionId}`);
  graph.reasoning.push({
    id: `reason-${graph.reasoning.length + 1}`,
    propositionId,
    because,
    source: "teach",
  });
  if (item.status === "unknown") item.status = "learning";
  return "practice";
}

export function practice(
  graph: Graph,
  propositionId: string,
  prompt: string,
  answer: string,
  passed: boolean,
): Phase {
  const item = graph.propositions.find((row) => row.id === propositionId);
  if (!item) throw new Error(`missing proposition ${propositionId}`);
  graph.practice.push({
    id: `practice-${graph.practice.length + 1}`,
    propositionId,
    prompt,
    answer,
    passed,
  });
  item.status = passed ? "stable" : "learning";
  item.evidence.push(passed ? `practice passed: ${prompt}` : `practice missed: ${prompt}`);
  return passed ? "measure" : "teach";
}

/** Model turns stay in @ppeng/agent-loop. This module does not call a provider. */
export const AGENT_LOOP_ENTRY = agentLoopEntrypoint();
