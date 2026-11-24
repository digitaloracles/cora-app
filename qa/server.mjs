import http from 'node:http';
import { execFileSync } from 'node:child_process';
import { knowledgeWorld } from '../cora/test/knowledge-fixtures.js';
const f = await knowledgeWorld();
const agent = f.app.store.createAgent({ name: "Planner", brainOwnerId: f.alice.user.id, tools: false, enabled: true });
const channel = "800000000000000081";
const plans = f.app.store.plans;
const plan = plans.create(channel, agent.id, {name:"Verifica chiusura",items:["Passo svolto","Passo aperto"]});
plans.change(channel, agent.id,"advance",{...plan,step:1});
http.createServer(async (req,res) => {
 try {
   if (req.url === '/pair' || req.url === '/open-ios') {
     const pairing = await f.request(f.alice, "/api/app/pairings", {method:"POST",body:{}});
     if (pairing.status !== 201) throw Error("pairing failed");
     if(req.url === '/open-ios') {
       execFileSync('xcrun',['simctl','openurl','booted',pairing.data.link], {stdio:'ignore'});
       res.end('ok');
     } else res.end(pairing.data.link);
   } else {
     const p = plans.recent({open:!!plans.open(channel,agent.id),limit:5}).find(p=>p.id===plan.id);
     res.end([p.status,p.done,p.items.length].join('/'));
   }
 } catch {res.writeHead(500);res.end('fixture failed');}
}).listen(19428,'127.0.0.1');
