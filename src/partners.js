
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
  const img=v.adImage&&typeof ovUrl==="function"?ovUrl(v.adImage):"";
  return `<div class="listing" style="background:var(--surface);color:var(--ink);border:1px solid var(--line);border-radius:10px;padding:12px 14px;margin:6px 0"><div class="listinghead" style="display:flex;justify-content:space-between;gap:10px"><div style="display:flex;gap:12px;min-width:0">${img?`<img class="adimg" src="${esc(img)}" alt="" loading="lazy">`:""}<div style="min-width:0"><button class="vlink strong" data-act="vcard" data-id="${esc(v.id)}">${esc(v.name)}</button>
      <div class="small">${[v.contactName,vsv(v).join(", "),v.license?"License "+v.license:""].filter(Boolean).map(esc).join(" · ")}</div></div></div><div class="small">${ratingHtml(v.id)}</div></div>
    ${v.adHeadline||v.adBody?`<div class="adcopy">${v.adHeadline?`<div class="adhead">${esc(v.adHeadline)}</div>`:""}${v.adBody?`<div class="small">${esc(v.adBody)}</div>`:""}</div>`:""}
    <div class="small">${[v.phone?`<a href="tel:${esc(tel)}">${esc(v.phone)}</a>`:"",v.email?`<a href="mailto:${esc(v.email)}">${esc(v.email)}</a>`:"",web?`<a href="${esc(web)}" target="_blank" rel="noopener">Website</a>`:"",vendorDocs(v.id)].filter(Boolean).join(" · ")}</div>
    <div class="small">Works in ${esc(areasShort(v.areas))}${area&&(v.areas||[]).includes(area)?` · <span class="strong">covers ${esc(String(area).split(" / ")[0])}</span>`:""}</div></div>`}
// listing status: free for 90 days from agreeing, then $20 a month
function listingAccept(v){if(!v.userId)return"";const a=(D.terms_acceptances||[]).filter(x=>x.user_id===v.userId&&String(x.version||"").startsWith("partner-terms-")&&x.version>="partner-terms-2026-11-10").sort((x,y)=>String(x.accepted_at).localeCompare(String(y.accepted_at)))[0];return a?String(a.accepted_at).slice(0,10):""}
function listingStatus(v){const acc=listingAccept(v),today=dayKey(),b=billingOf(v.id);
  if(b.billing_status==="canceled")return{key:"canceled",label:"Canceled"+(b.billing_cancel_at?` ${fmtDate(b.billing_cancel_at)}`:""),b};
  if(!acc)return{key:"agree",label:"Hasn't agreed to the marketing agreement yet",b};
  const free=addDaysIso(acc+"T12:00:00",LISTING_FREE_DAYS),paid=v.listingPaidThrough||"",card=hasCard(b);
  if(b.billing_status==="past_due")return{key:"due",label:"Card declined",free,paid,b};
  if(today<=free)return{key:"free",label:`Free until ${fmtDate(free)}${card?" · card on file":""}`,free,paid,b};
  if(paid&&paid>=today)return{key:"paid",label:`Paid through ${fmtDate(paid)}`,free,paid,b};
  if(card&&b.billing_status==="active")return{key:"paid",label:paid?`Active · paid through ${fmtDate(paid)}`:"Active",free,paid,b};
  return{key:"due",label:`$${LISTING_FEE} due${paid?`, paid through ${fmtDate(paid)}`:` since ${fmtDate(free)}`}`,free,paid,b}}

/* ---------- card payments (Stripe) ---------- */
const billingOn=()=>{try{return!!((typeof settingVal==="function"?settingVal("billing"):null)||{}).enabled}catch(_){return false}};
const billingOf=vid=>(Array.isArray(D.vendor_billing)?D.vendor_billing:[]).find(x=>x.vendor_id===vid)||{};
const hasCard=b=>!!(b&&b.stripe_subscription_id&&b.billing_status!=="canceled");
async function payCall(fn,body){const{data:{session}}=await sb.auth.getSession();if(!session)throw{message:"Sign in again, then try once more."};
  const r=await fetch("/.netlify/functions/"+fn,{method:"POST",headers:{"Content-Type":"application/json",Authorization:"Bearer "+session.access_token},body:JSON.stringify(body||{})});
  const j=await r.json().catch(()=>({}));if(!r.ok||!j.url)throw{message:j.error||"That didn't work. Try again in a minute."};location.href=j.url}
const startCheckout=(kind,extra)=>payCall("stripe-checkout",{kind,...(extra||{})});
const openBilling=()=>payCall("stripe-portal");
document.addEventListener("click",e=>{const t=e.target.closest('[data-act="paycard"],[data-act="billingportal"]');if(!t)return;e.preventDefault();e.stopImmediatePropagation();
  t.disabled=true;const old=t.textContent;t.textContent="Opening Stripe...";
  (t.dataset.act==="paycard"?startCheckout(t.dataset.kind||"listing"):openBilling()).catch(err=>{t.disabled=false;t.textContent=old;toast(err.message||"That didn't work.")})},true);
