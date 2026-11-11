
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
const appSteps=()=>isIOS()?(/CriOS/.test(navigator.userAgent)?`In Chrome, tap the Share icon at the right end of the address bar, then Add to Home Screen. Orbyt gets its own icon and opens full screen.`:/FxiOS|EdgiOS/.test(navigator.userAgent)?`Tap your browser's Share button, then Add to Home Screen. Orbyt gets its own icon and opens full screen.`:`In Safari, tap the Share button, then Add to Home Screen. Orbyt gets its own icon and opens full screen.`)
  :/android/i.test(navigator.userAgent)?`In Chrome, tap the menu (⋮), then Install app or Add to Home screen. Orbyt gets its own icon and opens full screen.`
  :isMacSafari()?`In Safari, choose File in the menu bar, then Add to Dock. Orbyt opens in its own window from your Dock.`
  :/Chrome|Edg\//.test(navigator.userAgent)?`In Chrome, click the install icon at the right end of the address bar. Or open the menu (⋮), then Cast, save, and share, then Install page as app.`
  :`Bookmark ${PORTAL_HOST} so it's one click away (Cmd+D on a Mac, Ctrl+D on Windows).`;
const isMacSafari=()=>/Macintosh/.test(navigator.userAgent)&&/Safari\//.test(navigator.userAgent)&&!/Chrome|Chromium|Edg\/|Firefox/.test(navigator.userAgent)&&!(navigator.maxTouchPoints>1);
// a dialog anyone can open from the header: this device's steps, a one-tap install where the browser allows it, and a code to open Orbyt on a phone
function appView(){const url="https://"+PORTAL_HOST;
  return `<div class="scrim" data-act="appclose"></div><div class="vcard appcard" role="dialog" aria-modal="true" aria-labelledby="ap-title">
    <div class="vchead"><div style="min-width:0"><div class="eyebrow">Orbyt on your phone</div><h2 id="ap-title" style="font-weight:500;margin-top:4px">Get the Orbyt app</h2></div><button class="xbtn" data-act="appclose" aria-label="Close">×</button></div>
    ${isStandalone()?`<p>You're already using the Orbyt app on this device.</p>`:`<p style="margin:8px 0 0">${esc(appSteps())}</p>${S.installEvt?`<p style="margin:10px 0 0"><button class="btn" type="button" data-act="installapp">Install the app</button></p>`:""}`}
    ${isPhone()?"":`<div class="appqr"><div class="appqrcode">${typeof qrSvg==="function"?qrSvg(url):""}</div><div><div class="strong">On your phone</div><p class="small" style="margin:4px 0 0">Scan this with your phone's camera to open Orbyt. On iPhone, tap the Share icon (at the bottom in Safari, or at the right end of the address bar in Chrome), then Add to Home Screen. On Android, tap the menu (⋮), then Install app.</p></div></div>`}
    <p class="small" style="margin:12px 0 0">No app store needed. The first time you open it, sign in once.</p></div>`}

function setupItems(){const r=setupRole(),a=(label,act,extra)=>`<button class="btn ghost sm" type="button" data-act="${act}" ${extra||""}>${label}</button>`;
  const done=id=>a("Done","setupdone",`data-id="${id}"`);
  const emails={vendor:"New bid requests, being picked for a job, and reminders",agent:"Introductions, new quotes, and updates on your projects",partner:"Your listing status and Orbyt event invitations"}[r];
  const common=[
    {id:"setup-help",label:"Read the how-to guide",hint:"Tap Help in the top right corner anytime for a step-by-step guide to using Orbyt, and how to reach me.",done:setupDone("setup-help"),act:a("Open Help","help")},
    {id:"setup-bookmark",label:isPhone()?"Add Orbyt to your home screen":"Keep Orbyt one click away",hint:S.installEvt?"Install the Orbyt app in one tap. It gets its own icon and opens full screen, like any other app.":appSteps(),
      done:setupDone("setup-bookmark")||isStandalone(),act:(S.installEvt?a("Install the app","installapp"):a("Show me how","getapp"))+" "+done("setup-bookmark")},
    ...(pushKey()&&S.pushState&&S.pushState!=="unsupported"?[{id:"setup-push",label:"Turn on notifications",hint:pushHint(),done:S.pushState==="on"||setupDone("setup-push"),act:pushButton()}]:[]),
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
    {id:"ov",label:"Add your business overview",hint:"One PDF about your company and what you offer. Agents can open it from your listing.",done:!!v.overviewPdf,act:a("Add it","gofold",'data-fold="port"')},
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
    partner:["When your listing goes live, and anything I need from you","Notices about your listing fee","Invitations to Orbyt networking and education events"],
    orbyt:["New agent, vendor and closing partner sign-ups","New projects and home team card requests","Quotes, picks, finished jobs and reviews to approve","Special offers paid, card payments declined, and listings canceled","Projects agents delete, and the daily summary of anything waiting"]}[r]||[];
  const body={
    agent:[
      sec("1. Start a project",p("Tap New project and add the address, what the home needs, and your timing. Buying side? Choose Buyer, and add closing needs like a lender or title to see local options from the closing partner directory.")),
      sec("2. Meet your vendors",p("I introduce vendors who fit the home, your timing and your area. You get an email and a task when they're introduced, and another when each quote comes in. Questions for a vendor? Tap Message next to their name. Each conversation is labeled with the property, and their phone and email show once you book them.")),
      sec("3. Review quotes",p("Open the project to see each quote, its timeline, and the vendor's PDF. Ask a vendor for changes, ask me for another option, or tap Send quotes to client to share a private page with your client.")),
      sec("4. Pick and book",p("Tap Add to team on the one you want. The vendor confirms and reaches out to schedule, and your client pays them directly. When the job's done, confirm the final amount and leave a quick review. If you like, tell the others why you went another way. It helps them improve.")),
      sec("5. Build your bench",p("Save vendors you like to Favorites, add your assistant or team to Always share with, and make a home team card for your buyers so they come back to you when they need someone.")),
      sec("6. Grow the network",p("Know an agent or a vendor who'd be a good fit? Use Refer someone to Orbyt on your dashboard. It sends a ready-made message with your link."))],
    vendor:[
      sec("1. Set up your profile",p("Add your business overview PDF, your portfolio, and your insurance certificate under Your profile. Invite agents you've worked with to review you.")),
      sec("2. Answer bid requests",p("New requests come by email and show at the top of your dashboard. Open one, add your price and timeline, and upload your quote as a PDF or a photo. Can't take it? Let me know with one tap, so I can line up someone else. Questions for the agent? Tap Message on the request. Conversations are in the Messages tab, labeled with the property, and the agent's phone and email show once you're booked.")),
      sec("3. When you're picked",p("Confirm the job and propose a start date, then reach out to the agent to schedule. Share your agreement and payment details with the client directly. You run the job your way.")),
      sec("4. When the job's done",p("Mark it complete with your final invoice amount. The agent confirms it, and Orbyt's fee is based on that amount, as set out in your terms.")),
      sec("5. Reviews and feedback",p("Every job earns an agent review, and you can copy any review for your own marketing. When an agent goes another way, they can tell you why, so you can see what's winning work.")),
      sec("6. Your availability",p("Use the Taking new work switch at the top of your dashboard. While you're Paused, I won't send new requests."))],
    partner:[
      sec("1. Your listing",p("Agents in the network can browse the closing partner directory and see your listing on their buyer projects. It's an open directory: partners show in a rotating order, and agents and their clients choose who to contact.")),
      sec("2. Make it stand out",p("Add your business overview PDF and invite agents you've worked with to review you. Both show on your listing.")),
      sec("3. Spotlights and events",p("Your listing includes rotating spotlights in Orbyt's emails and posts to agents, and invitations to Orbyt networking and education events.")),
      sec("4. Showing or hidden",p("Use the Show my listing switch at the top of your dashboard to hide your listing for a while.")),
      sec("5. Your fee",p(`Your first 90 days are free with our launch offer, then it's $20 a month for your marketing listing. ${typeof billingOn==="function"&&billingOn()?"Your card is charged automatically. Use Manage billing on your dashboard to update your card, see receipts, or cancel.":`Cancel anytime by emailing ${HELP_EMAIL}.`} Your agreement has the details.`))],
    orbyt:[
      sec("1. Your dashboard",p("Everything waiting on you lands here: sign-ups to review, projects to match, quotes and picks to follow up on, and fees due. Use Nudge to send a ready-made reminder, or check an item off when it's handled.")),
      sec("2. Match projects",p("Open a project in Projects or Pipeline. For each service, pick the vendors to introduce. They get the bid request, and the agent sees each quote as it comes in. Open a vendor's name to see their PDF, portfolio and reviews while you match.")),
      sec("3. Vendors and reviews",p("Review new vendor sign-ups in Vendors and reviews: check their insurance and references, then approve. Approve agent reviews before they show, and manage special offers from a vendor's card.")),
      sec("4. Closing partners",p("Lenders, title, escrow and insurance providers have their own tab. Check each license, then approve every licensed provider, since the directory is open to all. Agents browse listed partners themselves, and Orbyt doesn't pick or introduce them. The Card payments panel at the top shows your Stripe setup.")),
      sec("5. Invoicing",p("Orbyt's fees on finished jobs show here once the agent confirms the final amount. Mark each one invoiced, paid or waived. Closing partner marketing fees and special offer fees have their own sections. Card payments record themselves.")),
      sec("6. Reports",p("Revenue by period, split into job fees, closing partner marketing fees and special offer fees, plus projects, agents and vendors over time. The Investor view has the same numbers in a shareable format.")),
      sec("7. Updates and setup",p("Setup steps, SQL updates and what each email means are in your Orbyt runbook in Google Drive. Never paste a secret key into a chat; keys go only into Supabase or Netlify."))]}[r]||[];
  return `<div class="scrim" data-act="helpclose"></div><div class="vcard wide helpcard" role="dialog" aria-modal="true" aria-labelledby="hp-title">
    <div class="vchead"><div style="min-width:0"><div class="eyebrow">Help</div><h2 id="hp-title" style="font-weight:500;margin-top:4px">${r==="orbyt"?"Running Orbyt":"How Orbyt works"}</h2></div><button class="xbtn" data-act="helpclose" aria-label="Close">×</button></div>
    <div class="helpbody">${S.canWrite&&setupItems().length?`<p style="margin:0"><button class="btn ghost sm" type="button" data-act="setupshow">Show my setup checklist</button></p>`:""}${body.join("")}
      ${pushKey()&&S.pushState&&S.pushState!=="unsupported"?sec("Notifications",`<p>${esc(pushHint())}</p>${pushButton()?`<p style="margin-top:8px">${pushButton()}</p>`:""}<p class="small" style="margin-top:6px">You get a notification for the same things Orbyt emails you about. Turn them on separately on each phone or computer you use.</p>`):""}
      ${sec(r==="orbyt"?"Emails you'll get":"Emails to expect",`<p>Orbyt emails come from <span class="strong">${HELP_EMAIL}</span>. Add it to your contacts so nothing lands in spam.</p><ul>${emails.map(x=>`<li>${esc(x)}</li>`).join("")}</ul>`)}
      ${sec("Get the Orbyt app",`<p>Orbyt works like an app on your phone, with no app store needed. ${esc(appSteps())}</p><p style="margin-top:8px"><button class="btn sm" type="button" data-act="getapp">Get the app</button></p><p class="small" style="margin-top:6px">The first time you open it from your home screen, sign in once. Links in Orbyt emails open in your browser.</p>`)}
      ${r==="orbyt"?"":`<div class="callout" style="margin-top:6px"><div class="strong">Need help or found a bug?</div><p class="small" style="margin:4px 0 0">${contactLine()}</p>${typeof msgAshBtn==="function"&&msgOn()?`<div class="actions" style="margin-top:8px">${msgAshBtn("Message Ashleigh","btn sm")}</div>`:""}</div>`}</div></div>`}

