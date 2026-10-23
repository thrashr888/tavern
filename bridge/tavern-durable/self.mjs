// The agent's own view of itself: `my_info` reads what Tavern's info panel shows (model, spend,
// heartbeat, folders, approvals, what the machine offers), and `heartbeat_set` changes how often
// the heartbeat runs, or pauses it, once Paul allows it in Tavern. The new schedule is kept in
// <AGENT_CWD>/heartbeat-schedule.json, a file the agent can't write without approval.

import fs from "node:fs";
import path from "node:path";

export const SCHEDULE_FILE = "heartbeat-schedule.json";
const MAX_MINUTES = 24 * 60;

/** The saved schedule's minutes, or `fallback` when there's none (or it's unreadable). */
export function savedMinutes(cwd, fallback) {
  try {
    const minutes = JSON.parse(fs.readFileSync(path.join(cwd, SCHEDULE_FILE), "utf8")).everyMinutes;
    return Number.isInteger(minutes) && minutes >= 0 && minutes <= MAX_MINUTES ? minutes : fallback;
  } catch {
    return fallback;
  }
}

/** `info()` returns the agent's state; `setMinutes(n)` reschedules; `approvals` asks Paul. */
export function selfExtension({ approvals, info, setMinutes, cwd, name = "this agent" }) {
  const text = (value, isError = false) => ({ content: [{ type: "text", text: typeof value === "string" ? value : JSON.stringify(value, null, 2) }], ...(isError ? { isError } : {}) });
  return {
    name: "tavern-self",
    tools: [
      {
        name: "my_info",
        description:
          "Your own status as Tavern shows it: model, tokens and spend, heartbeat schedule and file, your folders, " +
          "approval policy, and what your machine offers (MCP servers, Docker containers, command-line tools).",
        parameters: { type: "object", properties: {} },
        replay: "safe",
        async execute() {
          return text(info());
        },
      },
      {
        name: "heartbeat_set",
        description:
          `How often your heartbeat runs, in minutes (0 pauses it; at most ${MAX_MINUTES}). Paul approves the change in Tavern. ` +
          "It only sets the timing: a beat runs HEARTBEAT.md in your folder (and heartbeat.json for checks), and does nothing " +
          "until one exists. This tool doesn't create them; write HEARTBEAT.md yourself to say what a beat does.",
        parameters: {
          type: "object",
          properties: {
            everyMinutes: { type: "integer", minimum: 0, maximum: MAX_MINUTES, description: "Minutes between beats; 0 pauses." },
            reason: { type: "string", description: "Why, in a sentence, for Paul." },
          },
          required: ["everyMinutes"],
        },
        replay: "safe",
        async execute(args, api, context) {
          const minutes = Number(args?.everyMinutes);
          if (!Number.isInteger(minutes) || minutes < 0 || minutes > MAX_MINUTES) return text(`everyMinutes must be a whole number from 0 to ${MAX_MINUTES}`, true);
          let answer = await api.memo("tavern.heartbeat", context);
          if (answer === undefined) {
            const title = minutes === 0 ? `Let ${name} pause its heartbeat?` : `Let ${name} run its heartbeat every ${minutes} min?`;
            const reply = await approvals.ask({ id: `approval-${api.taskId}`, title, message: String(args?.reason ?? "").slice(0, 1000) || undefined }, context?.abortSignal);
            answer = await api.memo("tavern.heartbeat", reply, context);
          }
          if (!answer?.allow) return text(answer?.note === "aborted" ? "The turn was aborted before Paul answered." : "Paul kept the current schedule.");
          fs.writeFileSync(path.join(cwd, SCHEDULE_FILE), JSON.stringify({ everyMinutes: minutes }, null, 2) + "\n");
          setMinutes(minutes);
          if (minutes === 0) return text("Heartbeat paused.");
          const ready = ["HEARTBEAT.md", "heartbeat.json"].some((file) => fs.existsSync(path.join(cwd, file)));
          return text(ready ? `Heartbeat now every ${minutes} min.`
            : `Heartbeat now every ${minutes} min, but your folder has no HEARTBEAT.md or heartbeat.json yet, so beats do nothing ` +
              `until you write ${path.join(cwd, "HEARTBEAT.md")} with what a beat should do.`);
        },
      },
    ],
  };
}
