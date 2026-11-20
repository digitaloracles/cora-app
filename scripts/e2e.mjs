#!/usr/bin/env node
// End-to-end check of the app against a real Cora server: pair from the panel, read agents, quotas and usage,
// follow live reasoning, render the views with that data, then revoke. Usage: node scripts/e2e.mjs <Cora.app> <cora checkout> <out dir>
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const [appPath, coraPath, outPath] = process.argv.slice(2).map((value) => resolve(value));
if (!appPath || !coraPath || !outPath) { console.error("usage: e2e.mjs <Cora.app> <cora checkout> <out dir>"); process.exit(2); }
mkdirSync(outPath, { recursive: true });
const binary = join(appPath, "Contents/MacOS/Cora");
const home = mkdtempSync(join(tmpdir(), "cora-app-e2e-"));
const log = [];
const note = (line) => { log.push(line); console.log(line); };

function app(args, { timeout = 60000 } = {}) {
  return new Promise((resolveRun) => {
    const child = spawn(binary, args, { env: { ...process.env, CORA_APP_HOME: home } });
    let stdout = "", stderr = "";
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    const timer = setTimeout(() => child.kill("SIGKILL"), timeout);
    child.on("close", (code) => { clearTimeout(timer); resolveRun({ code, stdout, stderr }); });
  });
}

