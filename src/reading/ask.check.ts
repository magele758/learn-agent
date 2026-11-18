import { askAboutHighlight, type HighlightQuestion } from "./ask.ts";

const reasons: string[] = [];

function fail(reason: string): void {
  reasons.push(reason);
}

delete process.env.OPENAI_API_KEY;
delete process.env.OPENAI_BASE_URL;
delete process.env.OPENAI_MODEL;

const input: HighlightQuestion = {
  documentTitle: "测量笔记",
  page: 4,
  pageText: "页内写着杠杆比力臂更省力。",
  quote: "  杠杆比力臂更省力  ",
  note: "这里好像跳了一步",
  question: "  这句话在说什么？  ",
  priorTurns: [{ question: "力臂是什么？", answer: "支点到力的距离。" }],
};

const prior = input.priorTurns[0];
if (!prior) fail("fixture missing prior turn");

try {
  let prompt = "";
  const answer = await askAboutHighlight(input, {
    complete: async (text) => {
      prompt = text;
      return "注入的回答";
    },
  });
  if (answer !== "注入的回答") fail(`answer=${JSON.stringify(answer)}`);
  if (!prompt.includes("杠杆比力臂更省力")) fail("prompt missing quote");
  if (!prompt.includes("这句话在说什么？")) fail("prompt missing question");
  if (!prompt.includes(input.documentTitle)) fail("prompt missing document title");
  if (!prompt.includes(String(input.page))) fail("prompt missing page");
  if (!prompt.includes(input.pageText)) fail("prompt missing page text");
  if (!prompt.includes(input.note)) fail("prompt missing note");
  if (prior && !prompt.includes(prior.question)) fail("prompt missing prior question");
  if (prior && !prompt.includes(prior.answer)) fail("prompt missing prior answer");
} catch (error) {
  fail(error instanceof Error ? error.message : String(error));
}

{
  let called = false;
  try {
    await askAboutHighlight(
      { ...input, question: " \n\t " },
      {
        complete: async () => {
          called = true;
          return "should not run";
        },
      },
    );
    fail("empty question did not throw");
  } catch (error) {
    if (called) fail("empty question called complete");
    const message = error instanceof Error ? error.message : String(error);
    if (message.includes("OPENAI_API_KEY")) fail(`empty question reached the model: ${message}`);
  }
}

{
  let called = false;
  try {
    await askAboutHighlight(
      { ...input, quote: "  " },
      {
        complete: async () => {
          called = true;
          return "should not run";
        },
      },
    );
    fail("empty quote did not throw");
  } catch (error) {
    if (called) fail("empty quote called complete");
    const message = error instanceof Error ? error.message : String(error);
    if (message.includes("OPENAI_API_KEY")) fail(`empty quote reached the model: ${message}`);
  }
}

try {
  const answer = await askAboutHighlight(input, { complete: async () => "  \n" });
  fail(`blank answer returned ${JSON.stringify(answer)}`);
} catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  if (message.includes("OPENAI_API_KEY")) fail(`blank answer reached the model: ${message}`);
}

if (reasons.length > 0) {
  for (const reason of reasons) console.log(reason);
  process.exitCode = 1;
} else {
  console.log("ok");
}