// the partner's card, in their portal
function billingBlock(v){if(!billingOn())return"";const b=billingOf(v.id),st=listingStatus(v),first=st.free?addDaysIso(st.free+"T12:00:00",1):"";
  const firstCharge=[first,v.listingPaidThrough?addDaysIso(v.listingPaidThrough+"T12:00:00",1):""].sort().pop();
  const box=(cls,txt,btn)=>`<div class="callout ${cls}" style="margin:10px 0 0"><p style="margin:0">${txt}</p><div class="actions" style="margin-top:8px">${btn}</div></div>`;
  if(b.billing_status==="canceled")return box("","<span class=\"strong\">Your listing is canceled</span>, so agents don't see it. You can restart it anytime.",`<button class="btn sm" data-act="paycard" data-kind="listing">Restart my listing</button>`);
  if(b.billing_status==="past_due")return box("warn","<span class=\"strong\">Your last payment didn't go through.</span> Update your card to keep your listing in the directory.",`<button class="btn sm" data-act="billingportal">Update my card</button>`);
  if(!hasCard(b))return box("",`<span class="strong">Add your card to keep your listing after your launch offer.</span> You won't be charged until ${esc(fmtDate(firstCharge||dayKey()))}, then it's $${LISTING_FEE} a month. Cancel anytime.`,`<button class="btn sm" data-act="paycard" data-kind="listing">Add my card</button>`);
  const when=b.billing_cancel_at?`Your listing is set to end ${esc(fmtDate(b.billing_cancel_at))}.`:st.key==="free"?`Your first $${LISTING_FEE} charge is on ${esc(fmtDate(firstCharge))}.`:`$${LISTING_FEE} a month${v.listingPaidThrough?`, paid through ${esc(fmtDate(v.listingPaidThrough))}`:""}.`;
  return `<div class="actions" style="margin:10px 0 0;align-items:center"><span class="small"><span class="strong">Card on file.</span> ${when}</span><button class="btn ghost sm" data-act="billingportal">Manage billing</button></div>`}

/* sign-up: portal.orbytconnect.com/join/partner */
const CARD_NOTE=" After you confirm your email, you'll add a card to finish. It isn't charged until your 90 days are up.";
function partnerSignupView(){
  if(S.billPublic===undefined){S.billPublic=false;sb.rpc("billing_enabled").then(({data})=>{if(data){S.billPublic=true;const el=document.getElementById("su-cardnote");if(el)el.textContent=CARD_NOTE}},()=>{})}
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
        <h2>Your marketing listing</h2><p class="small" style="margin:0">Free for your first 90 days, then $20 a month, billed monthly. It covers your directory listing, rotating spotlights in Orbyt's emails and posts to agents, and invitations to Orbyt networking and education events. The fee is flat and never depends on contacts, loans, policies or closings. Cancel anytime.<span id="su-cardnote">${S.billPublic?CARD_NOTE:""}</span></p>
        ${keyHighlights("partner")}
        <h2>Your business</h2>${bizFields("su")}
        <label class="checkrow top"><input type="checkbox" id="su-terms" name="terms"> <span>I've read and agree to the ${termsLink("partner")}.</span></label>
        ${authorityBox("su")}
        <label class="checkrow top"><input type="checkbox" id="su-optout" name="optout"> <span class="small" style="font-weight:300">If you'd rather not receive Orbyt updates and announcements, tick this box.</span></label></div>
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
  S.pendingEmail=email;S.pendingPartner=true;S.authMode="checkemail";S.authErr="";if(btn)btn.disabled=false;render()}

