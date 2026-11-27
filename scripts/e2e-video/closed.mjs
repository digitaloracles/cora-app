// With the app quit: the space still answers on loopback, its agent replies to a new message,
// and launchd brings the server back when it dies. Run by the e2e workflow with the app's own Node.
import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { DatabaseSync } from "node:sqlite";

const root = `${process.env.HOME}/Library/Application Support/Cora/Local`;
const base = "http://127.0.0.1:4370";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const log = (line) => console.log(`[closed] ${line}`);
const fail = (line) => { console.log(`[closed] FAIL ${line}`); process.exit(1); };
const sh = (cmd, args) => { try { return execFileSync(cmd, args, { encoding: "utf8" }).trim(); } catch (e) { return (e.stdout || "").trim(); } };

const env = Object.fromEntries(readFileSync(`${root}/env`, "utf8").split("\n").map((l) => /^([A-Z0-9_]+)=(.*)$/.exec(l)).filter(Boolean)
  .map(([, k, v]) => [k, v.replace(/^'(.*)'$/s, "$1").replace(/'\\''/g, "'")]));

const running = sh("/usr/bin/pgrep", ["-x", "Cora"]);
if (running) fail(`the app is still running (pid ${running})`);
log("app quit: no Cora process");

const listen = sh("/usr/sbin/lsof", ["-nP", "-iTCP:4370", "-sTCP:LISTEN"]);
log(`listening:\n${listen}`);
if (!listen.includes("127.0.0.1:4370") || /\*:4370|0\.0\.0\.0:4370/.test(listen)) fail("not bound to 127.0.0.1 only");
const status = (await fetch(`${base}/`)).status;
log(`GET / -> ${status}`);
if (status !== 200) fail("the panel does not answer");

const login = await fetch(`${base}/api/login`, { method: "POST", headers: { "Content-Type": "application/json", "X-Cora": "1" }, body: JSON.stringify({ password: env.CORA_ADMIN_PASSWORD }) });
const cookie = (login.headers.get("set-cookie") || "").split(";")[0];
if (login.status !== 200 || !cookie) fail(`login ${login.status}`);
log("signed in to the panel with the space's password");

const db = new DatabaseSync(`${root}/home/cora.db`, { readOnly: true });
const agent = db.prepare("SELECT id, json_extract(data, '$.name') name FROM agents ORDER BY position LIMIT 1").get();
const room = `web-${agent.id}`;
const before = db.prepare("SELECT count(*) n FROM messages WHERE channel_id = ? AND kind = 'agent'").get(room).n;
const question = "La finestra di Cora è chiusa: rispondimi con una frase sola, che ora è per te?";
const sent = await fetch(`${base}/api/rooms/${room}/messages`, { method: "POST", headers: { "Content-Type": "application/json", "X-Cora": "1", Cookie: cookie }, body: JSON.stringify({ text: question }) });
if (sent.status >= 300) fail(`message ${sent.status}: ${await sent.text()}`);
log(`asked ${agent.name} with the app quit: ${question}`);
let reply;
for (let i = 0; i < 90 && !reply; i++) {
  await sleep(2000);
  reply = db.prepare("SELECT author_name a, content c FROM messages WHERE channel_id = ? AND kind = 'agent' ORDER BY at DESC LIMIT 1").get(room);
  if (db.prepare("SELECT count(*) n FROM messages WHERE channel_id = ? AND kind = 'agent'").get(room).n <= before) reply = undefined;
}
if (!reply) fail("no reply from the agent within 180 s");
log(`reply with the app quit: ${JSON.stringify(reply)}`);

const pidOf = () => sh("/usr/sbin/lsof", ["-t", "-nP", "-iTCP:4370", "-sTCP:LISTEN"]).split("\n")[0];
const first = pidOf();
process.kill(Number(first), "SIGKILL");
log(`server pid ${first} killed`);
let second = "";
for (let i = 0; i < 40; i++) {
  await sleep(1500);
  second = pidOf();
  if (second && second !== first) { try { if ((await fetch(`${base}/`)).status === 200) break; } catch {} }
}
if (!second || second === first) fail("launchd did not restart the server");
log(`launchd restarted the server: pid ${second}, GET / -> 200`);
log(sh("/bin/launchctl", ["print", `gui/${process.getuid()}/space.usecora.local`]).split("\n").filter((l) => /state =|runs =|last exit/.test(l)).join(" | "));
log("done");
