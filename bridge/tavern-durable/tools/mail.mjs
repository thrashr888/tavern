#!/usr/bin/env node
// mail: Gmail for a Pi agent, from its shell, without the agent ever handling the OAuth token.
//
//   mail search "<gmail query>" [--max 10]     one line per message: id, thread, date, from, subject
//   mail read <messageId>                      headers and plain-text body
//   mail thread <threadId>                     every message of a thread, oldest first
//   mail send --to <addr> --subject <s> [--cc <addr>] [--reply-to-message <messageId>] < body.txt
//
// Credentials are the gmail-mcp files: GMAIL_OAUTH_PATH (the OAuth client, `installed`) and
// GMAIL_CREDENTIALS_PATH ({ tokens: { access_token, refresh_token, expiry_date } }), by default
// in ~/.gmail-mcp. A refreshed access token is written back so the next call reuses it.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const DIR = path.join(os.homedir(), ".gmail-mcp");
const OAUTH_PATH = process.env.GMAIL_OAUTH_PATH ?? path.join(DIR, "gcp-oauth.keys.json");
const CREDENTIALS_PATH = process.env.GMAIL_CREDENTIALS_PATH ?? path.join(DIR, "credentials.json");
const API = "https://gmail.googleapis.com/gmail/v1/users/me";

async function accessToken() {
  const credentials = JSON.parse(fs.readFileSync(CREDENTIALS_PATH, "utf8"));
  const tokens = credentials.tokens ?? credentials;
  if (tokens.access_token && Date.now() < (tokens.expiry_date ?? 0) - 60_000) return tokens.access_token;
  const client = JSON.parse(fs.readFileSync(OAUTH_PATH, "utf8"));
  const { client_id, client_secret } = client.installed ?? client.web ?? client;
  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ client_id, client_secret, refresh_token: tokens.refresh_token, grant_type: "refresh_token" }),
  });
  if (!response.ok) fail(`token refresh failed (${response.status}); Paul needs to sign in again`);
  const fresh = await response.json();
  tokens.access_token = fresh.access_token;
  tokens.expiry_date = Date.now() + (fresh.expires_in ?? 3600) * 1000;
  fs.writeFileSync(CREDENTIALS_PATH, JSON.stringify(credentials.tokens ? { ...credentials, tokens } : tokens), { mode: 0o600 });
  return tokens.access_token;
}

async function gmail(pathAndQuery, init = {}) {
  const response = await fetch(`${API}${pathAndQuery}`, {
    ...init,
    headers: { authorization: `Bearer ${await accessToken()}`, ...(init.body ? { "content-type": "application/json" } : {}) },
  });
  if (!response.ok) fail(`Gmail ${response.status}: ${(await response.text()).slice(0, 300)}`);
  return response.json();
}

function header(message, name) {
  return message.payload?.headers?.find((h) => h.name.toLowerCase() === name.toLowerCase())?.value ?? "";
}

function decode(data) {
  return Buffer.from(String(data).replace(/-/g, "+").replace(/_/g, "/"), "base64").toString("utf8");
}

/** First text/plain part, else text/html with tags stripped. */
function body(part) {
  const find = (p, type) => {
    if (!p) return null;
    if (p.mimeType === type && p.body?.data) return decode(p.body.data);
    for (const child of p.parts ?? []) {
      const found = find(child, type);
      if (found) return found;
    }
    return null;
  };
  const plain = find(part, "text/plain");
  if (plain) return plain;
  const html = find(part, "text/html") ?? "";
  return html.slice(0, 200_000).replace(/<(style|script)[\s\S]*?<\/\1>/gi, "").replace(/<br\s*\/?>|<\/p>/gi, "\n").replace(/<[^>]+>/g, "")
    .replace(/&nbsp;/g, " ").replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/\n{3,}/g, "\n\n").trim();
}