/* the partner's dashboard: their listing */
function partnerView(v){
  if(typeof msgPending==="function")msgPending();
  if(S.tab==="messages"&&typeof messagesView==="function"&&msgOn())return `<section class="hello"><div><div class="eyebrow">Closing partner · ${esc(vsv(v).join(", "))}</div><h1>Messages</h1></div><div><button class="btn ghost sm" type="button" data-act="partnerhome">Back to your listing</button></div></section>`+messagesView();
  const st=listingStatus(v),past=(Array.isArray(D.intros)?D.intros:[]).filter(i=>i.vendor_id===v.id),live=v.approved!==false;
  const sec=(id,n,title,sub,right,body)=>`<section class="psec" data-fold="${id}"><div class="psechead"><div><div class="eyebrow">${n}</div><h2>${title}</h2>${sub?`<p class="small">${sub}</p>`:""}</div>${right?`<div>${right}</div>`:""}</div><div class="psecbody">${body}</div></section>`;
  let h=`<section class="hello"><div><div class="eyebrow">Closing partner · ${esc(vsv(v).join(", "))}</div><h1>Hi, ${esc(v.name)}</h1>
    ${live?"":`<p class="banner" style="margin-top:10px">Thanks for joining. I'll check your license and let you know when your listing is live.</p>`}</div>
    <div class="hellore">${ratingHtml(v.id)}${typeof msgAshBtn==="function"&&msgOn()?msgAshBtn(unreadTotal()?`Messages from Ashleigh (${unreadTotal()})`:"Message Ashleigh","btn ghost sm"):""}</div></section>`;
  if(typeof newsCard==="function")h+=newsCard();if(typeof setupCard==="function"&&live)h+=setupCard();
  h+=sec("listing","1 · Your listing","How agents see you",live?"Agents in the network find you in the Orbyt closing partner directory and on their buyers' projects.":"Once it's live, agents in the network can find your listing in the Orbyt closing partner directory.",
    live?`<span class="pill ${st.key==="due"||st.key==="canceled"?"late":st.key==="agree"?"":"set"}">${esc(st.label)}</span>`:"",
    `${live&&typeof availToggle==="function"?availToggle(v):""}${partnerListing(v)}
     <p class="small" style="margin:10px 0 0">Your first ${LISTING_FREE_DAYS} days are free with our launch offer, then your marketing listing is $${LISTING_FEE} a month. ${billingOn()?"Cancel anytime from Manage billing.":"Cancel anytime by emailing ashleigh@orbytconnect.com."} It also includes rotating spotlights in Orbyt's emails and posts to agents, and invitations to Orbyt networking and education events.</p>${billingBlock(v)}`);
  h+=sec("port","2 · Your ad","Tell agents why to call you","This is your advertisement on your listing. Write it the way you'd pitch an agent over coffee.","",adCard(v));
  if(live){const sent=typeof rrFor==="function"?rrFor(v.id):[];
    h+=sec("myrev","3 · Reviews","What agents say about you","",myReviewsPill(v),
      myReviewsCard(v)+(typeof reviewInviteCard==="function"?`<details class="fold" data-fold="rr" style="margin-top:12px" ${S.rrMore?"open":""}><summary><span class="foldtitle">Invite agents to review you</span>${sent.length?`<span class="pill">${sent.length} invited</span>`:""}</summary><div class="foldbody">${reviewInviteCard(v)}</div></details>`:""));
    h+=sec("refer","4 · Spread the word","Refer someone to Orbyt","",refCountPill(),referralCard("partner"))}
  if(past.length)h+=`<details class="fold" style="margin-top:12px"><summary><span class="foldtitle">Earlier introductions</span><span class="pill">${past.length}</span></summary><div class="foldbody"><div class="introlist">${past.map(i=>`<div class="introcard"><div class="eyebrow">${esc(i.category)} · ${esc(ago(i.introduced_at))}</div><div class="strong">${esc(i.agent_name||"Agent")}</div><div class="small">${esc(i.address||"")}</div></div>`).join("")}</div></div></details>`;
  return h}

/* the partner's own ad on their listing */
function adCard(v){const img=v.adImage&&typeof ovUrl==="function"?ovUrl(v.adImage):"",ov=v.overviewPdf&&typeof ovUrl==="function"?ovUrl(v.overviewPdf):"";
  return `<form class="form inner" data-form="partnerad" novalidate>
    <label class="field"><span>Headline</span><input type="text" id="ad-head" name="headline" maxlength="80" value="${esc(v.adHeadline||"")}" placeholder="Fast, local pre-approvals your buyers can count on"></label>
    <label class="field"><span>Your pitch</span><textarea id="ad-body" name="body" rows="3" maxlength="400" placeholder="What's it like to work with you? Turnaround times, the loan types or coverage you offer, how you keep agents and buyers in the loop.">${esc(v.adBody||"")}</textarea></label>
    <div class="grid"><div><label class="field"><span>${img?"Replace your logo or photo":"Logo or photo (optional)"}</span><input type="file" id="ad-img" name="image" accept="image/png,image/jpeg,image/webp"></label>
        ${img?`<div class="small" style="margin-top:6px;display:flex;gap:8px;align-items:center"><img class="adimg" src="${esc(img)}" alt="Your logo or photo"><button class="linkbtn" type="button" data-act="adimgdel">Remove</button></div>`:""}</div>
      <div><label class="field"><span>${v.overviewPdf?"Replace your flyer or rate sheet":"Flyer or rate sheet PDF (optional)"}</span><input type="file" id="pt-ov" name="overview" accept="application/pdf"></label>
        ${v.overviewPdf?`<div class="small" style="margin-top:6px">On file: <a href="${esc(ov)}" target="_blank" rel="noopener">${esc(v.overviewPdfName||"Flyer")}</a> · <button class="linkbtn" type="button" data-act="ovpdfdel">Remove</button></div>`:""}</div></div>
    <div class="grid"><label class="field"><span>Website</span><input type="text" id="pt-web" name="web" value="${esc(v.web||"")}" placeholder="yourbusiness.com"></label>
      <label class="field"><span>Instagram</span><input type="text" id="pt-ig" name="instagram" value="${esc(v.instagram?"@"+v.instagram:"")}" placeholder="@yourbusiness"></label></div>
    <p class="small" style="margin:0">Keep it accurate, and include any license number or disclosure your industry requires. Agents see your ad, logo, flyer and links on your listing.</p>
    <p class="small warntext aderr" role="alert" style="margin:0" hidden></p>
    <div class="actions"><button class="btn sm" type="submit">Save your ad</button></div></form>`}