const { knowledgeWorld } = await import(pathToFileURL(join(coraPath, "test/knowledge-fixtures.js")).href);
const f = await knowledgeWorld();
try {
  const { store, traces, subscriptions } = f.app;
  const claude = store.createSubscription({ provider: "claude", label: "Claude Max", connectedBy: { id: f.alice.user.id, name: "alice" } });
  store.updateSubscription(claude.id, { status: "ready", email: "alice@claude.test", plan: "max" });
  store.setValue(`subscriptionUsage:${claude.id}`, { identity: subscriptions.usage.identity(store.subscription(claude.id)), state: "ready", fetchedAt: new Date().toISOString(), windows: [
    { id: "five_hour", kind: "session", group: "", usedPercent: 37, resetsAt: new Date(Date.now() + 2.2 * 3600000).toISOString(), minutes: null },
    { id: "seven_day", kind: "weekly", group: "", usedPercent: 84, resetsAt: new Date(Date.now() + 3.1 * 86400000).toISOString(), minutes: null },
  ], balances: [] });
  const buzz = store.createAgent({ name: "Buzz", brainOwnerId: f.alice.user.id, tools: false, enabled: true, model: "claude/claude-opus-5-5", subscriptionId: claude.id, color: "#f2a93b" });
  const ada = store.createAgent({ name: "Ada", brainOwnerId: f.alice.user.id, tools: false, enabled: true, model: "claude/claude-opus-5-5", subscriptionId: claude.id, color: "#4f9cf7" });
  const hidden = store.createAgent({ name: "Hidden", brainOwnerId: f.bob.user.id, tools: false, enabled: true });
  for (const [agent, tokens] of [[buzz, [42000, 6100]], [ada, [18000, 2500]], [hidden, [99999, 9]]]) {
    const done = traces.start({ agentId: agent.id, kind: "chat", channelId: `web-${agent.id}`, model: agent.model });
    done.add({ type: "thinking", text: agent === hidden ? "Bob's private reasoning" : `${agent.name} finished an earlier turn` });
    done.spent({ in: tokens[0], out: tokens[1] }); done.finish({ status: "ok", output: "done" });
  }

  // Plans across threads: one in progress, one blocked, a finished one, and another owner's that must stay out.
  const releasePlan = store.plans.create("800000000000000081", buzz.id, { name: "Plans in the apps", items: ["Server routes", "macOS page", "iOS list"] });
  const advanced = store.plans.change("800000000000000081", buzz.id, "advance", { ...releasePlan, step: 1 });
  const gate = store.plans.create("800000000000000082", ada.id, { name: "Gate the release", items: ["Wait for Phil"] });
  store.plans.change("800000000000000082", ada.id, "update", { ...gate, blocked_reason: "Phil has not tried it yet" });
  const finished = store.plans.create("800000000000000083", buzz.id, { name: "Ship version 0.2.11", items: ["Tag"] });
  store.plans.change("800000000000000083", buzz.id, "advance", { ...finished, step: 1 });
  store.plans.create("800000000000000084", hidden.id, { name: "Bob private plan", items: ["Hidden"] });

  // 1. The panel issues the link, as the button on notseb.usecora.space does for the signed-in person.
  const pairing = await f.request(f.alice, "/api/app/pairings", { method: "POST", body: {} });
  assert.equal(pairing.status, 201);
  note(`pairing link: ${pairing.data.link.replace(/code=[^&]+/, "code=…")}`);
  const connect = await app(["--connect", pairing.data.link]);
  note(`--connect → ${connect.code}: ${connect.stdout.trim()} ${connect.stderr.trim()}`);
  assert.equal(connect.code, 0);
  assert.match(connect.stdout, /Connected to 127\.0\.0\.1 as alice/);
  const devices = (await f.request(f.alice, "/api/app/devices")).data.devices;
  assert.equal(devices.length, 1);
  assert.equal((await app(["--connect", pairing.data.link])).code, 1, "the same link cannot connect twice");

  // 2. Agents, quotas and per-agent usage.
  const print = await app(["--print"]);
  writeFileSync(join(outPath, "print.txt"), print.stdout);
  note(print.stdout);
  assert.equal(print.code, 0, print.stderr);
  assert.match(print.stdout, /- Buzz \[idle\] claude\/claude-opus-5-5 today 48\.1k \(1 turns\)/);
  assert.match(print.stdout, /- Ada \[idle\] .* today 20\.5k/);
  assert.match(print.stdout, /- Claude alice@claude\.test max used by Buzz, Ada/);
  assert.match(print.stdout, /session: 63% left/);
  assert.match(print.stdout, /weekly: 16% left/);
  const agentLines = print.stdout.split("\n").filter((line) => /^- .+ \[\w+\] .* today /.test(line));
  assert.ok(agentLines.some((line) => line.startsWith("- Buzz ")) && agentLines.some((line) => line.startsWith("- Ada ")));
  assert.ok(!agentLines.some((line) => line.startsWith("- Hidden ") || / today 100k /.test(line)), "another owner's agent stays out");
  assert.ok(!print.stdout.includes("Hidden") && !print.stdout.includes("Bob's private reasoning"), "another owner's agent stays out");
  assert.match(print.stdout, /Plans: 2 in progress, 1 recently finished/);
  assert.match(print.stdout, /- \[active\] Plans in the apps · Buzz · .* · 1\/3\n    now: 2\. macOS page/);
  assert.match(print.stdout, /- \[blocked\] Gate the release · Ada · .* · 0\/1\n(    now: .*\n)?    blocked: Phil has not tried it yet/);
  assert.match(print.stdout, /- \[completed\] Ship version 0\.2\.11 · Buzz · .* · 1\/1/);
  assert.ok(!print.stdout.includes("Bob private plan"), "another owner's plan stays out");

  // 2b. A second space on the same Mac: both stay connected, each read with its own token, and one can leave alone.
  const other = await knowledgeWorld();
  try {
    other.app.store.createAgent({ name: "Nova", brainOwnerId: other.alice.user.id, tools: false, enabled: true });
    const second = await other.request(other.alice, "/api/app/pairings", { method: "POST", body: {} });
    assert.equal(second.status, 201);
    const otherServer = new URL(second.data.link).searchParams.get("server");
    assert.ok(otherServer && otherServer !== new URL(pairing.data.link).searchParams.get("server"), "two spaces, two addresses");
    assert.equal((await app(["--connect", second.data.link])).code, 0);
    const spaces = await app(["--spaces"]);
    note(`--spaces → ${spaces.stdout.trim()}`);
    assert.equal(spaces.stdout.trim().split("\n").length, 2, "the first space stays when a second one connects");
    const first = await app(["--print"]);
    assert.match(first.stdout, /- Buzz \[idle\]/);
    assert.ok(!first.stdout.includes("Nova"));
    const otherPrint = await app(["--print", otherServer]);
    note(`--print ${otherServer} → ${otherPrint.code}: ${otherPrint.stdout.split("\n").slice(0, 3).join(" | ")}`);
    assert.equal(otherPrint.code, 0, otherPrint.stderr);
    assert.match(otherPrint.stdout, /- Nova \[idle\]/);
    assert.ok(!otherPrint.stdout.includes("Buzz"), "each space shows only its own agents");
    assert.equal((await app(["--disconnect", otherServer])).code, 0);
    assert.equal((await other.request(other.alice, "/api/app/devices")).data.devices.length, 0, "leaving a space signs that Mac out there");
    assert.equal((await app(["--spaces"])).stdout.trim().split("\n").length, 1);
    assert.equal((await app(["--print"])).code, 0, "the first space is still connected");
  } finally {
    await other.close();
  }

  // 2c. An agent asks with answers to choose from: the app lists the question, a press answers it as the owner, and it leaves the list.
  if (f.app.orchestrator.choices) {
    await f.app.orchestrator.askOwner(store.agent(buzz.id), { question: "Install the new build now?", choices: ["Now", "Later"] }, { channelId: `web-${buzz.id}` });
    const asked = await app(["--print"]);
    assert.match(asked.stdout, /Questions: 1\n- (ch_[a-f0-9]{12}) Buzz · .*: Install the new build now\?\n    choices: 0=Now \| 1=Later/);
    const id = /- (ch_[a-f0-9]{12}) Buzz/.exec(asked.stdout)[1];
    const answered = await app(["--answer", id, "1"]);
    note(`--answer → ${answered.code}: ${answered.stdout.trim()} ${answered.stderr.trim()}`);
    assert.equal(answered.code, 0, answered.stderr);
    assert.match(answered.stdout, /Answered Buzz: Later/);
    const said = f.app.orchestrator.state(`web-${buzz.id}`).history.find((item) => item.kind === "owner" && item.choiceFor === buzz.id);
    assert.equal(said?.content, "Later", "the agent hears the answer pressed in the app");
    const again = await app(["--answer", id, "0"]);
    assert.equal(again.code, 1, "a question is answered once");
    assert.ok(!(await app(["--print"])).stdout.includes("Install the new build now?"), "answered, it leaves the app");
    await f.app.orchestrator.askOwner(store.agent(ada.id), { question: "The gate passed. Promote to production?", choices: ["Yes", "No"] }, { channelId: `web-${ada.id}` });
    note("questions: answered from the app, one left open for the screenshots");
  } else {
    note("questions: this Cora has no choices registry, skipped");
  }

  // 3. Live reasoning, step by step, while a turn runs.
  const live = traces.start({ agentId: buzz.id, kind: "chat", channelId: `web-${buzz.id}`, model: "claude/claude-opus-5-5" });
  live.goal = "Read the quotas and report what is left";
  const watching = app(["--watch", "8"], { timeout: 30000 });
  await new Promise((resolveWait) => setTimeout(resolveWait, 2500));
  const thoughts = ["Reading the Claude windows before I answer", "The weekly window is at 84%: I warn before starting the long job"];
  live.add({ type: "thinking", text: thoughts[0] });
  await new Promise((resolveWait) => setTimeout(resolveWait, 400));
  live.add({ type: "tool", name: "shell", args: { command: "node --test" }, result: "ok 3 tests" });
  const secret = traces.start({ agentId: hidden.id, kind: "chat", channelId: `web-${hidden.id}` });
  secret.add({ type: "thinking", text: "Bob's live secret" });
  await new Promise((resolveWait) => setTimeout(resolveWait, 400));
  live.add({ type: "thinking", text: thoughts[1] });
  live.spent({ in: 3200, out: 410 });
  store.plans.change("800000000000000081", buzz.id, "advance", { ...advanced, step: 2 });
  const watched = await watching;
  writeFileSync(join(outPath, "watch.txt"), watched.stdout);
  note(watched.stdout);
  assert.match(watched.stdout, /live: connected/);
  assert.match(watched.stdout, new RegExp(`step Buzz ${live.id} \\[thinking\\] ${thoughts[0]}`));
  assert.match(watched.stdout, new RegExp(`step Buzz ${live.id} \\[tool\\] shell`));
  assert.match(watched.stdout, new RegExp(`step Buzz ${live.id} \\[thinking\\] ${thoughts[1]}`));
  assert.ok(!watched.stdout.includes("Bob's live secret"), "another owner's live reasoning never reaches the app");
  assert.match(watched.stdout, new RegExp(`plan Buzz ${advanced.id} active 2/3`), "plan changes arrive live");

  const working = await app(["--print"]);
  assert.match(working.stdout, /- Buzz \[working\]/);
  assert.match(working.stdout, new RegExp(`live ${live.id} .*\\[thinking\\] ${thoughts[1]}`));
  const render = await app(["--render-live", join(outPath, "screens")], { timeout: 120000 });
  note(`--render-live → ${render.code}: ${render.stdout.trim()} ${render.stderr.trim()}`);
  assert.equal(render.code, 0);
  live.finish({ status: "ok", output: "16% of the weekly window left." }); secret.finish({ status: "ok" });

  // 4. Revoking the Mac from the panel stops it at once.
  assert.equal((await f.request(f.alice, `/api/app/devices/${devices[0].id}`, { method: "DELETE" })).status, 200);
  const revoked = await app(["--print"]);
  note(`--print after revoke → ${revoked.code}: ${revoked.stderr.trim()}`);
  assert.equal(revoked.code, 1);
  assert.match(revoked.stderr, /revocato|revoked/);
  note("E2E PASS");
} finally {
  writeFileSync(join(outPath, "e2e.log"), log.join("\n") + "\n");
  await app(["--disconnect"]).catch(() => {});
  await f.close();
}
