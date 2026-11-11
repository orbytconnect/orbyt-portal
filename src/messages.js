/* ---------- messages ----------
   Job threads: one per vendor on a project, labeled with the property address, between the agent's side (the agent
   and anyone the project is shared with) and the vendor. Closing partners aren't part of these. Ashleigh can read
   them but doesn't post or get notified.
   Orbyt threads: every agent, vendor and closing partner has one conversation with Ashleigh, not tied to a property.
   Every message sends a push right away; email follows only if it's still unread after 15 minutes (the database
   does that). */
const myEmail=()=>String((S.me&&S.me.email)||"").toLowerCase();
const msgOn=()=>Array.isArray(D.message_threads);
const msgSort=(a,b)=>String(a.created_at).localeCompare(String(b.created_at));
function msgThreads(){if(!msgOn())return[];const k=kind(),me=roleVal();
  return D.message_threads.map(t=>({...t,p:t.project_id?projById(t.project_id):null,v:t.vendor_id?vendorById(t.vendor_id):null,msgs:(D.messages||[]).filter(m=>m.thread_id===t.id).sort(msgSort)}))
    .filter(t=>t.msgs.length&&(t.orbyt_user?(k==="orbyt"||t.orbyt_user===S.uid):t.p&&t.v&&(k==="orbyt"||(k==="agent"&&isOnProject(t.p,me))||(k==="vendor"&&t.vendor_id===me))))
    .sort((a,b)=>String(b.last_message_at||"").localeCompare(String(a.last_message_at||"")))}
const isOrbytThread=t=>!!t.orbyt_user;
// who someone is, for Ashleigh: their business (vendors and partners) or name, and their role
const personOf=uid=>(D.profiles||[]).find(p=>p.id===uid)||{};
function personLabel(uid){const pr=personOf(uid),v=S.vendors.find(x=>x.userId===uid);return v?v.name:(pr.full_name||pr.email||"Someone")}
function personRole(uid){const pr=personOf(uid),v=S.vendors.find(x=>x.userId===uid);
  return v?(typeof isPartner==="function"&&isPartner(v)?"Closing partner":"Vendor")+(pr.full_name?" · "+pr.full_name:""):pr.role==="agent"?"Agent"+(pr.brokerage?" · "+pr.brokerage:""):""}
const readAt=t=>((D.message_reads||[]).find(r=>r.thread_id===t.id&&r.email===myEmail())||{}).last_read_at||"";
const unreadOf=t=>kind()==="orbyt"&&!isOrbytThread(t)?0:t.msgs.filter(m=>String(m.sender_email||"").toLowerCase()!==myEmail()&&(!readAt(t)||m.created_at>readAt(t))).length;
const unreadThreads=()=>msgThreads().filter(t=>unreadOf(t)>0);
const unreadTotal=()=>unreadThreads().reduce((s,t)=>s+unreadOf(t),0);
// the other side of a thread, as this person sees it
const otherSide=t=>isOrbytThread(t)?(kind()==="orbyt"?personRole(t.orbyt_user):"Questions, help or feedback"):kind()==="vendor"?t.p.agent:kind()==="orbyt"?`${t.v.name} and ${t.p.agent}`:t.v.name;
const threadTitle=t=>isOrbytThread(t)?(kind()==="orbyt"?personLabel(t.orbyt_user):"Ashleigh at Orbyt"):t.p.address;
const threadAttrs=t=>isOrbytThread(t)?`data-o="${esc(t.orbyt_user)}"`:`data-p="${esc(t.project_id)}" data-v="${esc(t.vendor_id)}"`;
// a button to message Ashleigh, for anyone but her
const msgAshBtn=(label,cls)=>msgOn()&&kind()!=="orbyt"&&S.uid?`<button class="${cls||"btn ghost sm"}" type="button" data-act="msgopen" data-o="${esc(S.uid)}">${esc(label||"Message Ashleigh")}</button>`:"";
const threadServices=t=>isOrbytThread(t)?"":[...new Set(S.bids.filter(b=>b.projectId===t.project_id&&b.vendorId===t.vendor_id).map(b=>b.category))].join(", ");
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
  return `<button class="mthread ${open?"on":""} ${n?"unread":""} ${isOrbytThread(t)?"morbyt":""}" type="button" data-act="msgopen" ${threadAttrs(t)}>
    <span class="mtop"><span class="maddr">${esc(threadTitle(t))}</span><span class="small num">${last.created_at?ago(last.created_at):""}</span></span>
    <span class="small mwho">${esc(otherSide(t))}${threadServices(t)?" · "+esc(threadServices(t)):""}</span>
    <span class="small msnip">${n?`<span class="count">${n}</span> `:""}${last.body?esc((last.sender_name?last.sender_name+": ":"")+String(last.body).slice(0,110)):"Message me anytime"}</span></button>`}
