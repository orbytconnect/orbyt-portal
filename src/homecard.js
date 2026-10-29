
/* ---------- home team cards: a printable card agents give buyer clients, and the request page behind its QR code ---------- */
// services worth putting in front of buyers, in the order they come up after a move
const HC_ORDER=["Painting","Cleaning","Handyman","Landscaping","Moving","HVAC","Plumbing","Electric","General contractor / remodeling","Window treatments",
  "Landscape design","Pool services","Roofing","Flooring","Pest control","Home inspection","Pressure washing","Window cleaning","Junk removal","Gutter cleaning",
  "Carpet cleaning","Fencing","Concrete","Tree service","Organizing","Appliance repair","Garage doors","Drywall","Solar panel cleaning"];
const HC_SKIP=["Staging","Photography","Signage"];
const HC_ALSO_DEFAULT=["Window treatments","Landscape design","General contractor / remodeling","Electric","Plumbing","Pool services","Roofing","Flooring","Pest control","Home inspection","Pressure washing"];
const HC_LABEL={"General contractor / remodeling":"Remodeling","Electric":"Electrical"};
const hcLabel=c=>HC_LABEL[c]||c;
const HC_SPEC={"Painting":"Interiors, exteriors and cabinets","Cleaning":"Move-in deep cleans and windows","Handyman":"Small repairs, installs, punch lists",
  "Landscaping":"Yard refresh, planting, irrigation","Moving":"Local moves, packing, junk haul-away","HVAC":"Tune-ups, repairs and new systems",
  "Plumbing":"Leaks, fixtures and water heaters","Electric":"Fixtures, outlets, panels and EV chargers","General contractor / remodeling":"Kitchens, baths and bigger projects",
  "Window treatments":"Shades, shutters and drapery","Landscape design":"Plans for the yard you want","Pool services":"Weekly service and repairs",
  "Roofing":"Repairs, inspections and new roofs","Flooring":"Hardwood, tile and carpet","Pest control":"Inspections and ongoing service",
  "Home inspection":"Before you renovate or buy again","Pressure washing":"Driveways, patios and siding","Window cleaning":"Inside and out",
  "Junk removal":"Haul-away after the move","Carpet cleaning":"Deep cleans and stain removal","Tree service":"Trimming and removal",
  "Organizing":"Unpacking and closets","Garage doors":"Repairs and openers","Appliance repair":"Washers, fridges and ovens"};
const HC_INTRO="The local pros I trust, for whenever you need them.";
const HC_WHEN=["As soon as possible","In the next month","In 1 to 3 months","Just planning ahead"];

function hcServices(){const all=[...new Set([...HC_ORDER,...CATS,...MORE_SERVICES])].filter(c=>!HC_SKIP.includes(c));
  return all.sort((a,b)=>(HC_ORDER.indexOf(a)+1||99)-(HC_ORDER.indexOf(b)+1||99))}
function hcVendorsFor(c){const fav=favIds(roleVal());
  return S.vendors.filter(v=>v.approved!==false&&vsv(v).includes(c)).sort((a,b)=>(fav.includes(b.id)-fav.includes(a.id))||(((rating(b.id)||{}).avg||0)-((rating(a.id)||{}).avg||0))||a.name.localeCompare(b.name))}
const hcSaved=()=>Array.isArray(D.home_cards)?D.home_cards.find(x=>x.agent_id===S.uid):undefined;
const hcMe=()=>(D.profiles||[]).find(p=>p.id===S.uid)||{};
function hcDefaults(){
  const feat=[];for(const c of hcServices()){if(feat.length>=6)break;const vs=hcVendorsFor(c);if(vs.length)feat.push({c,v:vs[0].id,what:HC_SPEC[c]||""})}
  return{featured:feat,also:HC_ALSO_DEFAULT.filter(c=>!feat.some(f=>f.c===c)),intro:HC_INTRO,welcome:"Welcome home",priority:true,showPhone:true}}
function hcState(){
  if(!S.hc){const sv=hcSaved(),st=sv&&sv.settings&&typeof sv.settings==="object"?sv.settings:null,d=hcDefaults();
    S.hc=st?{...d,...st,featured:Array.isArray(st.featured)?st.featured:d.featured,also:Array.isArray(st.also)?st.also:d.also}:d}
  return S.hc}