document.addEventListener("submit",e=>{const f=e.target.closest('form[data-form="partnerad"]');if(!f)return;e.preventDefault();e.stopImmediatePropagation();
  const v=vendorById(myVendorId());if(!v)return;const fd=new FormData(f),img=fd.get("image"),ovf=fd.get("overview"),el=f.querySelector(".aderr");
  const bad=m=>{if(el){el.textContent=m;el.hidden=false}};
  if(img&&img.size&&(!/^image\/(png|jpeg|webp)$/.test(img.type)||img.size>5e6))return bad(img.size>5e6?"That image is over 5 MB. Try a smaller one.":"Choose a PNG, JPG or WebP image.");
  if(ovf&&ovf.size&&(ovf.type!=="application/pdf"||ovf.size>25e6))return bad(ovf.type!=="application/pdf"?"Choose a PDF for your flyer.":"That PDF is over 25 MB. Try a smaller version.");
  guard(async()=>{const row={ad_headline:String(fd.get("headline")||"").trim().slice(0,80)||null,ad_body:String(fd.get("body")||"").trim().slice(0,400)||null,
      website:String(fd.get("web")||"").trim()||null,instagram:igHandle(fd.get("instagram"))||null};
    if(img&&img.size){const old=v.adImage;row.ad_image=await putFile("vendor-public",v.id,img);if(old)try{await sb.storage.from("vendor-public").remove([old])}catch(_){}}
    if(ovf&&ovf.size){const old=v.overviewPdf;Object.assign(row,{overview_pdf:await putFile("vendor-public",v.id,ovf),overview_pdf_name:ovf.name.slice(0,120)});if(old)try{await sb.storage.from("vendor-public").remove([old])}catch(_){}}
    fail((await sb.from("vendors").update(row).eq("id",v.id)).error,"ad");await S.db.reload()},"Your ad is saved. Agents see it on your listing.")},true);
document.addEventListener("click",e=>{const t=e.target.closest('[data-act="adimgdel"]');if(!t)return;e.preventDefault();const v=vendorById(myVendorId());if(!v||!v.adImage)return;
  guard(async()=>{try{await sb.storage.from("vendor-public").remove([v.adImage])}catch(_){}fail((await sb.from("vendors").update({ad_image:null}).eq("id",v.id)).error,"ad");await S.db.reload()},"Removed.")},true);

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

/* ---------- Ashleigh: listing fees (kept apart from vendor job fees) ---------- */
const allPays=()=>Array.isArray(D.listing_payments)?D.listing_payments:[];
const listingPays=()=>allPays().filter(x=>(x.kind||"listing")==="listing");
const promoPays=()=>allPays().filter(x=>x.kind==="promo");
const paysFor=vid=>listingPays().filter(x=>x.vendor_id===vid).sort((a,b)=>String(b.period_end).localeCompare(String(a.period_end)));
const addMonthIso=(iso,n)=>{const d=new Date(iso+"T12:00:00"),day=d.getDate();d.setDate(1);d.setMonth(d.getMonth()+n);d.setDate(Math.min(day,new Date(d.getFullYear(),d.getMonth()+1,0).getDate()));return d.toISOString().slice(0,10)};
// the next month to pay for starts the day after their free period or their last paid month, whichever is later
function nextPeriod(v){const st=listingStatus(v);if(st.key==="agree")return null;
  const cover=[st.free||"",v.listingPaidThrough||""].sort().pop(),start=addDaysIso(cover+"T12:00:00",1);return{start,end:addDaysIso(addMonthIso(start,1)+"T12:00:00",-1)}}
const partnersAll=()=>S.vendors.filter(v=>isPartner(v));
const partnersLive=()=>partnersAll().filter(v=>v.approved!==false&&billingOf(v.id).billing_status!=="canceled");
function listingDue(){return partnersLive().filter(v=>listingStatus(v).key==="due").map(v=>{const st=listingStatus(v),np=nextPeriod(v);
  const months=Math.max(1,Math.ceil((Date.parse(dayKey())-Date.parse(np.start))/(30.4*864e5)));return{v,st,np,months,amt:months*LISTING_FEE}})}
document.addEventListener("click",e=>{const t=e.target.closest('[data-act="listingpaid"]');if(!t)return;e.preventDefault();e.stopImmediatePropagation();
  const v=vendorById(t.dataset.id);if(!v)return;const np=nextPeriod(v);if(!np)return;
  guard(async()=>{
    if(Array.isArray(D.listing_payments))fail((await sb.from("listing_payments").insert({vendor_id:v.id,amount:LISTING_FEE,period_start:np.start,period_end:np.end})).error,"listing payment");
    else await col("vendors").doc(v.id).update({listingPaidThrough:np.end});
    await S.db.reload()},`${v.name}: $${LISTING_FEE} recorded, paid through ${fmtDate(np.end)}.`)},true);