function messagesView(){
  if(!msgOn())return `<div class="emptystate"><h2>Messages are almost ready</h2><p>Messaging turns on once Orbyt finishes setting it up.</p></div>`;
  msgLive();
  const admin=kind()==="orbyt",all=msgThreads(),key=S.openMsg||null;
  const mineO=!admin?(all.find(t=>isOrbytThread(t))||{orbyt_user:S.uid,msgs:[],draft:true}):null;
  const jobs=all.filter(t=>!isOrbytThread(t)),orbs=admin?all.filter(isOrbytThread):[];
  const match=t=>key&&(key.o?t.orbyt_user===key.o:t.project_id===key.p&&t.vendor_id===key.v);
  let cur=[...(mineO?[mineO]:[]),...orbs,...jobs].find(match)||null;
  if(!cur&&key&&key.o&&admin)cur={orbyt_user:key.o,msgs:[],draft:true};
  if(!cur&&key&&key.p){const p=projById(key.p),v=vendorById(key.v);if(p&&v)cur={project_id:p.id,vendor_id:v.id,p,v,msgs:[],draft:true}}
  const rows=l=>l.map(t=>threadRow(t,cur&&match(t)&&(cur.id?cur.id===t.id:true))).join("");
  const people=admin?(D.profiles||[]).filter(p=>p.id!==S.uid&&p.status==="active"&&p.role!=="admin").map(p=>({id:p.id,l:personLabel(p.id),r:personRole(p.id)})).sort((a,b)=>a.l.localeCompare(b.l)):[];
  const list=admin?`<div class="mgroup">Your conversations</div>
      ${S.canWrite?`<div class="mnew"><select id="msg-new" aria-label="Message someone"><option value="">Message someone...</option>${people.map(p=>`<option value="${esc(p.id)}">${esc(p.l)}${p.r?" · "+esc(p.r.split(" · ")[0]):""}</option>`).join("")}</select></div>`:""}
      ${orbs.length?rows(orbs):`<p class="small" style="padding:4px 14px 12px">No conversations yet.</p>`}
      <div class="mgroup">Agents and vendors <span class="small">(read only)</span></div>${jobs.length?rows(jobs):`<p class="small" style="padding:4px 14px 12px">No messages yet.</p>`}`
    :rows([mineO])+(jobs.length?rows(jobs):`<p class="small" style="padding:12px 14px">${kind()==="agent"?"Use Message next to any vendor on your projects to start a conversation about that home.":typeof isPartner==="function"&&isPartner(vendorById(roleVal())||{})?"":"Use Message the agent on any request to start a conversation about that home."}</p>`);
  let pane="";
  if(cur){const orb=isOrbytThread(cur),msgs=cur.msgs||[];
    if(cur.id&&unreadOf(cur)&&S.canWrite)msgMarkRead(cur);
    const mine=m=>admin?(orb?m.sender_side==="orbyt":m.sender_side!=="vendor"):String(m.sender_email||"").toLowerCase()===myEmail();
    const pr=orb&&admin?personOf(cur.orbyt_user):null,v=!orb?cur.v:null,p=!orb?cur.p:null;
    const sub=orb?(admin?esc([personRole(cur.orbyt_user),pr.email,pr.phone].filter(Boolean).join(" · ")):"Message me anytime about your account, a job, or anything that isn't working.")
      :`${esc(otherSide(cur))}${!admin?` · <button class="linkbtn" type="button" data-act="${kind()==="vendor"?"msgproject":"open"}" data-id="${esc(p.id)}" data-v="${esc(v.id)}">Open ${kind()==="vendor"?"request":"project"}</button>`:""}`;
    const canSend=S.canWrite&&(orb||!admin);
    const fkey=orb?"o|"+cur.orbyt_user:p.id+"|"+v.id,who=orb?(admin?firstName(personOf(cur.orbyt_user).full_name||personLabel(cur.orbyt_user)):"Ashleigh"):kind()==="vendor"?firstName(p.agent):v.name;
    pane=`<div class="mhead"><button class="linkbtn mback" type="button" data-act="msgback">All messages</button>
        <div class="eyebrow">${esc(orb?"Orbyt":threadServices(cur)||"Messages")}</div><h2 style="margin:2px 0 0">${esc(threadTitle(cur))}</h2><div class="small">${sub}</div></div>
      <div class="mlist" id="mlist">${msgs.length?msgs.map(m=>`<div class="mmsg ${mine(m)?"mine":""}"><div class="mbody">${esc(m.body).replace(/\n/g,"<br>")}</div><div class="mmeta">${esc(m.sender_name||"")} · ${esc(msgTime(m.created_at))}</div></div>`).join("")
        :`<p class="small" style="margin:auto;text-align:center">${orb?(admin?"Start a conversation.":"Questions, a bug, or feedback? Send me a message."):"Start the conversation about "+esc(p.address)+"."}</p>`}</div>
      ${canSend?`<form class="mform" data-form="msg" ${orb?`data-o="${esc(cur.orbyt_user)}"`:`data-p="${esc(p.id)}" data-v="${esc(v.id)}"`}><textarea id="msg-body" name="body" aria-label="Message" rows="2" maxlength="4000" placeholder="Write a message">${esc(S.msgText[fkey]||"")}</textarea><button class="btn" type="submit">Send</button></form>
          <p class="small mnote">${esc(who)} gets a notification right away.</p>`
        :admin?`<p class="small mnote">You can read every agent and vendor thread. They don't get a notice when you do, and you don't get notified about their messages.</p>`:""}`}
  else pane=`<div class="mempty"><p class="small">${all.length?"Pick a conversation.":admin?"Your conversations and agent and vendor threads show up here.":"Your conversations show up here."}</p></div>`;
  return `<section class="msgwrap ${cur?"open":""}"><div class="mside">${list}</div><div class="mpane">${pane}</div></section>`}
