/* ---------- messages between agents and vendors ----------
   One thread per vendor on a project, labeled with the property address. The agent's side is the agent and
   anyone the project is shared with. Closing partners aren't part of messaging. Ashleigh can read every thread
   but doesn't post. Every message sends a push notification right away; email follows only if it's still unread
   after 15 minutes (the database does that). */
const myEmail=()=>String((S.me&&S.me.email)||"").toLowerCase();
const msgOn=()=>Array.isArray(D.message_threads);
const msgSort=(a,b)=>String(a.created_at).localeCompare(String(b.created_at));
function msgThreads(){if(!msgOn())return[];const k=kind(),me=roleVal();
  return D.message_threads.map(t=>({...t,p:projById(t.project_id),v:vendorById(t.vendor_id),msgs:(D.messages||[]).filter(m=>m.thread_id===t.id).sort(msgSort)}))
    .filter(t=>t.p&&t.v&&t.msgs.length&&(k==="orbyt"||(k==="agent"&&isOnProject(t.p,me))||(k==="vendor"&&t.vendor_id===me)))
    .sort((a,b)=>String(b.last_message_at||"").localeCompare(String(a.last_message_at||"")))}
const readAt=t=>((D.message_reads||[]).find(r=>r.thread_id===t.id&&r.email===myEmail())||{}).last_read_at||"";
const unreadOf=t=>kind()==="orbyt"?0:t.msgs.filter(m=>String(m.sender_email||"").toLowerCase()!==myEmail()&&(!readAt(t)||m.created_at>readAt(t))).length;
const unreadThreads=()=>msgThreads().filter(t=>unreadOf(t)>0);
const unreadTotal=()=>unreadThreads().reduce((s,t)=>s+unreadOf(t),0);
// the other side of a thread, as this person sees it
const otherSide=t=>kind()==="vendor"?t.p.agent:kind()==="orbyt"?`${t.v.name} and ${t.p.agent}`:t.v.name;
const threadServices=t=>[...new Set(S.bids.filter(b=>b.projectId===t.project_id&&b.vendorId===t.vendor_id).map(b=>b.category))].join(", ");
// contact details between agents and vendors show once the vendor is booked
function bookedWithMe(vid){if(kind()==="orbyt")return true;const me=roleVal();
  return S.bids.some(b=>b.vendorId===vid&&b.status==="selected"&&projById(b.projectId)&&isOnProject(projById(b.projectId),me))}
const sharedProjects=vid=>{const me=roleVal();return[...new Set(S.bids.filter(b=>b.vendorId===vid&&projById(b.projectId)&&isOnProject(projById(b.projectId),me)).map(b=>b.projectId))].map(projById)};
function msgBtn(pid,vid,label,cls){if(!msgOn()||!pid||!vid)return"";const v=vendorById(vid);if(v&&typeof isPartner==="function"&&isPartner(v))return"";
  const t=msgThreads().find(x=>x.project_id===pid&&x.vendor_id===vid),n=t?unreadOf(t):0;
  return `<button class="${cls||"linkbtn"}" type="button" data-act="msgopen" data-p="${esc(pid)}" data-v="${esc(vid)}">${esc(label||"Message")}${n?` <span class="count">${n}</span>`:""}</button>`}
// for the agent: the vendor's contact details once booked, otherwise a way to message them
function vendorContactGate(v){if(kind()!=="agent"||bookedWithMe(v.id)||(typeof isPartner==="function"&&isPartner(v)))return null;
  const ps=sharedProjects(v.id);
  return `<p class="small" style="margin:0">Contact details show once you book ${esc(v.name)}. Until then, message them here so everything about the job stays in one place.</p>${ps.length?`<div class="actions" style="margin-top:8px">${ps.map(p=>msgBtn(p.id,v.id,ps.length>1?"Message about "+p.address:"Message "+v.name,"btn sm")).join("")}</div>`:""}`}

/* the Messages tab */
function threadRow(t,open){const last=t.msgs[t.msgs.length-1]||{},n=unreadOf(t);
  return `<button class="mthread ${open?"on":""} ${n?"unread":""}" type="button" data-act="msgopen" data-p="${esc(t.project_id)}" data-v="${esc(t.vendor_id)}">
    <span class="mtop"><span class="maddr">${esc(t.p.address)}</span><span class="small num">${last.created_at?ago(last.created_at):""}</span></span>
    <span class="small mwho">${esc(otherSide(t))}${threadServices(t)?" · "+esc(threadServices(t)):""}</span>
    <span class="small msnip">${n?`<span class="count">${n}</span> `:""}${esc((last.sender_name?last.sender_name+": ":"")+String(last.body||"").slice(0,110))}</span></button>`}