document.addEventListener("click",e=>{const t=e.target.closest('[data-act="getapp"],[data-act="appclose"],[data-act="installapp"],[data-act="setupdone"],[data-act="setupshow"],[data-act="help"],[data-act="helpclose"],[data-act="gofold"],[data-act="setupref"]');if(!t)return;
  e.preventDefault();e.stopImmediatePropagation();const a=t.dataset.act;
  if(a==="getapp"){S.appInfo=true;S.help=false;render();return}
  if(a==="appclose"){S.appInfo=false;render();return}
  if(a==="installapp"){const ev=S.installEvt;if(!ev){toast("Use your browser's menu to install Orbyt.");return}
    ev.prompt();ev.userChoice.then(c=>{S.installEvt=null;if(c&&c.outcome==="accepted")setupMark("setup-bookmark").then(()=>render()).catch(()=>{});else render()}).catch(()=>{});return}
  if(a==="help"){S.help=true;render();if(kind()!=="orbyt"&&S.canWrite&&!setupDone("setup-help"))setupMark("setup-help").catch(()=>{});return}
  if(a==="helpclose"){S.help=false;render();return}
  if(a==="setupdone"){if(t.dataset.id==="setup-hide")S.setupOpen=false;guard(()=>setupMark(t.dataset.id),t.dataset.id==="setup-hide"?"Hidden. Bring it back anytime with Show the checklist, or from Help.":"Checked off");return}
  if(a==="setupshow"){S.help=false;S.setupOpen=true;guard(()=>setupUnmark("setup-hide"));setTimeout(()=>document.querySelector(".setup,.setupback")?.scrollIntoView({behavior:"smooth",block:"center"}),300);return}
  const openFold=k=>{const d=document.querySelector(`details.fold[data-fold="${k}"]`);if(d){d.open=true;d.scrollIntoView({behavior:"smooth",block:"start"});return true}return false};
  if(a==="gofold"){if(!openFold(t.dataset.fold))toast("You'll find it under Your profile once you're approved.");return}
  if(a==="setupref"){S.refWho=t.dataset.who;render();setTimeout(()=>openFold("refer"),30)}},true);
