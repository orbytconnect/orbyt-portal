
/* ---------- closing partners: lenders, title, escrow and homeowners insurance ----------
   They buy a marketing listing (Closing Partner Marketing Services Agreement): free for 90 days, then $20 a month.
   Agents see every listed partner in an open directory, in a rotating order. Orbyt never picks, introduces or
   recommends one, and partners never pay for referrals. No bids, job fees, insurance tiers or special offers. */
const CLOSING=["Lender","Title","Escrow","Homeowners insurance"];
const CLOSING_HINT={"Lender":"Mortgage lenders and loan officers","Title":"Title companies and title officers","Escrow":"Escrow companies and officers","Homeowners insurance":"Home and hazard insurance"};
const isPartner=v=>!!v&&v.kind==="closing";
const introsFor=(pid,c)=>(Array.isArray(D.intros)?D.intros:[]).filter(i=>i.project_id===pid&&(!c||i.category===c));
const partnersFor=c=>S.vendors.filter(v=>isPartner(v)&&v.approved!==false&&vsv(v).includes(c));
const closingNote=`Listed closing partners pay Orbyt for advertising. Orbyt doesn't recommend one over another, and your client is always free to choose any provider.`;
const LISTING_FEE=20,LISTING_FREE_DAYS=90;
// everyone listed for a service, in an order that rotates daily so no one is always first
const dayKey=()=>new Date().toISOString().slice(0,10);
const rot=id=>{let h=2166136261;for(const ch of dayKey()+id){h^=ch.charCodeAt(0);h=Math.imul(h,16777619)}return h>>>0};
const listedFor=c=>S.vendors.filter(v=>isPartner(v)&&v.approved!==false&&v.available!==false&&(!c||vsv(v).includes(c))).sort((a,b)=>rot(a.id)-rot(b.id));
// the listing, as agents see it
function partnerListing(v,area){const tel=String(v.phone||"").replace(/[^\d+]/g,""),web=safeUrl(v.web);
  return `<div class="listing" style="background:#fff;border:1px solid var(--line,#E4E0D2);border-radius:10px;padding:10px 12px;margin:6px 0"><div class="listinghead" style="display:flex;justify-content:space-between;gap:10px"><div style="min-width:0"><button class="vlink strong" data-act="vcard" data-id="${esc(v.id)}">${esc(v.name)}</button>${v.contactName?`<span class="small"> · ${esc(v.contactName)}</span>`:""}
      <div class="small">${esc(vsv(v).join(", "))}${v.license?` · License ${esc(v.license)}`:""}</div></div><div class="small">${ratingHtml(v.id)}</div></div>
    <div class="small">${[v.phone?`<a href="tel:${esc(tel)}">${esc(v.phone)}</a>`:"",v.email?`<a href="mailto:${esc(v.email)}">${esc(v.email)}</a>`:"",web?`<a href="${esc(web)}" target="_blank" rel="noopener">Website</a>`:"",vendorDocs(v.id)].filter(Boolean).join(" · ")}</div>
    <div class="small">Works in ${esc(areasShort(v.areas))}${area&&(v.areas||[]).includes(area)?` · <span class="strong">covers ${esc(String(area).split(" / ")[0])}</span>`:""}</div></div>`}
// listing status: free for 90 days from agreeing, then $20 a month
function listingAccept(v){const a=(D.terms_acceptances||[]).filter(x=>x.user_id===v.userId&&String(x.version||"").startsWith("partner-terms-")&&x.version>="partner-terms-2026-11-10").sort((x,y)=>String(x.accepted_at).localeCompare(String(y.accepted_at)))[0];return a?String(a.accepted_at).slice(0,10):""}
function listingStatus(v){const acc=listingAccept(v),today=dayKey();
  if(!acc)return{key:"agree",label:"Hasn't agreed to the marketing agreement yet"};
  const free=addDaysIso(acc+"T12:00:00",LISTING_FREE_DAYS),paid=v.listingPaidThrough||"";
  if(today<=free)return{key:"free",label:`Free until ${fmtDate(free)}`,free,paid};
  if(paid&&paid>=today)return{key:"paid",label:`Paid through ${fmtDate(paid)}`,free,paid};
  return{key:"due",label:`$${LISTING_FEE} due${paid?`, paid through ${fmtDate(paid)}`:` since ${fmtDate(free)}`}`,free,paid}}