function msgTime(iso){const d=new Date(iso),today=new Date();
  return d.toDateString()===today.toDateString()?d.toLocaleTimeString("en-US",{hour:"numeric",minute:"2-digit"}):d.toLocaleDateString("en-US",{month:"short",day:"numeric"})+", "+d.toLocaleTimeString("en-US",{hour:"numeric",minute:"2-digit"})}
// a tile in the stats bar
// Ashleigh: unread messages to her show on her dashboard
function msgAlerts(){if(!msgOn()||kind()!=="orbyt")return[];
  return msgThreads().filter(t=>isOrbytThread(t)&&unreadOf(t)>0).map(t=>{const last=t.msgs[t.msgs.length-1];
    return{id:"msg-"+t.id+"-"+last.id,cls:"k-ink",label:"Message",title:`${personLabel(t.orbyt_user)}: ${String(last.body).slice(0,90)}`,meta:`${unreadOf(t)} unread · ${ago(last.created_at)}`,when:String(last.created_at).slice(0,10),act:{a:"msgthread",id:t.orbyt_user,label:"Reply"},auto:false}})}
document.addEventListener("click",e=>{const t=e.target.closest('[data-act="msgthread"]');if(!t)return;e.preventDefault();e.stopImmediatePropagation();
  S.openMsg={o:t.dataset.id};S.tab="messages";render();setTimeout(msgScroll,0)},true);
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
  if(t){S.openMsg=t.orbyt_user?{o:t.orbyt_user}:{p:t.project_id,v:t.vendor_id};S.tab="messages";setTimeout(msgScroll,0)}}