function messagesView(){
  if(!msgOn())return `<div class="emptystate"><h2>Messages are almost ready</h2><p>Messaging turns on once Orbyt finishes setting it up.</p></div>`;
  msgLive();
  const ts=msgThreads(),key=S.openMsg,cur=key?ts.find(t=>t.project_id===key.p&&t.vendor_id===key.v):null;
  const draftP=key&&!cur?projById(key.p):null,draftV=key&&!cur?vendorById(key.v):null;
  const admin=kind()==="orbyt";
  const list=ts.length?ts.map(t=>threadRow(t,cur&&cur.id===t.id)).join(""):`<p class="small" style="padding:12px">${admin?"No messages yet.":kind()==="agent"?"No messages yet. Use Message next to any vendor on your projects.":"No messages yet. Use Message the agent on any request."}</p>`;
  let pane="";
  if(cur||(draftP&&draftV)){const p=cur?cur.p:draftP,v=cur?cur.v:draftV,msgs=cur?cur.msgs:[];
    const t=cur||{project_id:p.id,vendor_id:v.id,p,v,msgs:[]};
    if(cur&&unreadOf(cur)&&S.canWrite)msgMarkRead(cur);
    const mine=m=>String(m.sender_email||"").toLowerCase()===myEmail();
    pane=`<div class="mhead"><button class="linkbtn mback" type="button" data-act="msgback">All messages</button>
        <div class="eyebrow">${esc(threadServices(t)||"Messages")}</div><h2 style="margin:2px 0 0">${esc(p.address)}</h2>
        <div class="small">${esc(otherSide(t))}${!admin?` · <button class="linkbtn" type="button" data-act="${kind()==="vendor"?"msgproject":"open"}" data-id="${esc(p.id)}" data-v="${esc(v.id)}">Open ${kind()==="vendor"?"request":"project"}</button>`:""}</div></div>
      <div class="mlist" id="mlist">${msgs.length?msgs.map(m=>`<div class="mmsg ${admin?(m.sender_side==="vendor"?"":"mine"):mine(m)?"mine":""}"><div class="mbody">${esc(m.body).replace(/\n/g,"<br>")}</div><div class="mmeta">${esc(m.sender_name||"")} · ${esc(msgTime(m.created_at))}</div></div>`).join("")
        :`<p class="small" style="margin:auto;text-align:center">Start the conversation about ${esc(p.address)}.</p>`}</div>
      ${admin?`<p class="small mnote">You can read every thread. Agents and vendors don't get a notice when you do, and you don't get notified about their messages.</p>`
        :S.canWrite?`<form class="mform" data-form="msg" data-p="${esc(p.id)}" data-v="${esc(v.id)}"><textarea id="msg-body" name="body" aria-label="Message" rows="2" maxlength="4000" placeholder="Write a message">${esc(S.msgText[p.id+"|"+v.id]||"")}</textarea><button class="btn" type="submit">Send</button></form>
          <p class="small mnote">${kind()==="vendor"?esc(firstName(p.agent)):esc(v.name)} gets a notification right away. Ashleigh at Orbyt can read messages to help if anything comes up.</p>`:""}`}
  else pane=`<div class="mempty"><p class="small">${ts.length?"Pick a conversation.":admin?"Messages between agents and vendors show up here.":"Your conversations show up here, labeled by property."}</p></div>`;
  return `<section class="msgwrap ${cur||draftP?"open":""}"><div class="mside">${list}</div><div class="mpane">${pane}</div></section>`}
function msgTime(iso){const d=new Date(iso),today=new Date();
  return d.toDateString()===today.toDateString()?d.toLocaleTimeString("en-US",{hour:"numeric",minute:"2-digit"}):d.toLocaleDateString("en-US",{month:"short",day:"numeric"})+", "+d.toLocaleTimeString("en-US",{hour:"numeric",minute:"2-digit"})}
// a tile in the stats bar
const msgStat=()=>msgOn()&&kind()!=="orbyt"?[{key:"msgs",label:"Unread messages",list:unreadThreads(),render:l=>`<div class="mside inline">${l.map(t=>threadRow(t,false)).join("")}</div>`,empty:"You're all caught up."}]:[];

