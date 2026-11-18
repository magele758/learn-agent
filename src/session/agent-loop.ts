/** Local name of the assembler in @ppeng/agent-loop. This does not start a turn. */
export function agentLoopEntrypoint(): string {
  return "createAssembledLoop";
}

/** Resolve the local package. A missing install is a result, not a throw. */
export async function loadAgentLoop(): Promise<{ ok: true } | { ok: false; reason: string }> {
  try {
    await import("@ppeng/agent-loop");
    return { ok: true };
  } catch (error: unknown) {
    const reason = error instanceof Error ? error.message : String(error);
    return { ok: false, reason };
  }
}