document.addEventListener("click",e=>{const t=e.target.closest('[data-act="listingundo"]');if(!t)return;e.preventDefault();e.stopImmediatePropagation();
  guard(async()=>{fail((await sb.from("listing_payments").delete().eq("id",t.dataset.id)).error,"listing payment");await S.db.reload()},"Payment removed.")},true);
function listingCell(v){const st=listingStatus(v),b=st.b||{};
  const card=billingOn()||b.stripe_customer_id?`<div class="small">${b.billing_status==="canceled"?"Stripe: canceled":b.billing_status==="past_due"?'<span class="warntext">Stripe: card declined</span>':hasCard(b)?(b.billing_cancel_at?`Card on file · ends ${esc(fmtDate(b.billing_cancel_at))}`:"Card on file"):"No card yet"}</div>`:"";
  return `<div class="small ${st.key==="due"||st.key==="canceled"?"warntext":""}">${esc(st.label)}</div>${card}${st.key!=="agree"&&st.key!=="canceled"&&S.canWrite?`<button class="linkbtn" style="white-space:nowrap" data-act="listingpaid" data-id="${esc(v.id)}">Mark a month paid</button>`:""}`}

/* Ashleigh's Closing partners tab: its own directory, apart from vendors */
function partnersAdminView(){const all=partnersAll().sort((a,b)=>a.name.localeCompare(b.name)),f=S.pf||{c:"",st:"",q:""},q=(f.q||"").trim().toLowerCase();
  const pend=all.filter(v=>v.approved===false);
  const keyOf=v=>{const k=listingStatus(v).key;return k==="canceled"?k:v.approved===false?"review":v.available===false?"hidden":k};
  const vs=all.filter(v=>(!q||(v.name+" "+(v.contactName||"")+" "+(v.email||"")).toLowerCase().includes(q))&&(!f.c||vsv(v).includes(f.c))&&(!f.st||(f.st==="nocard"?!hasCard(billingOf(v.id)):keyOf(v)===f.st)));
  const live=partnersLive(),paying=live.filter(v=>listingStatus(v).key==="paid").length,free=live.filter(v=>listingStatus(v).key==="free").length,due=listingDue();
  const sel=(id,k,label,opts)=>`<label class="field"><span>${label}</span><select id="${id}" data-pf="${k}">${opts.map(([v,t])=>`<option value="${esc(v)}" ${f[k]===v?"selected":""}>${esc(t)}</option>`).join("")}</select></label>`;
  let h=(S.canWrite?billingSetupCard():"")+`<div class="stats" style="--n:4;margin-bottom:18px">
    <div class="stat static"><span class="eyebrow">Listed partners</span><b class="num">${live.length}</b><span class="small">${live.filter(v=>v.available!==false).length} showing to agents</span></div>
    <div class="stat static"><span class="eyebrow">Paying</span><b class="num">${paying}</b><span class="small">${money2(paying*LISTING_FEE)} a month</span></div>
    <div class="stat static"><span class="eyebrow">In free period</span><b class="num">${free}</b><span class="small">First ${LISTING_FREE_DAYS} days</span></div>
    <div class="stat static"><span class="eyebrow">Fee due</span><b class="num ${due.length?"warntext":""}">${due.length}</b><span class="small">${money2(due.reduce((s,x)=>s+x.amt,0))} owed</span></div></div>`;
  if(pend.length)h+=`<section class="section"><h2>Waiting for your review <span class="count">${pend.length}</span></h2><p class="small" style="margin:4px 0 10px">Check each license, then approve. Approve every licensed provider: the directory stays open to all.</p>
    <div class="tablewrap"><table><thead><tr><th>Partner</th><th>Service</th><th>License</th><th>Signed up</th><th></th></tr></thead><tbody>${pend.map(v=>`<tr><td><button class="vlink strong" data-act="vcard" data-id="${esc(v.id)}">${esc(v.name)}</button><div class="small">${esc([v.contactName,vPhone(v),vEmail(v)].filter(Boolean).join(" · "))}</div></td>
      <td>${esc(vsv(v).join(", "))}</td><td class="small">${esc(v.license||"None given")}</td><td class="small">${v.createdAt?ago(v.createdAt):""}</td><td><button class="btn sm" data-act="vcard" data-id="${esc(v.id)}">Review</button></td></tr>`).join("")}</tbody></table></div></section>`;
  h+=`<section class="section"><div class="sechead"><div><h2>Closing partner directory</h2><span class="small">Lenders, title, escrow and insurance. Agents see listed partners in a rotating order with the advertising note.</span></div></div>
    <div class="rfilters"><label class="field rsearch"><span>Search</span><input type="text" id="pf-q" data-pf="q" value="${esc(f.q||"")}" placeholder="Name or contact"></label>
      ${sel("pf-c","c","Service",[["","All services"],...CLOSING.map(c=>[c,c])])}
      ${sel("pf-st","st","Status",[["","Everyone"],["review","Needs review"],["free","Free period"],["paid","Paid"],["due","Fee due"],["hidden","Hidden by partner"],["canceled","Canceled"],["nocard","No card on file"],["agree","Hasn't accepted the agreement"]])}</div>
    ${vs.length?`<div class="tablewrap"><table><thead><tr><th>Partner</th><th>Service</th><th>Areas</th><th>License</th><th>Listing</th><th>Fee</th></tr></thead><tbody>${vs.map(v=>`<tr>
      <td><button class="vlink strong" data-act="vcard" data-id="${esc(v.id)}">${esc(v.name)}</button>${v.approved===false?' <span class="pill late">Needs review</span>':""}${agreementPill(v)}<div class="small">${esc([v.contactName,vPhone(v),vEmail(v)].filter(Boolean).join(" · "))}</div><div class="small">${ratingHtml(v.id)}</div></td>
      <td>${esc(vsv(v).join(", "))}</td><td class="small" style="max-width:200px" title="${esc((v.areas||[]).join(", "))}">${esc(areasShort(v.areas))}</td>
      <td>${v.licensed?"Licensed":'<span style="color:var(--warn)">Check license</span>'}${v.license?`<div class="small">${esc(v.license)}</div>`:""}</td>
      <td class="small">${v.approved===false?"Not live yet":v.available!==false?"Showing":"Hidden by partner"}</td>
      <td style="min-width:140px">${v.approved===false?(S.canWrite?`<button class="btn sm" data-act="vcard" data-id="${esc(v.id)}">Review</button>`:""):listingCell(v)}</td></tr>`).join("")}</tbody></table></div>`:`<p class="small">${all.length?"No partners match those filters.":"No closing partners yet. Share portal.orbytconnect.com/join/partner."}</p>`}</section>`;
  return h}
