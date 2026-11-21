// Tools a client lends the agent while it's connected: the iPhone app offers its location and
// battery. The host lists them as agent tools all the time; a call goes to a connected client
// that lends that tool and waits for its answer, or says no phone is connected. They change
// nothing, but they reveal where Paul is, so the host's approvals ask before each call.
//
// Client → host: {"type":"lend_tools","tools":["phone_location", ...]} (an empty list takes them back)
// Host → client: {"type":"lent_tool_request","id":"…","tool":"phone_location","arguments":{…}}
// Client → host: {"type":"lent_tool_response","id":"…","result":{…}} or {"…","error":"…"}

import crypto from "node:crypto";

export const LENT_TOOLS = [
  {
    name: "phone_location",
    description: "Paul's iPhone's current location (latitude, longitude, accuracy in meters, and a place name when the phone has one). Only while the phone app is connected; Paul approves each call.",
    parameters: { type: "object", properties: {} },
  },
  {
    name: "phone_battery",
    description: "Paul's iPhone's battery level (0-100) and whether it's charging. Only while the phone app is connected; Paul approves each call.",
    parameters: { type: "object", properties: {} },
  },
];

const TIMEOUT_MS = 60_000;

export class LentTools {
  #lenders = new Map(); // socket -> Set of tool names
  #pending = new Map(); // id -> { resolve, reject, timer, socket }
  #send;

  /** `send(socket, record)` writes one line to a client. */
  constructor(send) {
    this.#send = send;
  }

  get names() {
    return LENT_TOOLS.map((tool) => tool.name);
  }

  /** A client's `lend_tools`: the tools it answers for from now on. */
  lend(socket, tools) {
    const known = new Set(this.names);
    const lent = new Set((Array.isArray(tools) ? tools : []).filter((name) => known.has(name)));
    if (lent.size) this.#lenders.set(socket, lent);
    else this.#lenders.delete(socket);
    return [...lent];
  }

  /** A client went away: its tools go, and calls waiting on it fail. */
  drop(socket) {
    this.#lenders.delete(socket);
    for (const [id, call] of this.#pending) {
      if (call.socket !== socket) continue;
      clearTimeout(call.timer);
      this.#pending.delete(id);
      call.reject(new Error("The phone disconnected before answering."));
    }
  }

  /** A client's `lent_tool_response`. */
  answer(socket, message) {
    const call = this.#pending.get(String(message?.id));
    if (!call || call.socket !== socket) return false;
    clearTimeout(call.timer);
    this.#pending.delete(String(message.id));
    if (message.error) call.reject(new Error(String(message.error)));
    else call.resolve(message.result ?? null);
    return true;
  }

  /** Asks the newest client lending `tool`. */
  call(tool, args = {}) {
    const socket = [...this.#lenders].reverse().find(([, tools]) => tools.has(tool))?.[0];
    if (!socket) return Promise.reject(new Error("No phone is connected to lend that tool. Ask Paul to open Tavern on his iPhone."));
    const id = crypto.randomUUID();
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.#pending.delete(id);
        reject(new Error("The phone didn't answer in time."));
      }, TIMEOUT_MS);
      timer.unref?.();
      this.#pending.set(id, { resolve, reject, timer, socket });
      this.#send(socket, { type: "lent_tool_request", id, tool, arguments: args });
    });
  }

  /** The Pi Durable extension with the lent tools. */
  extension() {
    return {
      name: "tavern-lent-tools",
      tools: LENT_TOOLS.map((tool) => ({
        ...tool,
        replay: "unsafe",
        execute: async (args) => {
          try {
            const result = await this.call(tool.name, args ?? {});
            return { content: [{ type: "text", text: JSON.stringify(result) }], details: { lent: { tool: tool.name, result } } };
          } catch (error) {
            return { content: [{ type: "text", text: String(error?.message ?? error) }], isError: true };
          }
        },
      })),
    };
  }
}
