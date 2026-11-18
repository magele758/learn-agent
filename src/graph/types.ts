export type PropositionStatus = "unknown" | "learning" | "stable";

export interface Proposition {
  id: string;
  text: string;
  status: PropositionStatus;
  evidence: string[];
}

export interface Dependency {
  id: string;
  prerequisiteId: string;
  targetId: string;
}

export interface ReasoningStep {
  id: string;
  propositionId: string;
  because: string;
  source: "teach" | "practice";
}

export interface PracticeResult {
  id: string;
  propositionId: string;
  prompt: string;
  answer: string;
  passed: boolean;
}

export interface Graph {
  topic: string;
  propositions: Proposition[];
  dependencies: Dependency[];
  reasoning: ReasoningStep[];
  practice: PracticeResult[];
}

export function emptyGraph(topic: string): Graph {
  return { topic, propositions: [], dependencies: [], reasoning: [], practice: [] };
}