function show(message) {
  return [
    `Message: ${message.id}  Thread: ${message.threadId}`,
    `Date: ${header(message, "Date")}`,
    `From: ${header(message, "From")}`,
    `To: ${header(message, "To")}`,
    header(message, "Cc") ? `Cc: ${header(message, "Cc")}` : null,
    `Subject: ${header(message, "Subject")}`,
    "",
    body(message.payload).trim(),
  ].filter((line) => line !== null).join("\n");
}

function flags(args) {
  const out = { _: [] };
  for (let i = 0; i < args.length; i++) {
    if (args[i].startsWith("--")) out[args[i].slice(2)] = args[++i];
    else out._.push(args[i]);
  }
  return out;
}

/** RFC 2047 for non-ASCII headers. */
function encodeHeader(text) {
  return /^[\x20-\x7e]*$/.test(text) ? text : `=?UTF-8?B?${Buffer.from(text).toString("base64")}?=`;
}

function fail(message) {
  process.stderr.write(`mail: ${message}\n`);
  process.exit(1);
}

const [command, ...rest] = process.argv.slice(2);
const args = flags(rest);
switch (command) {
  case "search": {
    const query = args._.join(" ");
    if (!query) fail('usage: mail search "<gmail query>" [--max 10]');
    const max = Math.min(Number(args.max ?? 10) || 10, 50);
    const list = await gmail(`/messages?q=${encodeURIComponent(query)}&maxResults=${max}`);
    const ids = (list.messages ?? []).map((m) => m.id);
    if (ids.length === 0) console.log("No messages.");
    for (const id of ids) {
      const m = await gmail(`/messages/${id}?format=metadata&metadataHeaders=Subject&metadataHeaders=From&metadataHeaders=Date`);
      console.log(`${m.id}  thread ${m.threadId}  ${header(m, "Date")}  ${header(m, "From")}  ${header(m, "Subject")}`);
    }
    break;
  }
  case "read": {
    if (!args._[0]) fail("usage: mail read <messageId>");
    console.log(show(await gmail(`/messages/${encodeURIComponent(args._[0])}?format=full`)));
    break;
  }
  case "thread": {
    if (!args._[0]) fail("usage: mail thread <threadId>");
    const thread = await gmail(`/threads/${encodeURIComponent(args._[0])}?format=full`);
    console.log((thread.messages ?? []).map(show).join("\n\n----\n\n"));
    break;
  }
  case "send": {
    if (!args.to || !args.subject) fail("usage: mail send --to <addr> --subject <s> [--cc <addr>] [--reply-to-message <id>] < body");
    if (/[\r\n]/.test(args.to + args.subject + (args.cc ?? ""))) fail("headers can't contain newlines");
    const text = fs.readFileSync(0, "utf8");
    if (!text.trim()) fail("the body (stdin) is empty");
    const headers = [`To: ${args.to}`, args.cc ? `Cc: ${args.cc}` : null, `Subject: ${encodeHeader(args.subject)}`];
    let threadId;
    if (args["reply-to-message"]) {
      const original = await gmail(`/messages/${encodeURIComponent(args["reply-to-message"])}?format=metadata&metadataHeaders=Message-ID&metadataHeaders=References`);
      const id = header(original, "Message-ID");
      threadId = original.threadId;
      if (id) headers.push(`In-Reply-To: ${id}`, `References: ${[header(original, "References"), id].filter(Boolean).join(" ")}`);
    }
    headers.push("MIME-Version: 1.0", "Content-Type: text/plain; charset=UTF-8", "Content-Transfer-Encoding: 8bit");
    const raw = Buffer.from(`${headers.filter(Boolean).join("\r\n")}\r\n\r\n${text}`).toString("base64url");
    const sent = await gmail("/messages/send", { method: "POST", body: JSON.stringify({ raw, ...(threadId ? { threadId } : {}) }) });
    console.log(`Sent ${sent.id} in thread ${sent.threadId}`);
    break;
  }
  default:
    fail("commands: search, read, thread, send (see the top of mail.mjs)");
}