// sending a referral (copy, email or text) checks off the matching step
document.addEventListener("click",e=>{const t=e.target.closest('.refcard [data-act="refcopy"], .refcard a.btn');if(!t||kind()!=="agent")return;
  const id="setup-ref-"+(S.refWho||"agent");if(!setupDone(id))setTimeout(()=>{setupMark(id).then(()=>render()).catch(()=>{})},400)},false);
document.addEventListener("keydown",e=>{if(e.key==="Escape"&&(S.help||S.appInfo)){S.help=false;S.appInfo=false;render()}});

/* ---------- push notifications: alerts on phones and computers ---------- */
const pushKey=()=>{try{return((typeof settingVal==="function"?settingVal("push"):null)||{}).public_key||""}catch(_){return""}};
const pushSupported=()=>"serviceWorker" in navigator&&"PushManager" in window&&"Notification" in window;
const b64uToBytes=s=>{const p="=".repeat((4-s.length%4)%4),b=atob((s+p).replace(/-/g,"+").replace(/_/g,"/"));return Uint8Array.from(b,c=>c.charCodeAt(0))};
const bytesToB64u=a=>btoa(String.fromCharCode(...a)).replace(/\+/g,"-").replace(/\//g,"_").replace(/=+$/,"");
// on (this device gets alerts), off, blocked (the browser said no), needs-app (iPhone: add to home screen first), unsupported
async function pushCheck(){let st;
  try{if(!pushSupported())st=isIOS()&&!isStandalone()?"needs-app":"unsupported";
    else if(Notification.permission==="denied")st="blocked";
    else{const reg=await navigator.serviceWorker.getRegistration();const sub=reg&&await reg.pushManager.getSubscription();st=sub?"on":"off"}}catch(_){st="unsupported"}
  if(st!==S.pushState){S.pushState=st;if(S.session)render()}}
async function pushOn(){const key=pushKey();if(!key)throw{message:"Notifications aren't switched on for Orbyt yet. Check back soon."};
  const perm=await Notification.requestPermission();
  if(perm!=="granted"){S.pushState=perm==="denied"?"blocked":"off";throw{message:perm==="denied"?"Notifications are blocked for Orbyt. Allow them in your browser or phone settings, then try again.":"No problem. You can turn them on anytime."}}
  const reg=await navigator.serviceWorker.ready;let sub=await reg.pushManager.getSubscription();
  if(sub&&sub.options&&sub.options.applicationServerKey&&bytesToB64u(new Uint8Array(sub.options.applicationServerKey))!==key){await sub.unsubscribe();sub=null}
  if(!sub)sub=await reg.pushManager.subscribe({userVisibleOnly:true,applicationServerKey:b64uToBytes(key)});
  const j=sub.toJSON();
  fail((await sb.from("push_subscriptions").upsert({user_id:S.uid,endpoint:j.endpoint,p256dh:j.keys.p256dh,auth:j.keys.auth,user_agent:navigator.userAgent.slice(0,200)},{onConflict:"endpoint"})).error,"notifications");
  S.pushState="on";if(typeof setupMark==="function")try{await setupMark("setup-push")}catch(_){}}
async function pushOff(){const reg=await navigator.serviceWorker.getRegistration();const sub=reg&&await reg.pushManager.getSubscription();
  if(sub){const ep=sub.endpoint;await sub.unsubscribe();await sb.from("push_subscriptions").delete().eq("endpoint",ep)}S.pushState="off"}
// Ashleigh, once: make the signing key pair in this browser; the private half goes straight to Supabase's Vault
async function pushSetup(){const kp=await crypto.subtle.generateKey({name:"ECDSA",namedCurve:"P-256"},true,["sign","verify"]);
  const pub=new Uint8Array(await crypto.subtle.exportKey("raw",kp.publicKey)),jwk=await crypto.subtle.exportKey("jwk",kp.privateKey);
  const{error}=await sb.rpc("push_setup",{p_public:bytesToB64u(pub),p_private:jwk.d});
  if(error){console.error(error);throw{message:/function|does not exist|schema cache/i.test(error.message||"")?"Run update 18 in Supabase first, then try again.":"That didn't save. Try again in a minute."}}
  await S.db.reload()}
function pushHint(){return({
  off:"Get an alert on this device when something needs you, like a new bid request, a quote, or an introduction.",
  blocked:"Notifications are blocked for Orbyt on this device. Allow them in your browser or phone settings, then come back and turn them on.",
  "needs-app":"On iPhone, notifications work in the Orbyt app. Add Orbyt to your home screen first, then open it from there and turn them on.",
  on:"This device gets an alert whenever Orbyt emails you."})[S.pushState]||""}
function pushButton(){return S.pushState==="off"?`<button class="btn ghost sm" type="button" data-act="pushon">Turn on</button>`
  :S.pushState==="needs-app"?`<button class="btn ghost sm" type="button" data-act="getapp">Show me how</button>`
  :S.pushState==="on"?`<button class="linkbtn" type="button" data-act="pushoff">Turn off on this device</button>`:""}
// Ashleigh's dashboard: set up once, then turn on per device
function adminPushCard(){if(!S.canWrite)return"";const key=pushKey();
  if(!key)return `<div class="callout pushcard" style="margin-bottom:18px"><div><span class="strong">Push notifications aren't set up yet.</span><div class="small">One click creates Orbyt's notification key and keeps it in Supabase. Then you, agents and vendors can turn on alerts. Run update 18 first.</div></div><button class="btn sm" type="button" data-act="pushsetup">Set up push notifications</button></div>`;
  if(S.pushState==="on"||S.pushState==="unsupported"||!S.pushState||setupDone("setup-push-dismiss"))return"";
  return `<div class="callout pushcard" style="margin-bottom:18px"><div><span class="strong">Get alerts on this device</span><div class="small">${esc(S.pushState==="off"?"New projects, sign-ups, special offer requests and anything else Orbyt emails you, as a notification here.":pushHint())}</div></div><div class="actions">${pushButton()}<button class="linkbtn" type="button" data-act="setupdone" data-id="setup-push-dismiss">Not now</button></div></div>`}
document.addEventListener("click",e=>{const t=e.target.closest('[data-act="pushon"],[data-act="pushoff"],[data-act="pushsetup"]');if(!t)return;e.preventDefault();e.stopImmediatePropagation();const a=t.dataset.act;
  if(a==="pushon")guard(pushOn,"Notifications are on for this device.");
  else if(a==="pushoff")guard(pushOff,"Notifications are off for this device.");
  else guard(async()=>{await pushSetup();await pushCheck()},"Push notifications are set up. Turn them on for this device next.")},true);
if(typeof window!=="undefined"){setTimeout(()=>{pushCheck()},800);document.addEventListener("visibilitychange",()=>{if(!document.hidden)pushCheck()})}
