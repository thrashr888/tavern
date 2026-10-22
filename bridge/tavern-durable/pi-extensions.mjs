// Standard Pi extensions in a durable session. Pi Durable v1.0 has its own extension format
// (tools, prompt sections, task hooks) and doesn't load the packages `pi install` adds, so the
// host loads them with Pi's own loader and offers what fits a headless, long-lived session:
//
// - registered tools become agent tools (`replay: "unsafe"`: they may change things);
// - `before_agent_start` handlers render into a prompt section, refreshed when a new prompt
//   arrives, so a package that appends to the system prompt (memory, house rules) still does;
// - `session_start`, `agent_end`, `session_compact` and `session_shutdown` fire from the host,
//   which sees the session start, turns settle, compactions land and the process stop;
// - `ctx.modelRegistry` and `ctx.model` are pi's own, so a package can use the agent's model
//   access (pi-cortex hands it to cortex) without a key of its own.
//
// Commands, shortcuts, renderers and UI dialogs need a terminal and are ignored. A handler or
// tool that throws is logged and skipped; one package can't stop the host.

import path from "node:path";
import { pathToFileURL } from "node:url";

/**
 * Loads the extensions of the packages Pi's settings list (`pi install`), plus the agent's
 * `.pi/extensions/` and `~/.pi/agent/extensions/`, with Pi's own package manager and loader.
 */
export async function loadPiExtensions({ piRepo, cwd, log = () => {} }) {
  const src = path.join(piRepo, "packages/coding-agent/src");
  const load = (file) => import(pathToFileURL(path.join(src, file)).href);
  const [{ getAgentDir }, { SettingsManager }, { DefaultPackageManager }, { loadExtensions }, { ModelRuntime }, { ModelRegistry }] = await Promise.all([
    load("config.ts"),
    load("core/settings-manager.ts"),
    load("core/package-manager.ts"),
    load("core/extensions/loader.ts"),
    load("core/model-runtime.ts"),
    load("core/model-registry.ts"),
  ]);
  const agentDir = getAgentDir();
  const settingsManager = SettingsManager.create(cwd, agentDir);
  const resolved = await new DefaultPackageManager({ cwd, agentDir, settingsManager }).resolve(async () => "skip");
  const paths = resolved.extensions.filter((r) => r.enabled && !r.path.startsWith("builtin:")).map((r) => r.path);
  const result = await loadExtensions(paths, cwd);
  for (const { path: file, error } of result.errors) log(`pi extension ${file} didn't load: ${error}`);
  // Only when something loaded: the registry reads pi's logins and model catalog.
  const modelRegistry = result.extensions.length
    ? await ModelRuntime.create().then((runtime) => new ModelRegistry(runtime)).catch((error) => (log(`pi models unavailable to extensions: ${error?.message ?? error}`), undefined))
    : undefined;
  return { ...result, modelRegistry };
}

/** A display name for a loaded extension: its package folder, or its file. */
export function extensionName(extension) {
  const file = String(extension?.path ?? "extension");
  const parts = file.split(path.sep);
  const modules = parts.lastIndexOf("node_modules");
  if (modules >= 0) return parts.slice(modules + 1, parts[modules + 1]?.startsWith("@") ? modules + 3 : modules + 2).join("/");
  return path.basename(file).replace(/\.(ts|js|mjs)$/, "") === "index" ? path.basename(path.dirname(file)) : path.basename(file);
}

/** Text of a pi-ai content value (a string or text blocks). */
function textOf(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.filter((b) => b?.type === "text").map((b) => b.text ?? "").join("\n");
}

/** Plain JSON for a tool's details: Pi Durable stores them, and they must round-trip. */
function jsonOf(value) {
  if (value === undefined) return undefined;
  try {
    return JSON.parse(JSON.stringify(value));
  } catch {
    return undefined;
  }
}

/**
 * Bridges loaded Pi extensions into one Pi Durable extension.
 *
 * `host` gives them the session: `cwd`, `submit(text)` (a follow-up), `compact(instructions)`,
 * `abort()`, `isIdle()`, `model()` (the session's `{provider, id}`), `notify(message, level)`
 * and `log(message)`.
 */
