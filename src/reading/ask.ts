import { createAssembledLoop, OpenAICompatibleAdapter, type SessionMessage } from "@ppeng/agent-loop";
import { createDefaultMemoryStore, DEFAULT_EMBED_AGENT } from "@ppeng/agent-loop/mini";

export interface HighlightQuestion {
  documentTitle: string;
  page: number;
  pageText: string;
  quote: string;
  note: string;
  question: string;
  priorTurns: { question: string; answer: string }[];
}

const DEFAULT_BASE_URL = "https://api.openai.com/v1";
const DEFAULT_MODEL = "gpt-4o-mini";

export async function askAboutHighlight(
  input: HighlightQuestion,
  options?: { complete?: (prompt: string) => Promise<string> },
): Promise<string> {
  const question = input.question.trim();
  const quote = input.quote.trim();
  if (!question) throw new Error("question is empty");
  if (!quote) throw new Error("quote is empty");

  const prompt = buildPrompt(input, question, quote);
  if (options?.complete) return requireAnswer(await options.complete(prompt));
  return requireAnswer(await askWithLoop(prompt));
}

function buildPrompt(input: HighlightQuestion, question: string, quote: string): string {
  const history =
    input.priorTurns.length === 0
      ? "（无）"
      : input.priorTurns.map((turn) => `问：${turn.question}\n答：${turn.answer}`).join("\n");
  return [
    "只根据这一页正文和划线原文回答。这一页和划线里没有的内容，就说不知道。",
    "",
    `文档标题：${input.documentTitle}`,
    `页码：${input.page}`,
    "划线原文：",
    quote,
    "用户批注：",
    input.note.trim(),
    "这一页正文：",
    input.pageText,
    "过往问答：",
    history,
    "这次的问题：",
    question,
  ].join("\n");
}

function requireAnswer(text: string): string {
  const answer = text.trim();
  if (!answer) throw new Error("assistant answer is empty");
  return answer;
}

function lastAssistantText(messages: readonly SessionMessage[]): string {
  const message = [...messages].reverse().find((item) => item.role === "assistant");
  const text =
    message?.parts
      .filter((part) => part.type === "text")
      .map((part) => part.text)
      .join("\n") ?? "";
  return requireAnswer(text);
}

async function askWithLoop(prompt: string): Promise<string> {
  const apiKey = process.env.OPENAI_API_KEY?.trim() ?? "";
  if (!apiKey) {
    throw new Error("OPENAI_API_KEY is missing. Set the OPENAI_API_KEY environment variable.");
  }
  const baseUrl = process.env.OPENAI_BASE_URL?.trim() || DEFAULT_BASE_URL;
  const model = process.env.OPENAI_MODEL?.trim() || DEFAULT_MODEL;
  const { store, surface } = createDefaultMemoryStore({ agent: DEFAULT_EMBED_AGENT });
  const session = surface.createSession({
    title: "highlight",
    mode: "chat",
    agentId: DEFAULT_EMBED_AGENT.id,
  });
  surface.appendMessage(session.id, "user", [{ type: "text", text: prompt }]);
  const loop = await createAssembledLoop({
    preset: "mini",
    io: {
      store,
      maxTurns: 1,
      model: new OpenAICompatibleAdapter({
        apiKey,
        baseUrl,
        model,
        useJsonMode: false,
      }),
    },
  });
  await loop.run(session.id);
  return lastAssistantText(store.foldMessages(session.id));
}
