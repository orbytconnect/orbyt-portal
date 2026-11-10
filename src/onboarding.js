
/* ---------- getting started: a checklist on each dashboard, and a Help page ---------- */
const HELP_EMAIL="ashleigh@orbytconnect.com";
const PORTAL_HOST="portal.orbytconnect.com";
const setupDone=id=>!!doneMap()[id];
function setupMark(id){const key=roleKey();if(!key||!S.canWrite)return Promise.resolve();
  return S.db.doc("taskstate/"+key).set({done:{...doneMap(),[id]:now()},nudged:nudgedMap()})}
const setupRole=()=>{const k=kind();if(k==="vendor"){const v=vendorById(roleVal());return isPartner(v)?"partner":"vendor"}return k};
const contactLine=()=>`Questions, or something not working? Email <a href="mailto:${HELP_EMAIL}?subject=${encodeURIComponent("Orbyt portal help")}">${HELP_EMAIL}</a>. A screenshot helps.`;
// the home screen app: installable from the browser, no app store needed
const isStandalone=()=>{try{return matchMedia("(display-mode: standalone)").matches||navigator.standalone===true}catch(_){return false}};
const isIOS=()=>/iphone|ipad|ipod/i.test(navigator.userAgent)||(navigator.platform==="MacIntel"&&navigator.maxTouchPoints>1);
const isPhone=()=>isIOS()||/android/i.test(navigator.userAgent);
if("serviceWorker" in navigator&&(location.protocol==="https:"||location.hostname==="localhost"))window.addEventListener("load",()=>navigator.serviceWorker.register("/sw.js").catch(()=>{}));
window.addEventListener("beforeinstallprompt",e=>{e.preventDefault();S.installEvt=e;if(S.session)render()});
window.addEventListener("appinstalled",()=>{S.installEvt=null;if(typeof setupMark==="function"&&S.session)setupMark("setup-bookmark").then(()=>render()).catch(()=>{})});
const appSteps=()=>isIOS()?`In Safari, tap the Share button, then Add to Home Screen. Orbyt gets its own icon and opens full screen.`
  :/android/i.test(navigator.userAgent)?`In Chrome, tap the menu (⋮), then Install app or Add to Home screen. Orbyt gets its own icon and opens full screen.`
  :`On a computer, bookmark ${PORTAL_HOST} (Cmd+D on a Mac, Ctrl+D on Windows), or use the install icon at the right of Chrome's address bar. On your phone, open ${PORTAL_HOST} and add it to your home screen.`;