document.addEventListener("input",e=>{const t=e.target.closest('input[data-pf]');if(!t)return;S.pf={...(S.pf||{}),q:t.value};clearTimeout(S.pfT);S.pfT=setTimeout(()=>{render();const el=document.getElementById("pf-q");if(el){el.focus();el.setSelectionRange(el.value.length,el.value.length)}},250)});
document.addEventListener("change",e=>{const t=e.target.closest('select[data-pf]');if(!t)return;S.pf={...(S.pf||{}),[t.dataset.pf]:t.value};render()});

/* invoicing: listing fees, kept separate from job fees */
function listingInvoicing(){if(!partnersAll().length&&!listingPays().length)return"";
  const due=listingDue(),today=dayKey(),soon=addDaysIso(today+"T12:00:00",30);
  const upcoming=partnersLive().map(v=>({v,st:listingStatus(v),np:nextPeriod(v)})).filter(x=>x.np&&x.st.key!=="due"&&x.np.start<=soon).sort((a,b)=>a.np.start.localeCompare(b.np.start));
  const monthStart=today.slice(0,8)+"01",pays=listingPays().slice().sort((a,b)=>String(b.paid_at).localeCompare(String(a.paid_at)));
  const thisMonth=pays.filter(x=>String(x.paid_at).slice(0,10)>=monthStart).reduce((s,x)=>s+Number(x.amount||0),0);
  const paying=partnersLive().filter(v=>listingStatus(v).key==="paid").length;
  return `<section class="section"><h2>Closing partner marketing fees</h2><p class="small" style="margin:4px 0 12px">Flat $${LISTING_FEE} a month marketing listings, after a ${LISTING_FREE_DAYS}-day free period. Tracked separately from vendor job fees.</p>
    <div class="stats" style="--n:3;margin-bottom:14px">
      <div class="stat static"><span class="eyebrow">Due now</span><b class="num ${due.length?"warntext":""}">${money2(due.reduce((s,x)=>s+x.amt,0))}</b><span class="small">${due.length} ${due.length===1?"partner":"partners"}</span></div>
      <div class="stat static"><span class="eyebrow">Collected this month</span><b class="num">${money2(thisMonth)}</b><span class="small">Marketing fees</span></div>
      <div class="stat static"><span class="eyebrow">Monthly recurring</span><b class="num">${money2(paying*LISTING_FEE)}</b><span class="small">${paying} paying</span></div></div>
    <h3 style="margin:16px 0 8px">Due now</h3>${due.length?`<div class="tablewrap"><table><thead><tr><th>Partner</th><th>Since</th><th>Owed</th><th></th></tr></thead><tbody>${due.map(x=>`<tr><td><button class="vlink strong" data-act="vcard" data-id="${esc(x.v.id)}">${esc(x.v.name)}</button><div class="small">${esc([x.v.contactName,vEmail(x.v)].filter(Boolean).join(" · "))}</div></td>
      <td class="num">${fmtDate(x.np.start)}</td><td class="money">${money2(x.amt)}<div class="small">${x.months} ${x.months===1?"month":"months"}</div></td><td>${S.canWrite?`<button class="btn sm" data-act="listingpaid" data-id="${esc(x.v.id)}">Mark a month paid</button>`:""}</td></tr>`).join("")}</tbody></table></div>`:`<p class="small">Nothing due.</p>`}
    <h3 style="margin:18px 0 8px">Coming up in the next 30 days</h3>${upcoming.length?`<div class="tablewrap"><table><thead><tr><th>Partner</th><th>Next month starts</th><th>Why</th><th>Amount</th></tr></thead><tbody>${upcoming.map(x=>`<tr><td>${esc(x.v.name)}</td><td class="num">${fmtDate(x.np.start)}</td><td class="small">${x.st.key==="free"?"Free period ends":"Renewal"}</td><td class="money">${money2(LISTING_FEE)}</td></tr>`).join("")}</tbody></table></div>`:`<p class="small">No listing fees start in the next 30 days.</p>`}
    ${pays.length?`<h3 style="margin:18px 0 8px">Payments recorded</h3><div class="tablewrap"><table><thead><tr><th>Partner</th><th>Covers</th><th>Recorded</th><th>Amount</th><th></th></tr></thead><tbody>${pays.slice(0,S.allLp?999:8).map(x=>{const v=vendorById(x.vendor_id),last=paysFor(x.vendor_id).filter(y=>(y.kind||"listing")==="listing")[0];return `<tr><td>${esc(v?v.name:"Partner")}</td><td class="small">${fmtDate(x.period_start)} to ${fmtDate(x.period_end)}</td><td class="num">${fmtDate(String(x.paid_at).slice(0,10))}<div class="small">${x.source==="stripe"?"Card (Stripe)":"Recorded by you"}</div></td><td class="money">${money2(Number(x.amount||0))}</td>
      <td>${S.canWrite&&last&&last.id===x.id&&x.source!=="stripe"?`<button class="linkbtn" data-act="listingundo" data-id="${esc(x.id)}">Undo</button>`:""}</td></tr>`}).join("")}</tbody></table></div>${pays.length>8?`<button class="linkbtn" data-act="alllp">${S.allLp?"Show fewer":"Show all "+pays.length}</button>`:""}`:""}</section>`}