const hcLogo=()=>S.hc&&S.hc.logo!==undefined?S.hc.logo:((hcSaved()||{}).logo||"");
const hcSlug=()=>{const sv=hcSaved();if(sv)return sv.slug;const f=String(hcMe().full_name||"").toLowerCase().replace(/[^a-z0-9]+/g,"-").replace(/^-|-$/g,"").split("-")[0];return f.length>1?f:"agent"};
const hcUrl=slug=>portalHome()+"r/"+(slug||hcSlug());
const hcShort=slug=>hcUrl(slug).replace(/^https?:\/\//,"");

function qrSvg(text){
  if(typeof qrcode!=="function")return"";
  const q=qrcode(0,"M");q.addData(text);q.make();const n=q.getModuleCount();let d="";
  for(let r=0;r<n;r++)for(let c=0;c<n;c++)if(q.isDark(r,c))d+=`M${c} ${r}h1v1h-1z`;
  return `<svg viewBox="0 0 ${n} ${n}" shape-rendering="crispEdges" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="QR code"><path fill="#18314F" d="${d}"/></svg>`}
function orbytLogoSrc(){const im=document.querySelector("picture.logo img");return im?im.getAttribute("src")||"":""}
const nb=s=>esc(s).replace(/ /g,"&nbsp;");

// the card itself: 5 by 7 inches, the same markup for the preview and for printing
function hcCardHtml(h){
  const me=hcMe(),logo=hcLogo(),slug=(hcSaved()||{}).slug||hcSlug();
  const tiles=(h.featured||[]).filter(f=>f&&f.c).slice(0,6).map(f=>{const v=vendorById(f.v),r=v?rating(v.id):null;
    return `<div class="hct"><div class="hcc">${esc(hcLabel(f.c))}</div><div class="hcn">${esc(v?v.name:"Pick a pro")}</div>${r?`<div class="hcs">★ ${r.avg.toFixed(1)} from agents</div>`:""}${f.what?`<div class="hcw">${esc(f.what)}</div>`:""}</div>`}).join("");
  const also=(h.also||[]).filter(c=>!(h.featured||[]).some(f=>f.c===c)).map(c=>nb(hcLabel(c))).join(" · ");
  const who=[`<b>${esc(me.full_name||roleVal()||"")}</b>`,esc(me.brokerage||""),h.showPhone!==false?esc(me.phone||""):""].filter(Boolean).join(" · ");
  return `<div class="htc"><div class="hctop"><div class="hcey">${esc(h.welcome||"Welcome home")}</div>${logo?`<img class="hclg" src="${esc(logo)}" alt="">`:""}</div><h1>Your home team</h1>
    <div class="hcfrom">${esc(h.intro||HC_INTRO)}<br>${who}</div>
    <div class="hcrule"></div><div class="hcgrid">${tiles}</div>
    ${also?`<div class="hcmore"><div class="hcey" style="font-size:7.5pt">Also on call</div><div class="hclist">${also}</div></div>`:""}
    <div class="hcfoot"><span>Each pro joined Orbyt with references from local agents.</span>${orbytLogoSrc()?`<img src="${esc(orbytLogoSrc())}" alt="Orbyt">`:"Orbyt"}</div>
    <div class="hcband"><div class="hcqr">${qrSvg(hcUrl(slug))}</div><div><h2>Need one of them?</h2>
      <p>Scan the code or visit <span class="hcurl">${esc(hcShort(slug))}</span>. Tell me what you need, and I'll set up the intro and a quote.</p>${h.priority!==false?`<span class="hcperk">Booking through me gets you priority scheduling</span>`:""}</div></div></div>`}

/* ---------- the card maker (agent "Home team card" tab) ---------- */
function hcView(agent){
  if(D.home_cards===undefined)return `<div class="emptystate"><h2>Almost ready</h2><p>Home team cards are switched on with the next Orbyt update. Check back soon.</p></div>`;
  if(S.hcNet===undefined){S.hcNet=null;sb.rpc("network_services").then(({data,error})=>{S.hcNet=error?[]:(data||[]);if(S.tab==="card")render()})}
  const h=hcState(),svcs=hcServices(),saved=hcSaved(),logo=hcLogo(),net=Array.isArray(S.hcNet)&&S.hcNet.length?S.hcNet:null;
  const rows=[0,1,2,3,4,5].map(i=>{const f=h.featured[i]||{c:"",v:"",what:""},vs=f.c?hcVendorsFor(f.c):[],fav=favIds(agent);
    return `<div class="hcrow"><label class="field"><span>Spot ${i+1}</span><select class="hc-svc" data-i="${i}" id="hc-svc-${i}"><option value="">Leave empty</option>
        ${svcs.filter(c=>hcVendorsFor(c).length||c===f.c).map(c=>`<option value="${esc(c)}" ${c===f.c?"selected":""}>${esc(hcLabel(c))}</option>`).join("")}</select></label>
      <label class="field"><span>Pro</span><select class="hc-v" data-i="${i}" id="hc-v-${i}" ${f.c?"":"disabled"}>${vs.map(v=>`<option value="${esc(v.id)}" ${v.id===f.v?"selected":""}>${esc(v.name)}${fav.includes(v.id)?" ★":""}</option>`).join("")}</select></label>
      <label class="field"><span>What they do</span><input type="text" class="hc-what" data-i="${i}" id="hc-what-${i}" maxlength="44" value="${esc(f.what||"")}" ${f.c?"":"disabled"}></label></div>`}).join("");
  const alsoOpts=svcs.filter(c=>!h.featured.some(f=>f.c===c)).map(c=>{const n=hcVendorsFor(c).length||(net?net.includes(c):1);
    return `<label><input type="checkbox" class="hc-also" value="${esc(c)}" ${h.also.includes(c)?"checked":""}> ${esc(hcLabel(c))}${n?"":` <span class="small">(no Orbyt pro yet)</span>`}</label>`}).join("");
  const url=hcUrl(saved&&saved.slug);
  const sms=`Here's my home team, the local pros I trust for anything your new home needs. When you need one, send me a request here and I'll set it up: ${url}`;
  setTimeout(hcFit,0);
  return `<div class="hcwrap"><form class="form hcform" data-form="hcard" novalidate>
      <h3>Your home team card</h3>
      <p class="small" style="margin:0">A card for buyer clients to keep on the fridge. It shows your pros' names, ratings and what they do, never their contact details. When a client needs one, they scan the code and send the request to you, and I set up the intro and quote.</p>
      <div class="grid"><label class="field"><span>Top line</span><input type="text" id="hc-welcome" name="welcome" maxlength="48" value="${esc(h.welcome||"")}" placeholder="Welcome home, Mei and Sam"></label>
        <label class="field"><span>Your note</span><input type="text" id="hc-intro" name="intro" maxlength="70" value="${esc(h.intro||"")}"></label></div>
      <fieldset class="field hcfs"><legend class="legend">Your logo (optional)</legend>
        <div class="hclogo">${logo?`<img src="${esc(logo)}" alt="Your logo">`:`<span class="small">Add your team or brokerage logo to co-brand the card and your request page.</span>`}</div>
        <div class="actions" style="margin-top:6px"><label class="btn ghost sm hcfile">${logo?"Replace logo":"Upload logo"}<input type="file" id="hc-logo" accept="image/png,image/jpeg,image/webp,image/svg+xml"></label>${logo?`<button class="linkbtn" type="button" data-act="hclogodel">Remove</button>`:""}</div>
        <p class="small" style="margin:0">A PNG with a clear background looks best.</p></fieldset>
      <fieldset class="field hcfs"><legend class="legend">Six pros on the card</legend><p class="small" style="margin:0 0 6px">Pick from pros you've saved to favorites (marked ★) or worked with on a project. Anything else your client needs, I'll match from the network.</p>${rows}</fieldset>
      <fieldset class="field hcfs"><legend class="legend">Also on call</legend><div class="checks">${alsoOpts}</div></fieldset>
      <label class="checkrow"><input type="checkbox" id="hc-priority" name="priority" ${h.priority!==false?"checked":""}> Show "Booking through me gets you priority scheduling"</label>
      <label class="checkrow"><input type="checkbox" id="hc-phone" name="showPhone" ${h.showPhone!==false?"checked":""}> Show my phone number</label>
      <p class="small warntext hcerr" role="alert" style="margin:0" hidden></p>
      <div class="actions"><button class="btn sm" type="button" data-act="hcprint">Print or save as PDF</button><button class="btn ghost sm" type="submit">Save card</button></div>
      ${saved?`<div class="hclink"><div class="small">Your request page</div><div class="strong" id="hc-url" style="overflow-wrap:anywhere">${esc(url)}</div>
        <div class="actions"><button class="btn ghost sm" type="button" data-act="copylink" data-url="${esc(url)}">Copy link</button><a class="btn ghost sm" href="sms:?&body=${esc(encodeURIComponent(sms))}">Text it to a client</a><a class="linkbtn" href="${esc(url)}" target="_blank" rel="noopener">Open the page</a></div></div>`
        :`<p class="small" style="margin:0">Save the card to turn on your request page at ${esc(hcShort())}.</p>`}
    </form>
    <div class="hcside"><div class="small" style="margin-bottom:6px">Preview · prints 5 × 7 in</div><div class="hcprev" id="hcprev">${hcCardHtml(h)}</div></div></div>`}
function hcFit(){const w=$("#hcprev");if(!w)return;const c=w.querySelector(".htc");if(!c)return;const s=Math.min(1,w.clientWidth/480);c.style.transform=`scale(${s})`;w.style.height=(672*s)+"px"}
window.addEventListener("resize",()=>hcFit());
function hcRead(f){const h=hcState();
  h.welcome=f.querySelector("#hc-welcome").value.trim();h.intro=f.querySelector("#hc-intro").value.trim();
  h.priority=f.querySelector("#hc-priority").checked;h.showPhone=f.querySelector("#hc-phone").checked;
  h.featured=[0,1,2,3,4,5].map(i=>({c:(f.querySelector("#hc-svc-"+i)||{}).value||"",v:(f.querySelector("#hc-v-"+i)||{}).value||"",what:((f.querySelector("#hc-what-"+i)||{}).value||"").trim()})).filter(x=>x.c);
  h.also=[...f.querySelectorAll(".hc-also:checked")].map(x=>x.value);return h}
function hcPreview(){const p=$("#hcprev");if(p){p.innerHTML=hcCardHtml(S.hc);hcFit()}}
document.addEventListener("input",e=>{const f=e.target.closest('form[data-form="hcard"]');if(!f||e.target.type==="file")return;hcRead(f);hcPreview()});
document.addEventListener("change",e=>{const f=e.target.closest('form[data-form="hcard"]');if(!f)return;
  if(e.target.id==="hc-logo")return hcLogoPick(e.target.files&&e.target.files[0]);
  const h=hcRead(f);
  if(e.target.classList.contains("hc-svc")){const i=+e.target.dataset.i,c=e.target.value,vs=c?hcVendorsFor(c):[];
    const arr=[0,1,2,3,4,5].map(j=>({c:(f.querySelector("#hc-svc-"+j)||{}).value||"",v:(f.querySelector("#hc-v-"+j)||{}).value||"",what:((f.querySelector("#hc-what-"+j)||{}).value||"").trim()}));
    arr[i]={c,v:vs[0]?vs[0].id:"",what:HC_SPEC[c]||""};h.featured=arr.filter(x=>x.c);h.also=h.also.filter(x=>x!==c);render()}
  else hcPreview()});
function hcErr(m){const el=$(".hcerr");if(el){el.textContent=m;el.hidden=!m}if(m)toast(m)}
// logos are shrunk in the browser and saved with the card, so the request page can show them too
function hcLogoPick(file){if(!file)return;
  if(file.size>8e6)return hcErr("That image is over 8 MB. Try a smaller file.");
  const rd=new FileReader();rd.onload=()=>{const im=new Image();im.onload=()=>{
    let best="";for(const max of [640,480,360,260]){const k=Math.min(1,max/im.width,(max*.45)/im.height),w=Math.max(1,Math.round(im.width*k)),hh=Math.max(1,Math.round(im.height*k));
      const cv=document.createElement("canvas");cv.width=w;cv.height=hh;cv.getContext("2d").drawImage(im,0,0,w,hh);best=cv.toDataURL("image/png");if(best.length<=380000)break;
      const jp=cv.toDataURL("image/jpeg",.88);if(jp.length<=380000){best=jp;break}}
    if(best.length>380000)return hcErr("That logo is too detailed to save. Try a simpler PNG or JPG.");
    hcState().logo=best;hcErr("");render()};im.onerror=()=>hcErr("That file didn't open as an image. Try a PNG or JPG.");im.src=rd.result};rd.readAsDataURL(file)}
async function hcSave(){const h=hcState(),{logo,...settings}=h;
  const{data,error}=await sb.rpc("home_card_save",{p_settings:settings,p_logo:logo===undefined?null:logo});
  if(error){console.error(error);throw{message:/Only active|too large|logo/.test(error.message||"")?String(error.message).replace(/^.*?ERROR:\s*/,""):"The card didn't save. Check your connection and try again."}}
  await S.db.reload();delete S.hc.logo;return data}
document.addEventListener("submit",e=>{const f=e.target.closest('form[data-form="hcard"]');if(!f)return;e.preventDefault();e.stopImmediatePropagation();hcRead(f);
  guard(async()=>{await hcSave()},()=>"Card saved. Your request page is live.")},true);
document.addEventListener("click",e=>{const t=e.target.closest('[data-act="hcprint"],[data-act="hclogodel"],[data-act="hcmake"]');if(!t)return;e.preventDefault();e.stopImmediatePropagation();
  const a=t.dataset.act;
  if(a==="hclogodel"){hcState().logo="";render();return}
  if(a==="hcmake"){const p=t.dataset.id?projById(t.dataset.id):null;S.hc=null;const h=hcState();
    if(p){const nm=String(client(p)||"").trim();h.welcome=nm?("Welcome home, "+nm.replace(/\s*&\s*/g," and ")).slice(0,48):"Welcome home"}
    S.tab="card";S.openProject=null;S.openForm=null;render();window.scrollTo({top:0});return}
  const f=$('form[data-form="hcard"]');if(f)hcRead(f);
  guard(async()=>{await hcSave();setTimeout(hcPrint,50)})},true);
function hcPrint(){
  document.getElementById("htcprint")?.remove();document.getElementById("htcprintcss")?.remove();
  const box=document.createElement("div");box.id="htcprint";box.innerHTML=hcCardHtml(hcState());document.body.appendChild(box);
  const st=document.createElement("style");st.id="htcprintcss";
  st.textContent="#htcprint{display:none}@media print{@page{size:5in 7in;margin:0}html,body{margin:0!important;padding:0!important;background:#F6F4EA!important}body>*:not(#htcprint){display:none!important}#htcprint{display:block!important}#htcprint .htc{transform:none!important}}";
  document.head.appendChild(st);
  const done=()=>{box.remove();st.remove();window.removeEventListener("afterprint",done)};window.addEventListener("afterprint",done);
  const imgs=[...box.querySelectorAll("img")].map(i=>i.complete?null:new Promise(r=>{i.onload=i.onerror=r})).filter(Boolean);
  Promise.all(imgs).then(()=>{(document.fonts?document.fonts.ready:Promise.resolve()).then(()=>window.print())})}
// on a buyer project: make a card with the client's name on it
function hcProjectBtn(p){if(kind()!=="agent"||!S.canWrite||!p||!["Buyer","Both"].includes(p.clientType))return"";
  return `<div class="callout hccallout"><div><span class="strong">Give ${esc(cfn(p)||"your client")} a home team card</span><div class="small">Your pros for anything the new home needs, with a code that sends requests back to you.</div></div><button class="btn ghost sm" data-act="hcmake" data-id="${esc(p.id)}">Make the card</button></div>`}

/* ---------- the request page behind the card's QR code (no login) ---------- */
async function renderCardRequestPage(slug){
  $("#who").innerHTML="";
  const{data,error}=await sb.rpc("home_card_get",{p_slug:slug});
  if(error||!data){$("#app").innerHTML=reviewCard("Home team","This page isn't active",`<p>Reach out to your agent directly, and they can set up what you need.</p>`);return}
  const first=String(data.agent||"your agent").split(" ")[0];
  const feat=(data.featured||[]).filter(f=>f&&f.c),also=(data.also||[]).filter(c=>!feat.some(f=>f.c===c));
  const opt=(c,sub)=>`<label><input type="checkbox" name="svc" value="${esc(c)}"> <span>${esc(hcLabel(c))}${sub?`<span class="small"> · ${esc(sub)}</span>`:""}</span></label>`;
  $("#app").innerHTML=`<section class="auth one"><div class="authcard">
    ${data.logo?`<img class="hcpagelogo" src="${esc(data.logo)}" alt="${esc(data.brokerage||data.agent||"")}">`:""}
    <div class="eyebrow">${esc([data.agent,data.brokerage].filter(Boolean).join(" · "))}</div><h1>What does your home need?</h1>
    <p class="small" style="margin:0">Pick what you need, and ${esc(first)} will set up the intro and a quote with a trusted local pro.${data.priority?` Booking through ${esc(first)} gets you priority scheduling.`:""}</p>
    <form class="authform" data-form="hcrequest" data-slug="${esc(slug)}" novalidate>
      <fieldset class="field" style="border:0;padding:0;margin:0"><legend class="legend">What do you need?</legend><div class="checks hcopts">${feat.map(f=>opt(f.c,f.name)).join("")}${also.map(c=>opt(c)).join("")}</div></fieldset>
      <label class="field"><span>Anything else? (optional)</span><input type="text" id="hr-other" name="other" maxlength="40" placeholder="Fence repair"></label>
      <label class="field"><span>Home address</span><input type="text" id="hr-address" name="address" autocomplete="street-address" maxlength="200"></label>
      <label class="field"><span>When?</span><select id="hr-when" name="when">${HC_WHEN.map(w=>`<option>${esc(w)}</option>`).join("")}</select></label>
      <label class="field"><span>Details (optional)</span><textarea id="hr-notes" name="notes" rows="3" maxlength="1500" placeholder="Two bedrooms to paint, and the back fence is leaning"></textarea></label>
      <label class="field"><span>Your name</span><input type="text" id="hr-name" name="name" autocomplete="name" maxlength="120"></label>
      <div class="grid"><label class="field"><span>Email</span><input type="email" id="hr-email" name="email" autocomplete="email" maxlength="200"></label>
        <label class="field"><span>Phone</span><input type="tel" id="hr-phone" name="phone" autocomplete="tel" maxlength="40"></label></div>
      <label class="hcpot" aria-hidden="true">Company <input type="text" name="company" tabindex="-1" autocomplete="off"></label>
      <p class="small" style="margin:0">Your details go to ${esc(first)} and Orbyt only, to set this up. Read the <a href="${esc(new URL("privacy.html",portalHome()).href)}" target="_blank" rel="noopener">Privacy Policy</a>.</p>
      <p class="small warntext hrerr" role="alert" style="margin:0" hidden></p>
      <button class="btn" type="submit">Send to ${esc(first)}</button></form>
    <div class="hcpagefoot small">Powered by Orbyt</div></div></section>`;
}
document.addEventListener("submit",async e=>{const f=e.target.closest('form[data-form="hcrequest"]');if(!f)return;e.preventDefault();e.stopImmediatePropagation();
  const fd=new FormData(f),g=k=>String(fd.get(k)||"").trim(),er=f.querySelector(".hrerr"),show=m=>{if(er){er.textContent=m;er.hidden=!m;if(m)er.scrollIntoView({block:"nearest"})}};
  const svcs=[...fd.getAll("svc").map(String),...(g("other")?[canon(g("other")).slice(0,40)]:[])];
  const bad=!svcs.length?"Pick what you need, or type it in.":!g("address")?"Add the home's address.":!g("name")?"Add your name.":!g("email")&&!g("phone")?"Add an email or phone number so we can reach you."
    :g("email")&&!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(g("email"))?"Check your email address.":"";
  if(bad)return show(bad);show("");
  const btn=f.querySelector('button[type="submit"]');if(btn)btn.disabled=true;
  const{error}=await sb.rpc("home_card_request",{p_slug:f.dataset.slug,p_name:g("name"),p_email:g("email"),p_phone:g("phone"),p_address:g("address"),
    p_services:svcs,p_when:g("when"),p_notes:g("notes"),p_company:g("company")||null});
  if(btn)btn.disabled=false;
  if(error){console.error(error);const m=String(error.message||"").replace(/^.*?ERROR:\s*/,"");return show(/^(Add|Pick|Check|You've|This page)/.test(m)?m:"That didn't send. Check your connection and try again.")}
  const first=(f.querySelector('button[type="submit"]').textContent||"").replace(/^Send to /,"");
  $("#app").innerHTML=reviewCard("Request sent","Thanks, "+esc(g("name").split(" ")[0])+"!",`<p>${esc(first)} has your request. You'll hear back soon with the intro and next steps.</p><p class="small">Need something else later? Use this same page anytime.</p>`);window.scrollTo({top:0})},true);
document.addEventListener("input",e=>{const f=e.target.closest('form[data-form="hcrequest"]');if(!f)return;const er=f.querySelector(".hrerr");if(er&&!er.hidden){er.hidden=true;er.textContent=""}});