/* sign-up: portal.orbytconnect.com/join/partner */
function partnerSignupView(){
  const ck=(name,list,hint)=>`<div class="checks">${list.map((x,i)=>`<label><input type="checkbox" id="su-${name}-${i}" name="${name}" value="${esc(x)}">${esc(x)}${hint&&hint[x]?`<span class="small"> · ${esc(hint[x])}</span>`:""}</label>`).join("")}</div>`;
  return `<section class="auth one"><div class="authcard"><div class="eyebrow">For closing partners</div>
    <h1>Lenders, title, escrow and insurance</h1>
    <p class="small" style="margin:0">List your business in Orbyt's closing partner directory for San Diego agents. Your first 90 days are free, then it's $20 a month for your marketing listing. Cancel anytime.</p>
    <form class="authform" data-proto="signup" data-kind="partner" novalidate>
      <p class="small" style="margin:0">Every field is required unless it says optional.</p>
      <label class="field"><span>Company name</span><input type="text" id="su-company" name="company" required></label>
      <div class="grid"><label class="field"><span>First name</span><input type="text" id="su-first" name="first" required></label>
        <label class="field"><span>Last name</span><input type="text" id="su-last" name="last" required></label>
        <label class="field"><span>Email</span><input type="email" id="su-email" name="email" required></label>
        <label class="field"><span>Mobile phone</span><input type="tel" id="su-phone" name="phone" autocomplete="tel" required></label>
        <label class="field"><span>Website (optional)</span><input type="text" id="su-web" name="web" placeholder="yourbusiness.com"></label>
        <label class="field"><span>License number</span><input type="text" id="su-license" name="license" placeholder="NMLS, DRE, DFPI or Dept. of Insurance"></label></div>
      <div class="field"><span>What do you offer?</span>${ck("svc",CLOSING,CLOSING_HINT)}</div>
      <div class="field"><span>Where do you work?</span>${ck("area",AREAS)}</div>
      <div class="grid"><label class="field"><span>Years in business</span><select id="su-years" name="years"><option value="">Choose one</option>${YEARS.map(x=>`<option>${esc(x)}</option>`).join("")}</select></label></div>
      <label class="field"><span>Agents you've worked with (optional)</span><textarea id="su-refs" name="references" placeholder="Names and phone numbers or emails. We can invite them to review you."></textarea></label>
      <label class="field"><span>How did you hear about Orbyt? (optional)</span><input type="text" id="su-heard" name="heard"></label>
      <div class="grid"><label class="field"><span>Create a password (8+ characters)</span><input type="password" id="su-pass" name="password" autocomplete="new-password" required></label>
        <label class="field"><span>Type it again</span><input type="password" id="su-pass2" name="password2" autocomplete="new-password" required></label></div>${showPw("su-show")}
      <div class="reviewagree"><div class="eyebrow">Review and agree</div>
        <h2>Your marketing listing</h2><p class="small" style="margin:0">Free for your first 90 days, then $20 a month, billed monthly. It covers your directory listing, rotating spotlights in Orbyt's emails and posts to agents, and invitations to Orbyt networking and education events. The fee is flat and never depends on contacts, loans, policies or closings. Cancel anytime.</p>
        ${keyHighlights("partner")}
        <h2>Your business</h2>${bizFields("su")}
        <label class="checkrow top"><input type="checkbox" id="su-terms" name="terms"> <span>I've read and agree to the ${termsLink("partner")}.</span></label>
        ${authorityBox("su")}
        <label class="checkrow top"><input type="checkbox" id="su-optout" name="optout"> <span>If you'd rather not receive Orbyt updates and announcements, tick this box.</span></label></div>
      <p class="small" style="margin:0">Read how Orbyt handles your information in our <a href="${esc(new URL("privacy.html",portalHome()).href)}" target="_blank" rel="noopener">Privacy Policy</a>.</p>${authMsg()}
      <div class="actions"><button class="btn" type="submit">Join Orbyt</button><button class="btn ghost" type="button" data-act="authmode" data-m="signin">Back to sign in</button></div>
    </form></div></section>`}