function setupItems(){const r=setupRole(),a=(label,act,extra)=>`<button class="btn ghost sm" type="button" data-act="${act}" ${extra||""}>${label}</button>`;
  const done=id=>a("Done","setupdone",`data-id="${id}"`);
  const emails={vendor:"New bid requests, being picked for a job, and reminders",agent:"Introductions, new quotes, and updates on your projects",partner:"New introductions to agents"}[r];
  const common=[
    {id:"setup-bookmark",label:isPhone()?"Add Orbyt to your home screen":"Keep Orbyt one click away",hint:S.installEvt?"Install the Orbyt app in one tap. It gets its own icon and opens full screen, like any other app.":appSteps(),
      done:setupDone("setup-bookmark")||isStandalone(),act:S.installEvt?a("Install the app","installapp")+" "+done("setup-bookmark"):done("setup-bookmark")},
    {id:"setup-emails",label:"Watch for Orbyt emails",hint:`${emails} come by email from ${HELP_EMAIL}. Add it to your contacts so nothing lands in spam.`,done:setupDone("setup-emails"),act:a("Got it","setupdone",'data-id="setup-emails"')}];
  if(r==="agent"){const agent=roleVal(),ps=S.projects.filter(p=>isOnProject(p,agent));
    const refd=w=>setupDone("setup-ref-"+w);
    return[
      {id:"np",label:"Start your first project",hint:"Add the address, what the home needs, and your timing. I'll introduce vendors who fit.",done:ps.length>0,act:a("New project","newproject")},
      {id:"fav",label:"Save a vendor to your favorites",hint:"Open any vendor's card and tap Save to favorites. Favorites get matched to you first.",done:favIds(agent).length>0,act:a("Open Favorites","tab",'data-tab="favorites"')},
      {id:"card",label:"Make a home team card for a buyer",hint:"A printable card with your pros, and a code that sends their requests back to you.",done:!!(typeof hcSaved==="function"&&hcSaved()),act:a("Make the card","tab",'data-tab="card"')},
      {id:"team",label:"Add your assistant or team",hint:"Anyone in Always share with sees your projects and gets the emails.",done:defaultTeamOf(agent).length>0,act:a("Always share with","tab",'data-tab="team"')},
      {id:"setup-ref-agent",label:"Refer an agent",hint:"Know an agent who'd like this? Send them a ready-made message with your link.",done:refd("agent"),act:a("Refer an agent","setupref",'data-who="agent"')},
      {id:"setup-ref-vendor",label:"Refer a vendor you trust",hint:"Your favorite painter or cleaner can join with you as a reference.",done:refd("vendor"),act:a("Refer a vendor","setupref",'data-who="vendor"')},
      ...common]}
  const v=vendorById(roleVal());if(!v)return[];
  const rr=typeof rrFor==="function"?rrFor(v.id).length:0;
  if(r==="partner")return[
    {id:"ov",label:"Add your business overview",hint:"One PDF about your company and what you offer. Agents see it when I introduce you.",done:!!v.overviewPdf,act:a("Add it","gofold",'data-fold="port"')},
    {id:"rr",label:"Invite agents you've worked with to review you",hint:"Reviews from agents who know your work go a long way.",done:rr>0,act:a("Invite agents","gofold",'data-fold="rr"')},
    ...common];
  const ins=typeof insState==="function"?insState(v):null;
  return[
    {id:"ov",label:"Add your business overview",hint:"One PDF with your services and what sets you apart. Agents and their clients can open it next to your quotes.",done:!!v.overviewPdf,act:a("Add it","gofold",'data-fold="port"')},
    {id:"ins",label:"Add your insurance certificate",hint:"I need it before I can introduce you for some trades. It's checked in a few seconds.",done:!ins||!!ins.introsOk,act:a("Add it","gofold",'data-fold="ins"')},
    {id:"rr",label:"Invite 2 or 3 past agents to review you",hint:"Your profile has reviews before your first Orbyt job.",done:rr>0,act:a("Invite agents","gofold",'data-fold="rr"')},
    {id:"setup-avail",label:"Let me know you're taking new work",hint:"Use the Taking new work switch at the top of your dashboard. Switch to Paused anytime you're booked up.",done:setupDone("setup-avail")||v.available===false,act:a("I'm taking work","setupdone",'data-id="setup-avail"')},
    ...common]}

function setupUnmark(id){const key=roleKey();if(!key||!S.canWrite)return Promise.resolve();const dm={...doneMap()};delete dm[id];
  return S.db.doc("taskstate/"+key).set({done:dm,nudged:nudgedMap()})}
function setupCard(){if(!S.canWrite||!S.session)return"";
  const items=setupItems();if(!items.length)return"";const left=items.filter(x=>!x.done);
  // hidden, or all done: a one-line way back in
  if((setupDone("setup-hide")||!left.length)&&!S.setupOpen)return `<p class="small setupback">${left.length?`Setup checklist hidden, ${left.length} ${left.length===1?"step":"steps"} left.`:"You're all set up."} <button class="linkbtn" type="button" data-act="setupshow">Show the checklist</button> · <button class="linkbtn" type="button" data-act="help">How Orbyt works</button></p>`;
  const n=items.length-left.length;
  return `<section class="setup" aria-label="Get set up"><div class="setuphead"><div><div class="eyebrow">Get set up</div><h2>${!left.length?"All done. Nice work.":n?`${n} of ${items.length} done`:"A few quick steps to get the most out of Orbyt"}</h2></div>
      <div class="actions"><button class="linkbtn" type="button" data-act="help">How Orbyt works</button><button class="linkbtn" type="button" data-act="setupdone" data-id="setup-hide">Hide this</button></div></div>
    <div class="setupbar" role="progressbar" aria-valuemin="0" aria-valuemax="${items.length}" aria-valuenow="${n}"><span style="width:${Math.round(n/items.length*100)}%"></span></div>
    <ol class="setuplist">${items.map(x=>`<li class="${x.done?"done":""}"><span class="setupdot" aria-hidden="true">${x.done?"✓":""}</span><div class="setuptext"><span class="strong">${esc(x.label)}</span>${x.done?"":`<div class="small">${esc(x.hint)}</div>`}</div>${x.done?`<span class="small">Done</span>`:`<div>${x.act}</div>`}</li>`).join("")}</ol>
    <p class="small" style="margin:10px 0 0">${contactLine()}</p></section>`}