/* loading, reading and sending */
async function msgRefresh(){if(!S.uid)return;try{
  const[t,m,r]=await Promise.all([sb.from("message_threads").select("*"),sb.from("messages").select("*").order("created_at"),sb.from("message_reads").select("*")]);
  if(t.error||m.error)return;const before=(D.messages||[]).length;
  D.message_threads=t.data||[];D.messages=m.data||[];D.message_reads=r.data||[];
  const typing=document.activeElement&&document.activeElement.id==="msg-body";
  if(D.messages.length!==before||!typing){render();if(typing){const el=document.getElementById("msg-body");if(el){el.focus();el.setSelectionRange(el.value.length,el.value.length)}}}
  if(D.messages.length!==before)setTimeout(msgScroll,0)}catch(_){}}
let msgT=null;const msgRefreshSoon=()=>{clearTimeout(msgT);msgT=setTimeout(msgRefresh,400)};
function msgLive(){if(S.msgLive||!S.uid||!msgOn())return;S.msgLive=true;
  try{if(sb.channel)S.msgChan=sb.channel("orbyt-messages").on("postgres_changes",{event:"INSERT",schema:"public",table:"messages"},msgRefreshSoon).subscribe()}catch(_){}
  setInterval(()=>{if(document.visibilityState==="visible"&&S.uid)msgRefresh()},30000)}
// a push notification links straight to its thread
function msgPending(){if(!S.pendingThread||!msgOn())return;const t=D.message_threads.find(x=>x.id===S.pendingThread);S.pendingThread=null;
  if(t){S.openMsg={p:t.project_id,v:t.vendor_id};S.tab="messages";setTimeout(msgScroll,0)}}
function msgScroll(){const el=document.getElementById("mlist");if(el)el.scrollTop=el.scrollHeight}
const msgReadSent={};
function msgMarkRead(t){if(msgReadSent[t.id]===t.last_message_at)return;msgReadSent[t.id]=t.last_message_at;
  sb.rpc("message_read",{p_thread:t.id}).then(()=>{const rs=D.message_reads||(D.message_reads=[]),now=new Date().toISOString(),r=rs.find(x=>x.thread_id===t.id&&x.email===myEmail());
    if(r)r.last_read_at=now;else rs.push({thread_id:t.id,email:myEmail(),last_read_at:now});render()},()=>{})}
document.addEventListener("click",e=>{const t=e.target.closest('[data-act="msgopen"],[data-act="msgback"],[data-act="msgproject"]');if(!t)return;e.preventDefault();e.stopImmediatePropagation();
  if(t.dataset.act==="msgback"){S.openMsg=null;render();return}
  if(t.dataset.act==="msgproject"){const b=S.bids.find(x=>x.projectId===t.dataset.id&&x.vendorId===t.dataset.v);if(b){S.tab="projects";S.openRequest=b.id;S.openMsg=null;render();window.scrollTo({top:0})}return}
  S.openMsg={p:t.dataset.p,v:t.dataset.v};S.tab="messages";S.vendorCard=null;S.statFilter="";render();setTimeout(msgScroll,0);
  const box=document.querySelector(".msgwrap");if(box)box.scrollIntoView({block:"start"})},true);
document.addEventListener("input",e=>{if(e.target.id!=="msg-body")return;const f=e.target.closest("form");if(f)S.msgText[f.dataset.p+"|"+f.dataset.v]=e.target.value});
document.addEventListener("keydown",e=>{if(e.target.id==="msg-body"&&e.key==="Enter"&&(e.metaKey||e.ctrlKey)){e.preventDefault();e.target.closest("form").requestSubmit()}});
document.addEventListener("submit",e=>{const f=e.target.closest('form[data-form="msg"]');if(!f)return;e.preventDefault();e.stopImmediatePropagation();
  const ta=f.querySelector("textarea"),body=ta.value.trim(),btn=f.querySelector('button[type="submit"]');if(!body)return;
  btn.disabled=true;btn.textContent="Sending...";
  sb.rpc("message_send",{p_project:f.dataset.p,p_vendor:f.dataset.v,p_body:body}).then(({error})=>{
    if(error){btn.disabled=false;btn.textContent="Send";toast(error.message||"That didn't send. Try again.");return}
    S.msgText[f.dataset.p+"|"+f.dataset.v]="";msgRefresh().then(()=>{setTimeout(()=>{msgScroll();const el=document.getElementById("msg-body");if(el)el.focus()},0)})})},true);
S.msgText=S.msgText||{};
