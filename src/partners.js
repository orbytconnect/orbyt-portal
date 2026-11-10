
/* ---------- closing partners: lenders, title, escrow and homeowners insurance ----------
   They join free under the Closing Partner Terms, never pay per introduction or closing, and use a light intro flow
   (no bids, quotes, job fees, insurance tiers or special offers). */
const CLOSING=["Lender","Title","Escrow","Homeowners insurance"];
const CLOSING_HINT={"Lender":"Mortgage lenders and loan officers","Title":"Title companies and title officers","Escrow":"Escrow companies and officers","Homeowners insurance":"Home and hazard insurance"};
const isPartner=v=>!!v&&v.kind==="closing";
const introsFor=(pid,c)=>(Array.isArray(D.intros)?D.intros:[]).filter(i=>i.project_id===pid&&(!c||i.category===c));
const partnersFor=c=>S.vendors.filter(v=>isPartner(v)&&v.approved!==false&&vsv(v).includes(c));
const closingNote=`Orbyt isn't paid for these introductions, and your client is always free to choose any provider.`;

/* sign-up: portal.orbytconnect.com/join/partner */
function partnerSignupView(){
  const ck=(name,list,hint)=>`<div class="checks">${list.map((x,i)=>`<label><input type="checkbox" id="su-${name}-${i}" name="${name}" value="${esc(x)}">${esc(x)}${hint&&hint[x]?`<span class="small"> · ${esc(hint[x])}</span>`:""}</label>`).join("")}</div>`;
  return `<section class="auth one"><div class="authcard"><div class="eyebrow">For closing partners</div>
    <h1>Lenders, title, escrow and insurance</h1>
    <p class="small" style="margin:0">Join Orbyt's network of closing partners for San Diego agents. Founding partners are free, and Orbyt is never paid for introductions or closings.</p>
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
      <label class="field"><span>Agent references (2 to 3 names and numbers)</span><textarea id="su-refs" name="references"></textarea></label>
      <label class="field"><span>How did you hear about Orbyt? (optional)</span><input type="text" id="su-heard" name="heard"></label>
      <div class="grid"><label class="field"><span>Create a password (8+ characters)</span><input type="password" id="su-pass" name="password" autocomplete="new-password" required></label>
        <label class="field"><span>Type it again</span><input type="password" id="su-pass2" name="password2" autocomplete="new-password" required></label></div>${showPw("su-show")}
      <div class="reviewagree"><div class="eyebrow">Review and agree</div>
        <h2>Free for founding partners</h2><p class="small" style="margin:0">No sign-up fee, no monthly fee, and never a fee per introduction or closing. If Orbyt adds a paid membership later, it will be a flat fee, you'll get 30 days' notice, and you can choose not to continue.</p>
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
    [g("references").length<10,"Add 2 to 3 agent references, with names and phone numbers or emails.","#su-refs"],
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

/* the partner's dashboard: introductions, then their profile */
function partnerView(v){
  const mine=(Array.isArray(D.intros)?D.intros:[]).filter(i=>i.vendor_id===v.id).sort((a,b)=>String(b.introduced_at).localeCompare(String(a.introduced_at)));
  const open=mine.filter(i=>!i.reached_out_at),past=mine.filter(i=>i.reached_out_at);
  const card=i=>{const tel=String(i.agent_phone||"").replace(/[^\d+]/g,"");
    return `<div class="introcard"><div class="eyebrow">${esc(i.category)} · ${esc(ago(i.introduced_at))}</div>
      <div class="strong">${esc(i.agent_name||"Agent")}${i.brokerage?`<span class="small">, ${esc(i.brokerage)}</span>`:""}</div>
      <div class="small">${esc(i.address||"")}${i.area?" · "+esc(i.area):""}</div>${i.note?`<p class="note">${esc(i.note)}</p>`:""}
      <div class="actions">${tel?`<a class="btn ghost sm" href="tel:${esc(tel)}">Call ${esc(i.agent_phone)}</a>`:""}${i.agent_email?`<a class="btn ghost sm" href="mailto:${esc(i.agent_email)}">Email</a>`:""}
        ${i.reached_out_at?`<span class="pill set">Reached out ${esc(fmtDate(String(i.reached_out_at).slice(0,10)))}</span>`:S.canWrite?`<button class="btn sm" data-act="reachedout" data-id="${esc(i.id)}">I've reached out</button>`:""}</div></div>`};
  let h=`<section class="hello"><div><div class="eyebrow">Closing partner · ${esc(vsv(v).join(", "))}</div><h1>Hi, ${esc(v.name)}</h1>${v.approved===false?`<p class="banner" style="margin-top:10px">Thanks for joining. I'll check your license and references and reach out before your first introduction.</p>`:""}
    <p>When an agent in the network needs what you do, I'll introduce you here and by email. Reach out to the agent, then mark it below. You're a founding partner, so there's no fee.</p>${typeof availToggle==="function"?availToggle(v):""}</div>
    <div>${ratingHtml(v.id)}</div></section>`;
  if(typeof setupCard==="function"&&v.approved!==false)h+=setupCard();
  if(!Array.isArray(D.intros))return h+`<div class="emptystate"><h2>Almost ready</h2><p>Introductions switch on with the next Orbyt update. Check back soon.</p></div>`;
  h+=`<section class="section"><div class="sechead"><h2>New introductions</h2></div>${open.length?`<div class="introlist">${open.map(card).join("")}</div>`:`<p class="small">No new introductions right now. When an agent asks for ${esc(vsv(v).map(x=>x.toLowerCase()).join(" or "))} help, you'll get an email and it shows up here.</p>`}
    ${past.length?`<details class="fold" style="margin-top:12px"><summary><span class="foldtitle">Past introductions</span><span class="pill">${past.length}</span></summary><div class="foldbody"><div class="introlist">${past.map(card).join("")}</div></div></details>`:""}</section>`;
  if(v.approved===false)return h;
  const parts=[fold("myrev","Your reviews",myReviewsPill(v),"Read them, and copy them for your marketing",myReviewsCard(v),false),
    fold("port","Business overview and portfolio","","What agents see when I introduce you",portfolioCard(v),false)];
  if(typeof reviewInviteCard==="function"){const sent=typeof rrFor==="function"?rrFor(v.id):[];parts.push(fold("rr","Reviews from agents you've worked with",sent.length?`<span class="pill">${sent.length} invited</span>`:"","Invite agents you've worked with",reviewInviteCard(v),!!S.rrMore))}
  parts.push(fold("refer","Refer someone to Orbyt",refCountPill(),"A ready-made message to send",referralCard("partner"),false));
  return h+`<section class="section folds"><div class="sechead" style="margin-bottom:8px"><div><h2>Your profile</h2><span class="small">Tap one to open it.</span></div></div>${parts.join("")}</section>`}
document.addEventListener("click",e=>{const t=e.target.closest('[data-act="reachedout"]');if(!t)return;e.preventDefault();e.stopImmediatePropagation();
  guard(async()=>{fail((await sb.from("intros").update({reached_out_at:new Date().toISOString()}).eq("id",t.dataset.id)).error,"introduction");await S.db.reload()},"Marked. Thanks for reaching out.")},true);

/* projects: the closing partner section, for agents and for Ashleigh */
function closingPanel(p,mode){
  if(mode==="vendor"||!p)return"";const list=p.closing||[],isO=mode==="orbyt",ready=Array.isArray(D.intros);
  const left=CLOSING.filter(c=>!list.includes(c));
  if(!list.length&&!(mode==="agent"&&S.canWrite&&ready))return"";
  const rowFor=c=>{const ins=introsFor(p.id,c);
    const shown=ins.map(i=>{const v=vendorById(i.vendor_id);const tel=v?String(v.phone||"").replace(/[^\d+]/g,""):"";
      return `<div class="introrow"><div style="min-width:0">${v?`<button class="vlink strong" data-act="vcard" data-id="${esc(v.id)}">${esc(v.name)}</button>`:`<span class="strong">Partner</span>`}${v&&v.contactName?`<span class="small"> · ${esc(v.contactName)}</span>`:""}
        <div class="small">${[v&&v.phone?`<a href="tel:${esc(tel)}">${esc(v.phone)}</a>`:"",v&&v.email?`<a href="mailto:${esc(v.email)}">${esc(v.email)}</a>`:"",v?vendorDocs(v.id):""].filter(Boolean).join(" · ")}</div>
        ${i.note?`<div class="intronote">${isO?"Your note: ":"From Ashleigh: "}“${esc(i.note)}”</div>`:""}</div>
        <div class="small">Introduced ${esc(ago(i.introduced_at))}${i.reached_out_at?`<div><span class="pill set">They reached out</span></div>`:""}</div></div>`}).join("");
    let pick="";
    if(isO&&S.canWrite&&ready){const ps=partnersFor(c).filter(v=>!ins.some(i=>i.vendor_id===v.id)),ar=p.area;
      const sorted=ps.sort((a,b)=>((b.areas||[]).includes(ar)-(a.areas||[]).includes(ar))||(b.available!==false)-(a.available!==false)||a.name.localeCompare(b.name));
      const k=(p.id+c).replace(/[^a-z0-9]/gi,"");
      pick=sorted.length?`<form class="form inner introform" data-form="intro" data-p="${esc(p.id)}" data-c="${esc(c)}"><div class="grid">
          <label class="field"><span>${ins.length?"Introduce another":"Introduce"}</span><select id="in-v-${k}" name="vendorId">${sorted.map(v=>`<option value="${esc(v.id)}">${esc(v.name)}${(v.areas||[]).includes(ar)?" · works in "+esc(String(ar).split(" / ")[0]):""}${v.available===false?" (paused)":""}</option>`).join("")}</select></label>
          <label class="field"><span>Note for both of them (optional)</span><input type="text" id="in-n-${k}" name="note" placeholder="First-time buyer, wants to close by March"></label></div>
          <div class="actions"><button class="btn sm" type="submit">Introduce</button><span class="small">They each get an email with the other's contact details.</span></div></form>`
        :`<p class="small" style="margin:0">${ins.length?"No other approved":"No approved"} ${esc(c.toLowerCase())} partners yet.</p>`}
    return `<div class="closingrow"><div class="eyebrow">${esc(c)}</div>${shown||(isO?"":`<p class="small" style="margin:0">Ashleigh is lining up a ${esc(c.toLowerCase())} contact. You'll get an email when she makes the intro.</p>`)}${pick}</div>`};
  const add=mode==="agent"&&S.canWrite&&ready&&left.length?`<div class="actions"><label class="field" style="margin:0"><span>Add a closing partner</span><select id="cl-add-${esc(p.id)}">${left.map(c=>`<option value="${esc(c)}">${esc(c)}</option>`).join("")}</select></label><button class="btn ghost sm" data-act="addclosing" data-id="${esc(p.id)}">Ask for an intro</button></div>`:"";
  return `<section class="cat closingsec"><div class="cathead"><div><h3>Closing partners</h3><span class="small">${esc(closingNote)}</span></div></div>
    ${list.map(rowFor).join("")}${!list.length&&mode==="agent"?`<p class="small" style="margin:0">Need a lender, title, escrow or insurance contact for this client? Ask and I'll introduce someone from the network.</p>`:""}${add}</section>`}