/* the Help page, written for each role */
function helpView(){const r=setupRole(),sec=(t,b)=>`<div class="helpsec"><h3>${t}</h3>${b}</div>`,p=x=>`<p>${x}</p>`;
  const emails={
    agent:["When I introduce vendors for your project","When a vendor sends or updates a quote","When a vendor confirms a job, can't take it, or marks it done","Daily reminders about anything waiting on you"],
    vendor:["New bid requests, with the details and the agent's timing","When an agent asks for changes to your quote","When you're picked, and reminders to confirm","Reminders about your insurance certificate and open requests"],
    partner:["New introductions, with the agent's contact details","Your approval, and anything I need from you"]}[r]||[];
  const body={
    agent:[
      sec("1. Start a project",p("Tap New project and add the address, what the home needs, and your timing. Buying side? Choose Buyer, and add closing partners like a lender or title if your client needs them.")),
      sec("2. Meet your vendors",p("I introduce vendors who fit the home, your timing and your area. You get an email and a task when they're introduced, and another when each quote comes in.")),
      sec("3. Review quotes",p("Open the project to see each quote, its timeline, and the vendor's PDF. Ask a vendor for changes, ask me for another option, or tap Send quotes to client to share a private page with your client.")),
      sec("4. Pick and book",p("Tap Add to team on the one you want. The vendor confirms and reaches out to schedule, and your client pays them directly. When the job's done, confirm the final amount and leave a quick review. If you like, tell the others why you went another way. It helps them improve.")),
      sec("5. Build your bench",p("Save vendors you like to Favorites, add your assistant or team to Always share with, and make a home team card for your buyers so they come back to you when they need someone.")),
      sec("6. Grow the network",p("Know an agent or a vendor who'd be a good fit? Use Refer someone to Orbyt on your dashboard. It sends a ready-made message with your link."))],
    vendor:[
      sec("1. Set up your profile",p("Add your business overview PDF, your portfolio, and your insurance certificate under Your profile. Invite agents you've worked with to review you.")),
      sec("2. Answer bid requests",p("New requests come by email and show at the top of your dashboard. Open one, add your price and timeline, and upload your quote as a PDF or a photo. Can't take it? Let me know with one tap, so I can line up someone else.")),
      sec("3. When you're picked",p("Confirm the job and propose a start date, then reach out to the agent to schedule. Share your agreement and payment details with the client directly. You run the job your way.")),
      sec("4. When the job's done",p("Mark it complete with your final invoice amount. The agent confirms it, and Orbyt's fee is based on that amount, as set out in your terms.")),
      sec("5. Reviews and feedback",p("Every job earns an agent review, and you can copy any review for your own marketing. When an agent goes another way, they can tell you why, so you can see what's winning work.")),
      sec("6. Your availability",p("Use the Taking new work switch at the top of your dashboard. While you're Paused, I won't send new requests."))],
    partner:[
      sec("1. Introductions",p("When an agent in the network needs what you do, I introduce you by email and on your dashboard. Reach out to the agent, then tap I've reached out.")),
      sec("2. Your profile",p("Add your business overview PDF and invite agents you've worked with to review you. Agents see both when I introduce you.")),
      sec("3. Your availability",p("Use the Taking new work switch at the top of your dashboard. While you're Paused, I won't send new introductions.")),
      sec("4. Free for founding partners",p("There's no fee to be a founding closing partner. Your terms explain how any future membership would work."))]}[r]||[];
  return `<div class="scrim" data-act="helpclose"></div><div class="vcard wide helpcard" role="dialog" aria-modal="true" aria-labelledby="hp-title">
    <div class="vchead"><div style="min-width:0"><div class="eyebrow">Help</div><h2 id="hp-title" style="font-weight:500;margin-top:4px">How Orbyt works</h2></div><button class="xbtn" data-act="helpclose" aria-label="Close">×</button></div>
    <div class="helpbody">${S.canWrite&&setupItems().length?`<p style="margin:0"><button class="btn ghost sm" type="button" data-act="setupshow">Show my setup checklist</button></p>`:""}${body.join("")}
      ${sec("Emails to expect",`<p>Orbyt emails come from <span class="strong">${HELP_EMAIL}</span>. Add it to your contacts so nothing lands in spam.</p><ul>${emails.map(x=>`<li>${esc(x)}</li>`).join("")}</ul>`)}
      ${sec("Get the Orbyt app",`<p>Orbyt works like an app on your phone, with no app store needed. ${esc(appSteps())}</p>${S.installEvt?`<p style="margin-top:8px"><button class="btn sm" type="button" data-act="installapp">Install the app</button></p>`:""}<p class="small" style="margin-top:6px">The first time you open it from your home screen, sign in once. Links in Orbyt emails open in your browser.</p>`)}
      <div class="callout" style="margin-top:6px"><div class="strong">Need help or found a bug?</div><p class="small" style="margin:4px 0 0">${contactLine()}</p></div></div></div>`}