async function partnerSignup(f,fd,email,pass,pass2,done,btn){
  const g=k=>String(fd.get(k)||"").trim(),first=g("first"),last=g("last"),svcs=fd.getAll("svc").map(String),areas=fd.getAll("area").map(String);
  const checks=[[!g("company"),"Add your company name.","#su-company"],[!first||!last,"Add your first and last name.",!first?"#su-first":"#su-last"],
    [!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email),"Enter a valid email.","#su-email"],[g("phone").replace(/\D/g,"").length<10,"Add a mobile phone number, with area code.","#su-phone"],
    [g("license").length<3,"Add your license number (NMLS, DRE, DFPI or Department of Insurance).","#su-license"],
    [!svcs.length,"Pick what you offer.","#su-svc-0"],[!areas.length,"Pick at least one area you work in.","#su-area-0"],[!g("years"),"Choose your years in business.","#su-years"],
    [pass.length<8,"Use a password with at least 8 characters.","#su-pass"],[pass!==pass2,"Those passwords don't match. Type them again.","#su-pass2"],
    [!g("legal"),"Add your legal business name.","#su-legal"],[!fd.get("btype"),"Choose your business type.","#su-btype"],[!g("title"),"Add your title.","#su-title"],
    [!fd.get("terms"),`Check the box to agree to the ${TERMS.partner.title}.`,"#su-terms"],[!fd.get("authority"),"Check the box to confirm you have authority to agree for the business.","#su-auth"]];
  const hit=checks.find(c=>c[0]);
  if(hit){done(hit[1]);const el=f.querySelector(hit[2]);if(el){el.scrollIntoView({block:"center"});try{el.focus({preventScroll:true})}catch(_){}}return}
  const meta={ref:S.ref||"",role:"vendor",partner_kind:"closing",license:g("license"),full_name:first+" "+last,phone:g("phone"),areas,terms_version:TERMS.partner.version,user_agent:navigator.userAgent.slice(0,300),
    ...bizData(fd),marketing_opt_out:!!fd.get("optout"),company:g("company"),website:g("web"),services:svcs,years_in_business:g("years"),references:g("references"),heard_about:g("heard")};
  const{data,error}=await sb.auth.signUp({email,password:pass,options:{data:meta,emailRedirectTo:portalHome()}});
  if(error)return done(friendlyAuthError(error));
  if(data.session){S.authErr="";await enter(data.user);return}
  S.pendingEmail=email;S.authMode="checkemail";S.authErr="";if(btn)btn.disabled=false;render()}