document.addEventListener("click",e=>{const t=e.target.closest('[data-act="alllp"]');if(!t)return;e.preventDefault();e.stopImmediatePropagation();S.allLp=!S.allLp;render()},true);

/* money for forecasts and reports: listing payments recorded, and the next 12 months of expected fees */
function listingMoneyItems(){const items=[],today=dayKey();
  for(const x of promoPays()){const v=vendorById(x.vendor_id);items.push({date:String(x.paid_at).slice(0,10),stage:"paid",sub:"Special offer fee, paid",amt:Number(x.amount||0),label:`${v?v.name:"Vendor"} · Special offer`,listing:true})}
  for(const x of listingPays()){const v=vendorById(x.vendor_id);items.push({date:String(x.paid_at).slice(0,10),stage:"paid",sub:"Closing partner marketing fee, paid",amt:Number(x.amount||0),label:`${v?v.name:"Closing partner"} · Marketing fee`,listing:true})}
  for(const v of partnersLive()){let np=nextPeriod(v);if(!np)continue;
    for(let i=0;i<12;i++){items.push({date:np.start<today?today:np.start,stage:"exp",sub:np.start<today?"Closing partner marketing fee, due":"Closing partner marketing fee",amt:LISTING_FEE,est:np.start>=today,label:`${v.name} · Marketing fee`,listing:true});
      const s=addMonthIso(np.start,1);np={start:s}}}
  return items}
const listingRev=(a,b)=>listingPays().filter(x=>inR(String(x.paid_at).slice(0,10),a,b)).reduce((s,x)=>s+Number(x.amount||0),0);
const promoRev=(a,b)=>promoPays().filter(x=>inR(String(x.paid_at).slice(0,10),a,b)).reduce((s,x)=>s+Number(x.amount||0),0);

/* Ashleigh's dashboard: fees due */
function listingAlerts(){return listingDue().map(x=>{const vt=typeof vTo==="function"?vTo(x.v):null;
  return{id:"listdue-"+x.v.id+"-"+x.np.start,cls:"k-warn",label:"Marketing fee due",title:`${x.v.name} owes ${money2(x.amt)} in closing partner marketing fees`,meta:`Due since ${fmtDate(x.np.start)}`,when:x.np.start,act:{a:"tab",tab:"partners",label:"Open"},auto:false,resurface:7,
    nudge:vt?{to:vt,subject:"Your Orbyt closing partner listing",text:`Hi ${vt.greet}, it's Ashleigh with Orbyt. A friendly reminder that the $${LISTING_FEE} monthly fee for your Orbyt closing partner listing is due. Let me know if you have any questions, or if you'd like to cancel. Thank you!`}:null}})}