document.addEventListener("submit",e=>{const f=e.target.closest('form[data-form="intro"]');if(!f)return;e.preventDefault();e.stopImmediatePropagation();
  const fd=new FormData(f),vid=String(fd.get("vendorId")||""),note=String(fd.get("note")||"").trim();if(!vid)return;
  guard(async()=>{fail((await sb.from("intros").insert({project_id:f.dataset.p,category:f.dataset.c,vendor_id:vid,note:note||null})).error,"introduction");await S.db.reload()},"Introduced. They each got an email.")},true);
document.addEventListener("click",e=>{const t=e.target.closest('[data-act="addclosing"]');if(!t)return;e.preventDefault();e.stopImmediatePropagation();
  const p=projById(t.dataset.id),sel=document.getElementById("cl-add-"+t.dataset.id);if(!p||!sel)return;const c=sel.value;
  guard(async()=>{fail((await sb.from("projects").update({closing:[...new Set([...(p.closing||[]),c])]}).eq("id",p.id)).error,"project");await S.db.reload()},`Asked. Ashleigh will introduce a ${c.toLowerCase()} contact.`)},true);
// Ashleigh's dashboard: closing partner requests waiting on an intro
function closingAlerts(){const A=[];if(!Array.isArray(D.intros))return A;
  for(const p of S.projects)for(const c of p.closing||[])if(!introsFor(p.id,c).length)
    A.push({id:"closing-"+p.id+"-"+c,cls:"k-warn",label:"Closing partner",title:`${firstName(p.agent)} needs ${c.toLowerCase()} for ${p.address}`,meta:(client(p)?client(p)+" · ":"")+ago(p.createdAt),when:p.createdAt,act:{a:"openmatch",id:p.id,label:"Introduce"}});
  return A}