/* the partner's dashboard: their listing */
function partnerView(v){
  const st=listingStatus(v),past=(Array.isArray(D.intros)?D.intros:[]).filter(i=>i.vendor_id===v.id);
  let h=`<section class="hello"><div><div class="eyebrow">Closing partner · ${esc(vsv(v).join(", "))}</div><h1>Hi, ${esc(v.name)}</h1>${v.approved===false?`<p class="banner" style="margin-top:10px">Thanks for joining. I'll check your license and let you know when your listing is live.</p>`:""}
    <p>${v.approved===false?"Once it's live, agents in the network can find your listing in the Orbyt closing partner directory.":"Your listing is live in the Orbyt closing partner directory, where agents in the network can find you and your business overview."}</p>${typeof availToggle==="function"?availToggle(v):""}</div>
    <div>${ratingHtml(v.id)}</div></section>`;
  if(typeof setupCard==="function"&&v.approved!==false)h+=setupCard();
  if(v.approved!==false)h+=`<section class="section"><div class="sechead"><h2>Your listing</h2><span class="pill ${st.key==="due"?"late":st.key==="agree"?"":"set"}">${esc(st.label)}</span></div>
    <p class="small" style="margin:0 0 8px">Here's how agents see you. Your first ${LISTING_FREE_DAYS} days are free, then your marketing listing is $${LISTING_FEE} a month. Cancel anytime by emailing ashleigh@orbytconnect.com.</p>
    ${partnerListing(v)}<p class="small" style="margin:8px 0 0">Your listing also includes rotating spotlights in Orbyt's emails and posts to agents, and invitations to Orbyt networking and education events.</p></section>`;
  if(past.length)h+=`<details class="fold" style="margin-top:12px"><summary><span class="foldtitle">Earlier introductions</span><span class="pill">${past.length}</span></summary><div class="foldbody"><div class="introlist">${past.map(i=>`<div class="introcard"><div class="eyebrow">${esc(i.category)} · ${esc(ago(i.introduced_at))}</div><div class="strong">${esc(i.agent_name||"Agent")}</div><div class="small">${esc(i.address||"")}</div></div>`).join("")}</div></div></details>`;
  if(v.approved===false)return h;
  const parts=[fold("myrev","Your reviews",myReviewsPill(v),"Read them, and copy them for your marketing",myReviewsCard(v),false),
    fold("port","Business overview and portfolio","","Shown on your listing",portfolioCard(v),false)];
  if(typeof reviewInviteCard==="function"){const sent=typeof rrFor==="function"?rrFor(v.id):[];parts.push(fold("rr","Reviews from agents you've worked with",sent.length?`<span class="pill">${sent.length} invited</span>`:"","Invite agents you've worked with",reviewInviteCard(v),!!S.rrMore))}
  parts.push(fold("refer","Refer someone to Orbyt",refCountPill(),"A ready-made message to send",referralCard("partner"),false));
  return h+`<section class="section folds"><div class="sechead" style="margin-bottom:8px"><div><h2>Your profile</h2><span class="small">Tap one to open it.</span></div></div>${parts.join("")}</section>`}

/* projects: local closing partner options, for agents and for Ashleigh (no picking, no intros) */
function closingPanel(p,mode){
  if(mode==="vendor"||!p)return"";const list=p.closing||[],left=CLOSING.filter(c=>!list.includes(c));
  if(!list.length&&!(mode==="agent"&&S.canWrite))return"";
  const rowFor=c=>{const all=listedFor(c),here=all.filter(v=>(v.areas||[]).includes(p.area)),rest=all.filter(v=>!(v.areas||[]).includes(p.area)),old=introsFor(p.id,c);
    return `<div class="closingrow"><div class="eyebrow">${esc(c)} options</div>
      ${here.length?here.map(v=>partnerListing(v,p.area)).join(""):`<p class="small" style="margin:0">${all.length?"No listed "+esc(c.toLowerCase())+" partners cover this area yet.":"No "+esc(c.toLowerCase())+" partners are listed yet."}</p>`}
      ${rest.length?`<details class="moreopts"><summary class="small">${rest.length} more who work elsewhere in San Diego</summary>${rest.map(v=>partnerListing(v,p.area)).join("")}</details>`:""}
      ${old.length?`<div class="small" style="margin-top:6px">Introduced earlier: ${old.map(i=>esc((vendorById(i.vendor_id)||{}).name||"a partner")).join(", ")}</div>`:""}</div>`};
  const add=mode==="agent"&&S.canWrite&&left.length?`<div class="actions"><label class="field" style="margin:0"><span>Show more closing options</span><select id="cl-add-${esc(p.id)}">${left.map(c=>`<option value="${esc(c)}">${esc(c)}</option>`).join("")}</select></label><button class="btn ghost sm" data-act="addclosing" data-id="${esc(p.id)}">Add to this project</button></div>`:"";
  return `<section class="cat closingsec"><div class="cathead"><div><h3>Closing partners</h3><span class="small">${esc(closingNote)}</span></div></div>
    ${list.map(rowFor).join("")}${!list.length&&mode==="agent"?`<p class="small" style="margin:0">Need a lender, title, escrow or insurance contact for this client? Add it here to see local options listed with Orbyt.</p>`:""}${add}</section>`}