/* invoicing: special offer payments, kept apart from job fees and listings */
function promoInvoicing(){const pays=promoPays().slice().sort((a,b)=>String(b.paid_at).localeCompare(String(a.paid_at)));if(!pays.length)return"";
  const monthStart=dayKey().slice(0,8)+"01",thisMonth=pays.filter(x=>String(x.paid_at).slice(0,10)>=monthStart).reduce((s,x)=>s+Number(x.amount||0),0);
  return `<section class="section"><h2>Special offer fees</h2><p class="small" style="margin:4px 0 12px">$20 per 30-day special offer. ${money2(thisMonth)} collected this month.</p>
    <div class="tablewrap"><table><thead><tr><th>Vendor</th><th>Offer runs</th><th>Paid</th><th>Amount</th></tr></thead><tbody>${pays.slice(0,S.allPp?999:8).map(x=>{const v=vendorById(x.vendor_id);return `<tr><td>${esc(v?v.name:"Vendor")}${x.note?`<div class="small">${esc(x.note)}</div>`:""}</td><td class="small">${fmtDate(x.period_start)} to ${fmtDate(x.period_end)}</td><td class="num">${fmtDate(String(x.paid_at).slice(0,10))}<div class="small">${x.source==="stripe"?"Card (Stripe)":"Recorded by you"}</div></td><td class="money">${money2(Number(x.amount||0))}</td></tr>`}).join("")}</tbody></table></div>
    ${pays.length>8?`<button class="linkbtn" data-act="allpp">${S.allPp?"Show fewer":"Show all "+pays.length}</button>`:""}</section>`}
document.addEventListener("click",e=>{const t=e.target.closest('[data-act="allpp"]');if(!t)return;e.preventDefault();e.stopImmediatePropagation();S.allPp=!S.allPp;render()},true);

/* Ashleigh: switch on card payments */
function billingSetupCard(){const cfg=(typeof settingVal==="function"?settingVal("billing"):null)||{},on=!!cfg.enabled,secret=!!cfg.secret_set_at;
  return `<details class="fold" style="margin-bottom:16px" ${S.billOpen||!on?"open":""}><summary><span class="foldtitle">Card payments (Stripe)</span><span class="pill ${on?"set":""}">${on?"On":"Off"}</span></summary><div class="foldbody">
    <p class="small" style="margin:0 0 8px">Closing partners add a card when they sign up and Stripe charges $${LISTING_FEE} a month after their launch offer. Vendors pay $20 by card to run a special offer. Payments land in your Stripe account and show up here automatically.</p>
    <ol class="small" style="margin:0 0 10px;padding-left:18px;line-height:1.7">
      <li>${secret?`Shared secret created ${esc(fmtDate(String(cfg.secret_set_at).slice(0,10)))}.`:"Create the shared secret below, then copy it."} ${S.canWrite?`<button class="linkbtn" data-act="billsecret">${secret?"Make a new one":"Create the shared secret"}</button>`:""}</li>
      <li>In Netlify, add the three settings from your runbook: STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET and ORBYT_BILLING_SECRET (the shared secret). Then redeploy.</li>
      <li>In Stripe, add the webhook for https://portal.orbytconnect.com/.netlify/functions/stripe-webhook and turn on the customer billing page.</li>
      <li>Turn on card payments here, then test with Stripe's test card 4242 4242 4242 4242.</li></ol>
    ${S.billSecret?`<div class="callout" style="margin:0 0 10px"><p class="small" style="margin:0 0 6px"><span class="strong">Your shared secret.</span> Paste it into Netlify as ORBYT_BILLING_SECRET now. It won't be shown again.</p>
      <div class="actions" style="align-items:center"><input type="text" id="bill-secret" readonly value="${esc(S.billSecret)}" style="flex:1;min-width:220px;font-family:monospace;font-size:13px"><button class="btn ghost sm" data-act="billcopy">Copy</button></div></div>`:""}
    ${S.canWrite?`<div class="actions"><button class="btn sm ${on?"ghost":""}" data-act="billtoggle" data-v="${on?"0":"1"}">${on?"Turn off card payments":"Turn on card payments"}</button></div>`:""}</div></details>`}
document.addEventListener("click",e=>{const t=e.target.closest('[data-act="billsecret"],[data-act="billtoggle"],[data-act="billcopy"]');if(!t)return;e.preventDefault();e.stopImmediatePropagation();S.billOpen=true;
  if(t.dataset.act==="billcopy"){const el=document.getElementById("bill-secret");if(el){el.select();try{navigator.clipboard.writeText(el.value);toast("Copied")}catch(_){document.execCommand("copy")}}return}
  if(t.dataset.act==="billsecret"){const b=new Uint8Array(32);crypto.getRandomValues(b);const sec=[...b].map(x=>x.toString(16).padStart(2,"0")).join("");
    if((settingVal("billing")||{}).secret_set_at&&!confirm("Make a new shared secret? You'll need to update ORBYT_BILLING_SECRET in Netlify too."))return;
    guard(async()=>{fail((await sb.rpc("billing_setup",{p_secret:sec})).error,"payments setup");S.billSecret=sec;await S.db.reload()},"Shared secret created. Copy it into Netlify.");return}
  const on=t.dataset.v==="1";
  guard(async()=>{const cur=settingVal("billing")||{};fail((await sb.from("settings").update({value:{...cur,enabled:on}}).eq("key","billing")).error,"payments");await S.db.reload()},on?"Card payments are on.":"Card payments are off.")},true);

document.addEventListener("click",e=>{const t=e.target.closest('[data-act="partnerhome"]');if(!t)return;e.preventDefault();e.stopImmediatePropagation();S.tab="tasks";S.openMsg=null;render()},true);
