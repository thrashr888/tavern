// The `ask` tool: the agent puts a question to Paul, as choices (a select dialog) or a short
// answer (an input dialog), and waits for it. It shares the approvals queue, so Tavern shows one
// question at a time, by the composer, and a client that reconnects is asked again. The answer is
// a memo of the tool task: a host restart while waiting asks again (same id), and a restart after
// answering doesn't.

const MAX_OPTIONS = 12;

export const ASK_PREFIX = "ask-";

/** The dialog for one call, or why the arguments don't make one. */
export function askDialog(args, taskId) {
  const question = String(args?.question ?? "").trim().slice(0, 1000);
  if (!question) return { error: "question is required" };
  const options = [...new Set((Array.isArray(args?.options) ? args.options : []).map((o) => String(o ?? "").trim().slice(0, 200)).filter(Boolean))];
  if (options.length === 1) return { error: "give at least two options, or none for a written answer" };
  if (options.length > MAX_OPTIONS) return { error: `at most ${MAX_OPTIONS} options` };
  const detail = String(args?.detail ?? "").trim().slice(0, 4000) || undefined;
  return options.length
    ? { id: `${ASK_PREFIX}${taskId}`, method: "select", title: question, message: detail, options }
    : { id: `${ASK_PREFIX}${taskId}`, method: "input", title: question, message: detail, placeholder: String(args?.placeholder ?? "").slice(0, 200) || undefined };
}

/** What the agent reads back. */
export function answerText(answer) {
  if (answer?.note === "aborted") return "The turn was aborted before Paul answered.";
  if (answer?.cancelled || answer?.value == null) return "Paul dismissed the question without answering.";
  return `Paul answered: ${answer.value}`;
}

export function askExtension(approvals) {
  return {
    name: "tavern-ask",
    tools: [
      {
        name: "ask",
        description:
          "Ask Paul a question in Tavern and wait for the answer. With options (2-12), he picks one; without, he types a short answer. " +
          "Use it when you need his decision or a missing detail to continue, not for updates. One question per call.",
        parameters: {
          type: "object",
          properties: {
            question: { type: "string", description: "The question, short and specific." },
            options: { type: "array", items: { type: "string" }, maxItems: MAX_OPTIONS, description: "Choices to pick from; omit for a written answer." },
            detail: { type: "string", description: "Optional context shown under the question." },
            placeholder: { type: "string", description: "Hint in the answer field (written answers only)." },
          },
          required: ["question"],
        },
        // Waiting on Paul is safe to repeat after a restart: it asks again, or reads the stored answer.
        replay: "safe",
        async execute(args, api, context) {
          const dialog = askDialog(args, api.taskId);
          if (dialog.error) return { content: [{ type: "text", text: dialog.error }], isError: true };
          let answer = await api.memo("tavern.ask", context);
          if (answer === undefined) {
            const reply = await approvals.ask(dialog, context?.abortSignal);
            answer = await api.memo("tavern.ask", reply, context);
          }
          return { content: [{ type: "text", text: answerText(answer) }], details: { ask: { question: dialog.title, options: dialog.options ?? null, answer: answer?.value ?? null } } };
        },
      },
    ],
  };
}