document.addEventListener("click",e=>{const t=e.target.closest('[data-act="addclosing"]');if(!t)return;e.preventDefault();e.stopImmediatePropagation();
  const p=projById(t.dataset.id),sel=document.getElementById("cl-add-"+t.dataset.id);if(!p||!sel)return;const c=sel.value;
  guard(async()=>{fail((await sb.from("projects").update({closing:[...new Set([...(p.closing||[]),c])]}).eq("id",p.id)).error,"project");await S.db.reload()},`Added. Local ${c.toLowerCase()} options are on the project.`)},true);
// no hand-picked intros any more, so nothing for Ashleigh to act on
function closingAlerts(){return[]}

/* the agent's Closing partners tab: the whole directory */
function closingDirectory(){const f=S.cdir||{c:"",area:""};
  const all=listedFor(f.c).filter(v=>!f.area||(v.areas||[]).includes(f.area));
  const groups=(f.c?[f.c]:CLOSING).map(c=>[c,all.filter(v=>vsv(v).includes(c))]).filter(g=>g[1].length);
  return `<section class="section"><div class="sechead"><div><h2>Closing partner directory</h2><span class="small">${esc(closingNote)}</span></div></div>
    <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:10px;max-width:560px"><label class="field"><span>Service</span><select id="cd-c" data-cdir="c"><option value="">All</option>${CLOSING.map(c=>`<option ${f.c===c?"selected":""}>${esc(c)}</option>`).join("")}</select></label>
      <label class="field"><span>Area</span><select id="cd-a" data-cdir="area"><option value="">All of San Diego</option>${AREAS.map(a=>`<option ${f.area===a?"selected":""}>${esc(a)}</option>`).join("")}</select></label></div>
    ${groups.length?groups.map(([c,vs])=>`<div class="closingrow"><div class="eyebrow">${esc(c)}</div>${vs.map(v=>partnerListing(v,f.area)).join("")}</div>`).join(""):`<p class="small">No closing partners are listed${f.area||f.c?" for that yet":" yet"}. Know a good one? Use Refer someone to Orbyt.</p>`}</section>`}
document.addEventListener("change",e=>{const t=e.target.closest("[data-cdir]");if(!t)return;S.cdir={...(S.cdir||{c:"",area:""}),[t.dataset.cdir]:t.value};render()});

/* Ashleigh: record a month paid */
document.addEventListener("click",e=>{const t=e.target.closest('[data-act="listingpaid"]');if(!t)return;e.preventDefault();e.stopImmediatePropagation();
  const v=vendorById(t.dataset.id);if(!v)return;const st=listingStatus(v),today=dayKey();
  const base=[today,st.free||"",v.listingPaidThrough||""].sort().pop(),d=new Date(base+"T12:00:00");d.setMonth(d.getMonth()+1);const until=d.toISOString().slice(0,10);
  guard(()=>col("vendors").doc(v.id).update({listingPaidThrough:until}),`${v.name} is paid through ${fmtDate(until)}.`)},true);
function listingCell(v){const st=listingStatus(v);
  return `<div class="small ${st.key==="due"?"warntext":""}">${esc(st.label)}</div>${st.key!=="agree"&&S.canWrite?`<button class="linkbtn" style="white-space:nowrap" data-act="listingpaid" data-id="${esc(v.id)}">Mark a month paid</button>`:""}`}