function msgScroll(){const el=document.getElementById("mlist");if(el)el.scrollTop=el.scrollHeight}
const msgReadSent={};
function msgMarkRead(t){if(msgReadSent[t.id]===t.last_message_at)return;msgReadSent[t.id]=t.last_message_at;
  sb.rpc("message_read",{p_thread:t.id}).then(()=>{const rs=D.message_reads||(D.message_reads=[]),now=new Date().toISOString(),r=rs.find(x=>x.thread_id===t.id&&x.email===myEmail());
    if(r)r.last_read_at=now;else rs.push({thread_id:t.id,email:myEmail(),last_read_at:now});render()},()=>{})}
document.addEventListener("click",e=>{const t=e.target.closest('[data-act="msgopen"],[data-act="msgback"],[data-act="msgproject"]');if(!t)return;e.preventDefault();e.stopImmediatePropagation();
  if(t.dataset.act==="msgback"){S.openMsg=null;render();return}
  if(t.dataset.act==="msgproject"){const b=S.bids.find(x=>x.projectId===t.dataset.id&&x.vendorId===t.dataset.v);if(b){S.tab="projects";S.openRequest=b.id;S.openMsg=null;render();window.scrollTo({top:0})}return}
  S.openMsg=t.dataset.o?{o:t.dataset.o}:{p:t.dataset.p,v:t.dataset.v};S.tab="messages";S.help=false;S.vendorCard=null;S.statFilter="";render();setTimeout(msgScroll,0);
  const box=document.querySelector(".msgwrap");if(box)box.scrollIntoView({block:"start"})},true);
const msgKey=f=>f.dataset.o?"o|"+f.dataset.o:f.dataset.p+"|"+f.dataset.v;
document.addEventListener("input",e=>{if(e.target.id!=="msg-body")return;const f=e.target.closest("form");if(f)S.msgText[msgKey(f)]=e.target.value});
document.addEventListener("change",e=>{if(e.target.id!=="msg-new"||!e.target.value)return;S.openMsg={o:e.target.value};render();setTimeout(()=>{const el=document.getElementById("msg-body");if(el)el.focus()},0)});
document.addEventListener("keydown",e=>{if(e.target.id==="msg-body"&&e.key==="Enter"&&(e.metaKey||e.ctrlKey)){e.preventDefault();e.target.closest("form").requestSubmit()}});
document.addEventListener("submit",e=>{const f=e.target.closest('form[data-form="msg"]');if(!f)return;e.preventDefault();e.stopImmediatePropagation();
  const ta=f.querySelector("textarea"),body=ta.value.trim(),btn=f.querySelector('button[type="submit"]');if(!body)return;
  btn.disabled=true;btn.textContent="Sending...";
  (f.dataset.o?sb.rpc("orbyt_message_send",{p_user:kind()==="orbyt"?f.dataset.o:null,p_body:body}):sb.rpc("message_send",{p_project:f.dataset.p,p_vendor:f.dataset.v,p_body:body})).then(({error})=>{
    if(error){btn.disabled=false;btn.textContent="Send";toast(error.message||"That didn't send. Try again.");return}
    S.msgText[msgKey(f)]="";msgRefresh().then(()=>{setTimeout(()=>{msgScroll();const el=document.getElementById("msg-body");if(el)el.focus()},0)})})},true);
S.msgText=S.msgText||{};