export function piExtensionBridge(loaded, host) {
  const extensions = loaded?.extensions ?? [];
  const log = host.log ?? (() => {});
  const names = extensions.map(extensionName);

  const ui = {
    notify: (message, level = "info") => host.notify?.(String(message), level === "error" ? "error" : level === "warning" ? "warning" : "info"),
    // Dialogs need someone at a terminal; headless answers are "no" and "nothing".
    confirm: async () => false,
    select: async () => undefined,
    input: async () => undefined,
    editor: async () => undefined,
    custom: async () => undefined,
    setStatus() {}, setWidget() {}, setFooter() {}, setHeader() {}, setTitle() {}, setWorkingMessage() {},
    setEditorText() {}, getEditorText: () => "", pasteToEditor() {}, onTerminalInput: () => () => {},
    theme: undefined,
  };
  const sessionManager = {
    getCwd: () => host.cwd,
    getSessionId: () => host.sessionId ?? "durable",
    getSessionFile: () => undefined,
    getSessionName: () => undefined,
    getEntries: () => [],
    getBranch: () => [],
    getLeafId: () => null,
    getHeader: () => undefined,
  };
  const ctx = {
    ui,
    mode: "rpc",
    hasUI: false,
    cwd: host.cwd,
    sessionManager,
    modelRegistry: loaded?.modelRegistry,
    /** The session's model as pi's registry knows it. */
    get model() {
      const ref = host.model?.();
      return ref && loaded?.modelRegistry ? loaded.modelRegistry.find(ref.provider, ref.id) : undefined;
    },
    scopedModels: [],
    signal: undefined,
    isIdle: () => host.isIdle?.() ?? true,
    isProjectTrusted: () => true,
    abort: () => void host.abort?.(),
    hasPendingMessages: () => false,
    shutdown() {},
    getContextUsage: () => undefined,
    compact: (options) => void host.compact?.(options?.customInstructions),
    getSystemPrompt: () => "",
  };

  // What the extensions' `pi.*` actions do here. Pi binds these when it runs a session; the
  // durable host is that session now.
  if (loaded?.runtime) {
    Object.assign(loaded.runtime, {
      sendUserMessage: (content) => void host.submit?.(textOf(content)),
      sendMessage: (message, options) => {
        const text = textOf(message?.content);
        if (options?.triggerTurn && text) host.submit?.(text);
      },
      appendEntry() {},
      setSessionName() {},
      getSessionName: () => undefined,
      setLabel() {},
      getActiveTools: () => tools.map((t) => t.name),
      getAllTools: () => tools.map((t) => ({ name: t.name, description: t.description, parameters: t.parameters })),
      setActiveTools() {},
      getSettings: () => ({}),
      getCommands: () => [],
      getThinkingLevel: () => undefined,
      setThinkingLevel() {},
      createContext: () => ctx,
    });
  }

  /** Runs every handler for `event.type` in load order; returns their results. */
  async function emit(event) {
    const results = [];
    for (const [i, extension] of extensions.entries()) {
      for (const handler of extension.handlers?.get(event.type) ?? []) {
        try {
          results.push(await handler(event, ctx));
        } catch (error) {
          log(`${names[i]} ${event.type} failed: ${error?.message ?? error}`);
        }
      }
    }
    return results;
  }

  const tools = extensions.flatMap((extension, i) =>
    [...(extension.tools?.values() ?? [])].map(({ definition }) => ({
      name: definition.name,
      description: definition.description ?? definition.name,
      parameters: definition.parameters,
      replay: "unsafe",
      guidelines: Array.isArray(definition.promptGuidelines) ? definition.promptGuidelines : [],
      async execute(args, api, context) {
        try {
          const toolCtx = Object.create(ctx, { signal: { value: context?.abortSignal }, tools: { value: [] } });
          const result = await definition.execute(api?.callId ?? "", args, context?.abortSignal, undefined, toolCtx);
          const content = Array.isArray(result?.content) ? result.content : [{ type: "text", text: textOf(result?.content) }];
          return { content, details: jsonOf(result?.details), isError: result?.isError === true };
        } catch (error) {
          log(`${names[i]} tool ${definition.name} failed: ${error?.message ?? error}`);
          return { content: [{ type: "text", text: `${definition.name} failed: ${error?.message ?? error}` }], isError: true };
        }
      },
    })),
  );

  // The section re-renders on every request; handlers run once per prompt.
  let prompt = "";
  let rendered = { prompt: null, text: undefined };
  const guidelines = tools.flatMap((t) => t.guidelines.map((g) => `- ${g}`));
  const hasPromptHandlers = extensions.some((e) => e.handlers?.has("before_agent_start"));
  const section = {
    key: "pi-extensions",
    tag: false,
    async render() {
      if (rendered.prompt === prompt) return rendered.text;
      let systemPrompt = "";
      const messages = [];
      for (const [i, extension] of extensions.entries()) {
        for (const handler of extension.handlers?.get("before_agent_start") ?? []) {
          try {
            const result = await handler({ type: "before_agent_start", prompt, systemPrompt, systemPromptOptions: {} }, ctx);
            if (typeof result?.systemPrompt === "string") systemPrompt = result.systemPrompt;
            if (result?.message) messages.push(textOf(result.message.content));
          } catch (error) {
            log(`${names[i]} before_agent_start failed: ${error?.message ?? error}`);
          }
        }
      }
      const parts = [guidelines.length ? `Tool guidelines:\n${guidelines.join("\n")}` : "", systemPrompt.trim(), ...messages.map((m) => m.trim())];
      const text = parts.filter(Boolean).join("\n\n") || undefined;
      rendered = { prompt, text };
      return text;
    },
  };

  const extension = {
    name: "pi-extensions",
    tools: tools.map(({ guidelines: _, ...tool }) => tool),
    sections: hasPromptHandlers || guidelines.length ? [section] : [],
  };

  return {
    extension,
    names,
    emit,
    /** The text the agent is about to get; `before_agent_start` sees it as the prompt. */
    setPrompt(text) {
      prompt = String(text ?? "");
    },
  };
}