document.addEventListener("click",e=>{const t=e.target.closest('[data-act="installapp"],[data-act="setupdone"],[data-act="setupshow"],[data-act="help"],[data-act="helpclose"],[data-act="gofold"],[data-act="setupref"]');if(!t)return;
  e.preventDefault();e.stopImmediatePropagation();const a=t.dataset.act;
  if(a==="installapp"){const ev=S.installEvt;if(!ev){toast("Use your browser's menu to install Orbyt.");return}
    ev.prompt();ev.userChoice.then(c=>{S.installEvt=null;if(c&&c.outcome==="accepted")setupMark("setup-bookmark").then(()=>render()).catch(()=>{});else render()}).catch(()=>{});return}
  if(a==="help"){S.help=true;render();return}
  if(a==="helpclose"){S.help=false;render();return}
  if(a==="setupdone"){if(t.dataset.id==="setup-hide")S.setupOpen=false;guard(()=>setupMark(t.dataset.id),t.dataset.id==="setup-hide"?"Hidden. Bring it back anytime with Show the checklist, or from Help.":"Checked off");return}
  if(a==="setupshow"){S.help=false;S.setupOpen=true;guard(()=>setupUnmark("setup-hide"));setTimeout(()=>document.querySelector(".setup,.setupback")?.scrollIntoView({behavior:"smooth",block:"center"}),300);return}
  const openFold=k=>{const d=document.querySelector(`details.fold[data-fold="${k}"]`);if(d){d.open=true;d.scrollIntoView({behavior:"smooth",block:"start"});return true}return false};
  if(a==="gofold"){if(!openFold(t.dataset.fold))toast("You'll find it under Your profile once you're approved.");return}
  if(a==="setupref"){S.refWho=t.dataset.who;render();setTimeout(()=>openFold("refer"),30)}},true);
// sending a referral (copy, email or text) checks off the matching step
document.addEventListener("click",e=>{const t=e.target.closest('.refcard [data-act="refcopy"], .refcard a.btn');if(!t||kind()!=="agent")return;
  const id="setup-ref-"+(S.refWho||"agent");if(!setupDone(id))setTimeout(()=>{setupMark(id).then(()=>render()).catch(()=>{})},400)},false);
document.addEventListener("keydown",e=>{if(e.key==="Escape"&&S.help){S.help=false;render()}});
