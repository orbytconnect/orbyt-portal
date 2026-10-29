/* =====================================================================
   Orbyt portal: live data layer (Supabase)
   The screens talk to S.db the same way they did in the prototype.
   This file translates those reads and saves into the Supabase tables.
   ===================================================================== */
const SB_URL="https://wqlsmrkmmbydqsuooshc.supabase.co";
const SB_KEY="sb_publishable_vmIhLd3MJNWkraNwDe4n_Q_DAMFLavF";
let sb=null;
// the portal home, whatever page address someone arrived on (like /join/vendor)
const portalHome=()=>location.origin+"/";
const D={};                       // raw rows, by table
const TABLES=["profiles","vendors","vendor_admin","vendor_private","vendor_notes","projects","project_private","project_admin",
  "project_members","default_shares","bids","invoices","reviews","favorites","task_checks","client_links","my_tasks","time_logs",
  "spend","contacts","market_requests","settings","vendor_agreements","terms_acceptances","review_requests"];
const nz=v=>v===""||v===undefined?null:v;
const camel=s=>s.replace(/_([a-z])/g,(m,c)=>c.toUpperCase());
const snake=s=>s.replace(/[A-Z]/g,c=>"_"+c.toLowerCase());
const byKey=(rows,k)=>{const m={};for(const r of rows||[])m[r[k]]=r;return m};
const isDeferred=x=>x&&typeof x==="object"&&x.__file;
const safeName=n=>String(n||"file").replace(/[^\w.\-]+/g,"_").slice(-80);
const fail=(error,what)=>{if(error){console.error(what,error);throw{message:friendlyDbError(error)}}};
function friendlyDbError(e){const m=String((e&&e.message)||e||"");
  if(/row-level security|permission denied/i.test(m))return"You don't have access to change that.";
  if(/duplicate key/i.test(m))return"That's already saved.";
  if(/Only Orbyt|has to come from|can't move|You can only|don't have access/i.test(m))return m.replace(/^.*?ERROR:\s*/,"");
  return"That didn't save. Check your connection and try again."}

async function fetchAll(t){
  // review requests come through a function so the private review links never reach the page
  if(t==="review_requests"){if(!S.uid)return undefined;const{data,error}=await sb.rpc("review_requests_list");return error?undefined:(data||[])}
  let out=[],from=0;
  for(;;){const{data,error}=await sb.from(t).select("*").range(from,from+999);
    if(error){console.error("load "+t,error);return t==="terms_acceptances"?undefined:out} // no terms step until update 8 is in
    out=out.concat(data||[]);if(!data||data.length<1000)return out;from+=1000}
}

/* ---------- shaping rows for the screens ---------- */
function appVendors(){const A=byKey(D.vendor_admin,"vendor_id"),P=byKey(D.vendor_private,"vendor_id");
  return(D.vendors||[]).map(v=>{const a=A[v.id]||{},p=P[v.id]||{},coi=(p.insurance_paths||[]).map(x=>"vendor-files:"+x);
    return{id:v.id,userId:v.user_id,name:v.name,contactName:v.contact_name||"",email:v.email||"",phone:v.phone||"",web:v.website||"",
      services:v.services||[],category:(v.services||[])[0]||"",areas:normAreas(v.areas||[]),areaNote:v.area_note||"",years:v.years_in_business||"",
      team:v.team_size||"",leadTime:v.lead_time||"",worksWithAgents:v.works_with_agents||"",portfolioUrl:v.portfolio_url||"",
      photoIds:(v.photo_paths||[]).map(x=>"vendor-photos:"+x),instagram:v.instagram||"",portfolioPdf:v.portfolio_pdf?"vendor-photos:"+v.portfolio_pdf:"",portfolioPdfPath:v.portfolio_pdf||"",portfolioPdfName:v.portfolio_pdf_name||"",available:v.available!==false,source:v.source||"",createdAt:v.created_at,
      approved:a.vendor_id?!!a.approved:(kind()==="orbyt"?false:true),featured:!!a.featured,licensed:!!a.licensed,insured:!!a.insured,repeatJobs:a.repeat_jobs||0,approvedAt:a.approved_at,
      pricing:p.pricing||{},references:p.references_text||"",heard:p.heard_about||"",signupNotes:p.signup_notes||"",promoInterest:p.promo_interest||"",coiIds:coi,coiId:coi[0]||"",coiUrl:p.coi_url||"",insurance:p.insurance||{},insPaths:p.insurance_paths||[],
      legalName:p.legal_name||"",dba:p.dba||"",businessType:p.business_type||"",signerTitle:p.signer_title||"",marketingOptOut:!!p.marketing_opt_out,
      insVerifiedPath:a.insurance_verified_path||"",insVerifiedAt:a.insurance_verified_at||"",insExpires:a.insurance_expires||"",insNote:a.insurance_note||"",insNoteAt:a.insurance_note_at||""}})}
function appProjects(){const PP=byKey(D.project_private,"project_id"),PA=byKey(D.project_admin,"project_id");
  return(D.projects||[]).map(p=>{const pp=PP[p.id]||{},pa=PA[p.id]||{};
    return{id:p.id,agent:p.agent_name,agentId:p.agent_id,agentEmail:p.agent_email||"",agentPhone:p.agent_phone||"",brokerage:p.brokerage||"",
      address:p.address,area:normArea(p.area||""),clientType:p.client_type,targetDate:p.target_date||"",categories:p.categories||[],notes:p.notes||"",
      addedServices:p.added_services||{},listed:!!p.listed,listedAt:p.listed_at,workOrder:p.work_order||null,source:p.source||"",createdBy:p.created_by||"",createdAt:p.created_at,
      client:pp.client_name||"",budget:pp.budget||"",listPrice:pp.list_price==null?null:Number(pp.list_price),sqft:p.sqft||null,pmInterest:pp.pm_interest||"",optionRequests:pp.option_requests||{},
      pm:!!pa.pm,pmInvoice:pa.pm_invoice||null,completed:!!pa.completed,completedAt:pa.completed_at,
      members:(D.project_members||[]).filter(m=>m.project_id===p.id).sort((a,b)=>String(a.added_at).localeCompare(String(b.added_at)))
        .map(m=>({id:m.id,name:m.name,email:m.email,role:m.role,notify:!!m.notify,fromDefault:!!m.from_default,userId:m.user_id,addedAt:m.added_at}))}})}
const BID_COLS=["project_id","category","vendor_id","vendor_name","status","introduced_at","introduced_by","intro_note","avail_checked","suggest_rank",
  "requested_at","amount","days","note","quote_path","quote_name","quote_is_image","submitted_at","rev","prev_amount","change_note","changes_at","changes_by",
  "chosen_at","confirmed_at","start_date","confirm_note","decline_reason","decline_stage","decline_note","declined_at","step_agreement","step_paid","done",
  "done_at","done_by","available_from","final_amount","final_note","final_reported_by","final_reported_at","final_confirmed_at","final_dispute","fee_type"];
function appBids(){const INV=byKey(D.invoices,"bid_id");
  return(D.bids||[]).map(b=>{const o={id:b.id};for(const c of BID_COLS)o[camel(c)]=b[c];
    o.vendorId=b.vendor_id||"";o.vendorName=b.vendor_name||"";o.amount=b.amount==null?null:Number(b.amount);o.finalAmount=b.final_amount==null?null:Number(b.final_amount);
    o.prevAmount=b.prev_amount==null?null:Number(b.prev_amount);o.pdfId=b.quote_path?"quotes:"+b.quote_path:"";o.pdfName=b.quote_name||"";o.pdfIsImage=!!b.quote_is_image;
    o.steps={agreement:!!b.step_agreement,paid:!!b.step_paid};o.startDate=b.start_date||"";o.availableFrom=b.available_from||"";o.feeType=b.fee_type||"";
    const i=INV[b.id];if(i)o.invoice={status:i.status,number:i.number||"",at:i.invoiced_at,paidAt:i.paid_at};
    for(const k of["changeNote","declineNote","declineReason","note","introNote","confirmNote","finalNote"])if(o[k]==null)o[k]="";
    return o})}
function appReviews(){return(D.reviews||[]).map(r=>({id:r.id,bidId:r.bid_id,vendorId:r.vendor_id,projectId:r.project_id,agent:r.agent_name||"",agentId:r.agent_id,
  rating:r.rating,comment:r.comment||"",approved:!!r.approved,createdAt:r.created_at,source:r.source||"booked",brokerage:r.reviewer_brokerage||"",
  reviewerEmail:r.reviewer_email||"",workWhen:r.work_when||""}))}
const settingVal=k=>((D.settings||[]).find(x=>x.key===k)||{}).value;
function myAgentName(){return S.me?(S.me.full_name||S.me.email):""}
function appCollection(n){
  switch(n){
    case"vendors":return appVendors();case"projects":return appProjects();case"bids":return appBids();case"reviews":return appReviews();
    case"mytasks":return(D.my_tasks||[]).map(m=>({id:m.id,title:m.title,due:m.due||"",projectId:m.project_id||"",done:!!m.done,doneAt:m.done_at,createdAt:m.created_at}));
    case"taskstate":{const done={},nudged={};for(const r of D.task_checks||[]){if(r.user_id!==S.uid)continue;if(r.checked_at)done[r.task_id]=r.checked_at;if(r.nudged_at)nudged[r.task_id]=r.nudged_at}
      return[{id:roleKey(),done,nudged}]}
    case"favorites":return[{id:favKey(myAgentName()),ids:(D.favorites||[]).filter(f=>f.user_id===S.uid).map(f=>f.vendor_id)}];
    case"settings":return[{id:"main",...(settingVal("main")||{})}];
    case"teams":return[{id:teamKey(myAgentName()),agent:myAgentName(),members:(D.default_shares||[]).filter(d=>d.owner_id===S.uid)
      .map(d=>({id:d.id,name:d.name,email:d.email,role:d.role,notify:!!d.notify}))}];
    case"signups":return(D.profiles||[]).filter(p=>p.role==="agent"&&p.id!==S.uid&&(p.status==="pending"||ageDays(p.approved_at||p.created_at)<30))
      .map(p=>({id:p.id,kind:"agent",name:p.full_name||p.email,email:p.email,phone:p.phone||"",brokerage:p.brokerage||"",areas:p.areas||[],
        status:p.status==="active"?"approved":p.status,createdAt:p.created_at}));
    case"markets":return(D.market_requests||[]).map(m=>({id:m.id,area:m.area,role:m.role||"agent",name:m.name||"",email:m.email||"",company:m.company||"",note:m.note||"",source:m.source||"",createdAt:m.created_at}));
    case"private/timelog/entries":return(D.time_logs||[]).map(t=>({id:t.id,date:t.logged_on,hours:Number(t.hours),type:t.kind,projectId:t.project_id||"",note:t.note||"",createdAt:t.created_at}));
    case"private/spend/entries":return(D.spend||[]).map(t=>({id:t.id,date:t.spent_on,amount:Number(t.amount),side:t.side||t.category||"",channel:t.channel||t.note||"",createdAt:t.created_at}));
    case"private/notes/vendors":{const g={};for(const n of D.vendor_notes||[])(g[n.vendor_id]=g[n.vendor_id]||[]).push({id:n.id,at:n.created_at,text:n.body});
      return Object.entries(g).map(([id,entries])=>({id,entries:entries.sort((a,b)=>String(b.at).localeCompare(String(a.at)))}))}
    case"private/contacts/agents":case"private/contacts/vendors":{const side=n.endsWith("agents")?"agent":"vendor",rows=(D.contacts||[]).filter(c=>c.side===side);
      return rows.length?[{id:side+"-all",rows:rows.map(c=>({n:c.name||"",e:c.email||"",c:c.company||"",a:c.area||""})),uploadedAt:rows.map(c=>c.imported_at).sort().pop()}]:[]}
  }
  return[];
}

/* ---------- the S.db stand-in ---------- */
function makeSupabaseDb(){
  const colL={},docL={};
  const snap=n=>({docs:appCollection(n).map(d=>({id:d.id,exists:true,data:()=>{const x={...d};delete x.id;return x}}))});
  const docSnap=p=>{if(p==="private/config"){const v=settingVal("config");return{id:"config",exists:!!v,data:()=>({...(v||{})})}}return{id:p,exists:false,data:()=>({})}};
  function notify(){for(const[n,fns]of Object.entries(colL)){const s=snap(n);fns.forEach(fn=>fn(s))}for(const[p,fns]of Object.entries(docL)){const s=docSnap(p);fns.forEach(fn=>fn(s))}}
  async function reload(){const res=await Promise.all(TABLES.map(fetchAll));TABLES.forEach((t,i)=>D[t]=res[i]);notify()}
  const split=p=>{const i=p.lastIndexOf("/");return[p.slice(0,i),p.slice(i+1)]};
  const ref=p=>{const[c,id]=split(p);return{id,
    set:async d=>{await write(c,id,"set",d);await reload()},
    update:async d=>{await write(c,id,"update",d);await reload()},
    delete:async()=>{await write(c,id,"delete");await reload()},
    onSnapshot:fn=>{(docL[p]=docL[p]||[]).push(fn);return()=>{}}}};
  return{
    collection:c=>({onSnapshot:fn=>{(colL[c]=colL[c]||[]).push(fn);return()=>{}},
      add:async d=>{const id=await write(c,null,"add",d);await reload();return{id}},doc:id=>ref(c+"/"+id)}),
    doc:ref,reload,_has:()=>true};
}

/* ---------- uploads ---------- */
const liveAssets={upload:async file=>({id:{__file:file}})};
async function putFile(bucket,folder,file){
  const path=folder+"/"+Date.now().toString(36)+"-"+safeName(file.name);
  const{error}=await sb.storage.from(bucket).upload(path,file,{contentType:file.type||undefined,upsert:false});
  fail(error,"upload");return path;
}
const SIGNED={},SIGNING={};
function signedUrl(id){if(!id||typeof id!=="string")return"";if(SIGNED[id])return SIGNED[id];
  if(!SIGNING[id]){SIGNING[id]=true;const i=id.indexOf(":"),bucket=id.slice(0,i),path=id.slice(i+1);
    sb.storage.from(bucket).createSignedUrl(path,3600).then(({data,error})=>{if(!error&&data){SIGNED[id]=data.signedUrl;schedule()}})}
  return""}
function blobHref(id){return signedUrl(id)||"#"}

/* ---------- saves: screen fields to table columns ---------- */
const pick=(d,map)=>{const o={};for(const[k,col]of Object.entries(map))if(k in d)o[col]=typeof d[k]==="string"&&col.match(/_(date|at)$|^target_date$|^due$/)?nz(d[k]):d[k];return o};
const VENDOR_MAP={name:"name",contactName:"contact_name",email:"email",phone:"phone",web:"website",services:"services",areas:"areas",areaNote:"area_note",
  years:"years_in_business",team:"team_size",leadTime:"lead_time",worksWithAgents:"works_with_agents",portfolioUrl:"portfolio_url",available:"available",source:"source"};
const VADMIN_MAP={approved:"approved",featured:"featured",licensed:"licensed",insured:"insured",repeatJobs:"repeat_jobs",approvedAt:"approved_at"};
const VPRIV_MAP={pricing:"pricing",references:"references_text",heard:"heard_about",signupNotes:"signup_notes",promoInterest:"promo_interest",coiUrl:"coi_url"};
const PROJ_MAP={sqft:"sqft",agent:"agent_name",agentEmail:"agent_email",agentPhone:"agent_phone",brokerage:"brokerage",address:"address",area:"area",clientType:"client_type",
  targetDate:"target_date",categories:"categories",notes:"notes",addedServices:"added_services",listed:"listed",listedAt:"listed_at",workOrder:"work_order",source:"source",createdBy:"created_by"};
const PPRIV_MAP={listPrice:"list_price",client:"client_name",budget:"budget",pmInterest:"pm_interest",optionRequests:"option_requests"};
const PADMIN_MAP={pm:"pm",pmInvoice:"pm_invoice",completed:"completed",completedAt:"completed_at"};
const stripStore=p=>String(p||"").replace(/^[a-z-]+:/,"");

async function write(c,id,op,d){
  d=d||{};
  if(c==="bids"){
    if(op==="delete"){fail((await sb.from("bids").delete().eq("id",id)).error,"bid");return}
    const row={};
    for(const[k,v]of Object.entries(d)){
      if(k==="pdfId"){if(!isDeferred(v))row.quote_path=v?stripStore(v):null;continue}
      if(k==="pdfName"){row.quote_name=v||null;continue}
      if(k==="pdfIsImage"){row.quote_is_image=!!v;continue}
      if(k==="steps"){row.step_agreement=!!(v&&v.agreement);row.step_paid=!!(v&&v.paid);continue}
      if(k==="invoice"||k==="createdAt")continue;
      const col=snake(k);if(BID_COLS.includes(col))row[col]=(col==="vendor_id"||col==="start_date"||col==="available_from"||col==="fee_type")?nz(v):v;
    }
    let bidId=id;
    if(op==="add"){const r=await sb.from("bids").insert(row).select("id").single();fail(r.error,"bid");bidId=r.data.id}
    else if(Object.keys(row).length)fail((await sb.from("bids").update(row).eq("id",id)).error,"bid");
    if(isDeferred(d.pdfId)){const f=d.pdfId.__file,path=await putFile("quotes",bidId,f);
      fail((await sb.from("bids").update({quote_path:path,quote_name:d.pdfName||f.name,quote_is_image:/^image\//.test(f.type||"")}).eq("id",bidId)).error,"bid file")}
    if("invoice"in d){const v=d.invoice||{};
      if(!v.status)fail((await sb.from("invoices").delete().eq("bid_id",bidId)).error,"invoice");
      else{const cur=(D.invoices||[]).find(i=>i.bid_id===bidId)||{};
        fail((await sb.from("invoices").upsert({bid_id:bidId,status:v.status,number:v.number??cur.number??null,invoiced_at:v.at??cur.invoiced_at??null,
          paid_at:v.paidAt??(v.status==="paid"?new Date().toISOString():null)})).error,"invoice")}}
    return bidId;
  }
  if(c==="projects"){
    if(op==="delete"){fail((await sb.from("projects").delete().eq("id",id)).error,"project");return}
    const main=pick(d,PROJ_MAP),priv=pick(d,PPRIV_MAP),adm=pick(d,PADMIN_MAP);
    if("budget"in priv)priv.budget=nz(priv.budget);
    let pid=id;
    if(op==="add"){
      if(kind()==="agent")main.agent_id=S.uid;
      else{const ag=(D.profiles||[]).find(x=>x.email&&d.agentEmail&&x.email.toLowerCase()===String(d.agentEmail).toLowerCase());main.agent_id=ag?ag.id:null}
      const r=await sb.from("projects").insert(main).select("id").single();fail(r.error,"project");pid=r.data.id;
    }else if(Object.keys(main).length)fail((await sb.from("projects").update(main).eq("id",pid)).error,"project");
    if(Object.keys(priv).length)fail((await sb.from("project_private").upsert({project_id:pid,...priv})).error,"project details");
    if(Object.keys(adm).length&&kind()==="orbyt")fail((await sb.from("project_admin").upsert({project_id:pid,...adm})).error,"project admin");
    if(Array.isArray(d.members)){
      const cur=(D.project_members||[]).filter(m=>m.project_id===pid),want=d.members,em=x=>String(x.email||"").toLowerCase();
      for(const m of cur)if(!want.some(w=>em(w)===em(m)))fail((await sb.from("project_members").delete().eq("id",m.id)).error,"sharing");
      for(const w of want){const m=cur.find(x=>em(x)===em(w));
        if(!m)fail((await sb.from("project_members").insert({project_id:pid,name:w.name,email:em(w),role:w.role||"Team member",notify:!!w.notify,from_default:!!w.fromDefault,added_by:S.uid})).error,"sharing");
        else if(!!m.notify!==!!w.notify||m.role!==w.role)fail((await sb.from("project_members").update({notify:!!w.notify,role:w.role}).eq("id",m.id)).error,"sharing")}
    }
    return pid;
  }
  if(c==="vendors"){
    if(op==="delete"){fail((await sb.from("vendors").delete().eq("id",id)).error,"vendor");return}
    const main=pick(d,VENDOR_MAP),adm=pick(d,VADMIN_MAP),priv=pick(d,VPRIV_MAP);
    if(d.category&&!d.services)main.services=[d.category];
    let vid=id;
    if(op==="add"){const r=await sb.from("vendors").insert(main).select("id").single();fail(r.error,"vendor");vid=r.data.id;
      fail((await sb.from("vendor_admin").upsert({vendor_id:vid,...adm})).error,"vendor");fail((await sb.from("vendor_private").upsert({vendor_id:vid,...priv})).error,"vendor")}
    else{if(Object.keys(main).length)fail((await sb.from("vendors").update(main).eq("id",vid)).error,"vendor");
      if(Object.keys(adm).length)fail((await sb.from("vendor_admin").upsert({vendor_id:vid,...adm})).error,"vendor");
      if(Object.keys(priv).length)fail((kind()==="vendor"?await sb.from("vendor_private").update(priv).eq("vendor_id",vid):await sb.from("vendor_private").upsert({vendor_id:vid,...priv})).error,"vendor");
      const v=(D.vendors||[]).find(x=>x.id===vid);
      if(d.approved===true&&v&&v.user_id)fail((await sb.rpc("admin_set_user_status",{p_user:v.user_id,p_status:"active"})).error,"approve")}
    const cois=[...(d.coiIds||[]),...(d.coiId?[d.coiId]:[])],photos=d.photoIds||[];
    if(cois.some(isDeferred)||photos.some(isDeferred)){
      const ins=[],ph=[];for(const x of cois)ins.push(isDeferred(x)?await putFile("vendor-files",vid,x.__file):stripStore(x));
      for(const x of photos)ph.push(isDeferred(x)?await putFile("vendor-photos",vid,x.__file):stripStore(x));
      if(cois.length)fail((await sb.from("vendor_private").upsert({vendor_id:vid,insurance_paths:[...new Set(ins.filter(Boolean))]})).error,"vendor files");
      if(photos.length)fail((await sb.from("vendors").update({photo_paths:ph.filter(Boolean)}).eq("id",vid)).error,"vendor photos")}
    return vid;
  }
  if(c==="reviews"){
    if(op==="add"){const r=await sb.from("reviews").insert({bid_id:d.bidId,vendor_id:d.vendorId,project_id:d.projectId,agent_id:kind()==="agent"?S.uid:null,
      agent_name:d.agent||myAgentName(),rating:d.rating,comment:d.comment||null,approved:kind()==="orbyt"?!!d.approved:false}).select("id").single();fail(r.error,"review");return r.data.id}
    if(op==="delete"){fail((await sb.from("reviews").delete().eq("id",id)).error,"review");return}
    fail((await sb.from("reviews").update({approved:!!d.approved}).eq("id",id)).error,"review");return id;
  }
  if(c==="mytasks"){
    if(op==="delete"){fail((await sb.from("my_tasks").delete().eq("id",id)).error,"task");return}
    const row=pick(d,{title:"title",due:"due",projectId:"project_id",done:"done",doneAt:"done_at"});if("project_id"in row)row.project_id=nz(row.project_id);if("due"in row)row.due=nz(row.due);
    if(op==="add"){const r=await sb.from("my_tasks").insert(row).select("id").single();fail(r.error,"task");return r.data.id}
    fail((await sb.from("my_tasks").update(row).eq("id",id)).error,"task");return id;
  }
  if(c==="markets"){
    if(op==="add"){const r=await sb.from("market_requests").insert({user_id:S.uid,area:d.area,role:d.role||null,name:d.name||null,email:d.email||null,company:d.company||null,
      note:d.note||null,source:d.source||null,created_at:d.createdAt||undefined}).select("id").single();fail(r.error,"area request");return r.data.id}
    if(op==="delete"){fail((await sb.from("market_requests").delete().eq("id",id)).error,"area request");return}
    return id;
  }
  if(c==="private/timelog/entries"){
    if(op==="delete"){fail((await sb.from("time_logs").delete().eq("id",id)).error,"time");return}
    const r=await sb.from("time_logs").insert({project_id:nz(d.projectId),kind:d.type||"matching",hours:Number(d.hours),note:d.note||null,logged_on:d.date||undefined}).select("id").single();
    fail(r.error,"time");return r.data.id;
  }
  if(c==="private/spend/entries"){
    if(op==="delete"){fail((await sb.from("spend").delete().eq("id",id)).error,"spend");return}
    const r=await sb.from("spend").insert({spent_on:d.date||undefined,amount:Number(d.amount),side:d.side||null,channel:d.channel||null}).select("id").single();
    fail(r.error,"spend");return r.data.id;
  }
  if(c==="private"&&id==="config"){fail((await sb.from("settings").upsert({key:"config",value:d,is_public:false})).error,"settings");return}
  if(c==="settings"){fail((await sb.from("settings").upsert({key:id,value:d,is_public:id==="main"})).error,"settings");return}
  if(c==="private/notes/vendors"){
    const cur=(D.vendor_notes||[]).filter(n=>n.vendor_id===id),want=d.entries||[];
    for(const n of cur)if(!want.some(w=>w.id===n.id))fail((await sb.from("vendor_notes").delete().eq("id",n.id)).error,"note");
    for(const w of want)if(!w.id)fail((await sb.from("vendor_notes").insert({vendor_id:id,body:w.text,created_at:w.at||undefined})).error,"note");
    return;
  }
  if(c==="private/contacts/agents"||c==="private/contacts/vendors"){const side=c.endsWith("agents")?"agent":"vendor";
    if(op==="delete"){fail((await sb.from("contacts").delete().eq("side",side)).error,"contacts");return}
    const rows=(d.rows||[]).map(r=>({side,name:r.n||null,email:r.e||null,company:r.c||null,area:r.a||null,source:"CSV upload"}));
    for(let i=0;i<rows.length;i+=500)fail((await sb.from("contacts").insert(rows.slice(i,i+500))).error,"contacts");return}
  if(c==="taskstate"){const want={};for(const[t,at]of Object.entries(d.done||{}))(want[t]=want[t]||{}).checked_at=at;for(const[t,at]of Object.entries(d.nudged||{}))(want[t]=want[t]||{}).nudged_at=at;
    const cur=(D.task_checks||[]).filter(r=>r.user_id===S.uid);
    for(const r of cur)if(!want[r.task_id])fail((await sb.from("task_checks").delete().eq("user_id",S.uid).eq("task_id",r.task_id)).error,"task");
    const rows=Object.entries(want).map(([task_id,v])=>({user_id:S.uid,task_id,checked_at:v.checked_at||null,nudged_at:v.nudged_at||null}));
    if(rows.length)fail((await sb.from("task_checks").upsert(rows)).error,"task");return}
  if(c==="favorites"){const want=new Set(d.ids||[]),cur=(D.favorites||[]).filter(f=>f.user_id===S.uid);
    for(const f of cur)if(!want.has(f.vendor_id))fail((await sb.from("favorites").delete().eq("user_id",S.uid).eq("vendor_id",f.vendor_id)).error,"favorite");
    for(const vid of want)if(!cur.some(f=>f.vendor_id===vid))fail((await sb.from("favorites").insert({user_id:S.uid,vendor_id:vid})).error,"favorite");return}
  if(c==="teams"){const cur=(D.default_shares||[]).filter(x=>x.owner_id===S.uid),want=d.members||[],em=x=>String(x.email||"").toLowerCase();
    for(const x of cur)if(!want.some(w=>em(w)===em(x)))fail((await sb.from("default_shares").delete().eq("id",x.id)).error,"sharing");
    for(const w of want){const x=cur.find(y=>em(y)===em(w));
      if(!x)fail((await sb.from("default_shares").insert({owner_id:S.uid,name:w.name,email:em(w),role:w.role,notify:!!w.notify})).error,"sharing");
      else if(!!x.notify!==!!w.notify||x.role!==w.role)fail((await sb.from("default_shares").update({notify:!!w.notify,role:w.role}).eq("id",x.id)).error,"sharing")}
    return}
  if(c==="signups"){if(d.status==="approved")fail((await sb.rpc("admin_set_user_status",{p_user:id,p_status:"active"})).error,"approve");return}
  console.warn("Not saved: unknown collection",c,op);
}

/* ---------- sign in, sign up, approval ---------- */
function friendlyAuthError(e){const m=String((e&&e.message)||e||"");
  if(/invalid login/i.test(m))return"That email and password don't match. Try again, or reset your password.";
  if(/not confirmed/i.test(m))return"Confirm your email first. Check your inbox for the link from Orbyt.";
  if(/already registered|already exists/i.test(m))return"That email already has an account. Try signing in instead.";
  if(/password/i.test(m)&&/least|short|weak/i.test(m))return"Use a password with at least 8 characters.";
  if(/rate limit|too many/i.test(m))return"Too many tries. Wait a minute, then try again.";
  return m||"Something went wrong. Try again."}
function protoBanner(){return""}
function accountFor(){return null}
function agentProfile(name){
  if(S.me&&(name===myAgentName()))return{name,email:S.me.email||"",phone:S.me.phone||"",brokerage:S.me.brokerage||"",areas:normAreas(S.me.areas||[])};
  const p=S.projects.find(x=>x.agent===name&&(x.agentEmail||x.agentPhone))||{};return{name,email:p.agentEmail||"",phone:p.agentPhone||"",brokerage:p.brokerage||"",areas:[]};
}
function isOnProject(p,agent){return kind()==="agent"?true:p.agent===agent}
const authMsg=()=>`<p class="small warntext autherr" role="alert" style="margin:0" ${S.authErr?"":"hidden"}>${esc(S.authErr||"")}</p>`;
const showPw=id=>`<label class="checkrow"><input type="checkbox" id="${id}" data-showpw> Show password</label>`;
function authView(){
  const m=S.authMode||"signin",err=authMsg();
  if(!S.authReady)return `<div class="emptystate" style="margin-top:28px"><h2>Loading</h2><p>Checking your sign-in.</p></div>`;
  const card=(eyebrow,title,body)=>`<section class="auth one"><div class="authcard"><div class="eyebrow">${eyebrow}</div><h1>${title}</h1>${body}</div></section>`;
  if(m==="pending")return card("Almost there",`Thanks${S.pendingName?", "+esc(S.pendingName):""}`,`<p>I review every new account before the first introduction, usually within a day. You'll get an email as soon as you're in.</p><p class="small">Ashleigh at Orbyt</p>
    <div class="actions"><button class="btn ghost" data-act="signout">Sign out</button></div>`);
  if(m==="declined")return card("Account","This account isn't active",`<p>Reach out to ashleigh@orbytconnect.com with any questions.</p><div class="actions"><button class="btn ghost" data-act="signout">Sign out</button></div>`);
  if(m==="checkemail")return card("One more step","Check your email",`<p>I sent a confirmation link to <span class="strong">${esc(S.pendingEmail||"your inbox")}</span>. Click it, then sign in here.</p>
    <div class="actions"><button class="btn" data-act="authmode" data-m="signin">Back to sign in</button></div>`);
  if(m==="forgot")return card("Password","Reset your password",`<form class="authform" data-proto="forgot" novalidate>
      <label class="field"><span>Email</span><input type="email" id="fp-email" name="email" autocomplete="email" required></label>${err}
      <p class="small authnote" role="status" style="margin:0" ${S.authNote?"":"hidden"}>${esc(S.authNote||"")}</p>
      <div class="actions"><button class="btn" type="submit">Email me a reset link</button><button class="btn ghost" type="button" data-act="authmode" data-m="signin">Back to sign in</button></div></form>`);
  if(m==="newpass")return card("Password","Choose a new password",`<form class="authform" data-proto="newpass" novalidate>
      <label class="field"><span>New password (8+ characters)</span><input type="password" id="np-pass" name="password" autocomplete="new-password" required></label>
      <label class="field"><span>Type it again</span><input type="password" id="np-pass2" name="password2" autocomplete="new-password" required></label>${showPw("np-show")}${err}
      <button class="btn" type="submit">Save password</button></form>`);
  if(m==="agent"||m==="vendor")return signupView(m);
  if(m==="join")return card("Join Orbyt","How will you use Orbyt?",`<p class="small" style="margin:0">Pick one to get started. Every match is made by a real person.</p>
    <div class="demolist"><button class="demoacct" data-act="authmode" data-m="agent"><span class="strong">I'm an agent</span><span class="small">The right team for every listing</span></button>
      <button class="demoacct" data-act="authmode" data-m="vendor"><span class="strong">I'm a vendor partner</span><span class="small">More of the work you're good at, less chasing it</span></button></div>
    <p class="small" style="margin:0">Already have an account? <button class="linkbtn" data-act="authmode" data-m="signin">Sign in</button></p>`);
  return `<section class="auth"><div class="authcard"><div class="eyebrow">Welcome back</div><h1>Sign in to Orbyt</h1>
      <form class="authform" data-proto="signin" novalidate>
        <label class="field"><span>Email</span><input type="email" id="si-email" name="email" autocomplete="email" required placeholder="you@brokerage.com"></label>
        <label class="field"><span>Password</span><input type="password" id="si-pass" name="password" autocomplete="current-password" required></label>${showPw("si-show")}${err}
        <button class="btn" type="submit">Sign in</button>
        <button class="linkbtn" type="button" data-act="authmode" data-m="forgot">Forgot your password?</button></form></div>
    <div class="authcard demo"><div class="eyebrow">New to Orbyt?</div><h2>We know people.</h2>
      <p class="small" style="margin:0">Agents get vendors matched to each home. Vendor partners get warm intros to agents who need their work. Every match is made by a real person.</p>
      <div class="demolist"><button class="demoacct" data-act="authmode" data-m="agent"><span class="strong">Join as an agent</span><span class="small">The right team for every listing</span></button>
        <button class="demoacct" data-act="authmode" data-m="vendor"><span class="strong">Join as a vendor partner</span><span class="small">More of the work you're good at</span></button></div></div></section>`;
}
function signupView(m){
  const ck=(name,list)=>`<div class="checks">${list.map((x,i)=>`<label><input type="checkbox" id="su-${name}-${i}" name="${name}" value="${esc(x)}">${esc(x)}</label>`).join("")}</div>`;
  const sel=(id,label,list)=>`<label class="field"><span>${label}</span><select id="su-${id}" name="${id}"><option value="">Choose one</option>${list.map(x=>`<option>${esc(x)}</option>`).join("")}</select></label>`;
  return `<section class="auth one"><div class="authcard"><div class="eyebrow">${m==="agent"?"For agents":"For vendor partners"}</div>
    <h1>${m==="agent"?"The right team for every listing":"More of the work you're good at"}</h1>
    <p class="small" style="margin:0">${m==="agent"?"Tell me where you list and I'll start lining up vendors matched to your homes.":"I'll check your references and reach out before your first introduction."}</p>
    <form class="authform" data-proto="signup" data-kind="${m}" novalidate>
      ${m==="vendor"?`<label class="field"><span>Company name</span><input type="text" id="su-company" name="company" required></label>`:""}
      <div class="grid"><label class="field"><span>First name</span><input type="text" id="su-first" name="first" required></label>
        <label class="field"><span>Last name</span><input type="text" id="su-last" name="last" required></label>
        <label class="field"><span>Email</span><input type="email" id="su-email" name="email" required></label>
        <label class="field"><span>Mobile phone</span><input type="tel" id="su-phone" name="phone"></label>
        ${m==="agent"?`<label class="field"><span>Brokerage</span><input type="text" id="su-brokerage" name="brokerage"></label>`:`<label class="field"><span>Website</span><input type="text" id="su-web" name="web" placeholder="yourbusiness.com"></label>`}</div>
      ${m==="vendor"?`<div class="grid"><label class="field"><span>Instagram (optional)</span><input type="text" id="su-ig" name="instagram" placeholder="@yourbusiness"></label>
        <label class="field"><span>Portfolio link (optional)</span><input type="text" id="su-port" name="portfolio" placeholder="Google Drive, Houzz, Dropbox or anywhere"></label></div>
        <p class="small" style="margin:0">Have a portfolio PDF? You can upload it from your dashboard once you're approved.</p>`:""}
      ${m==="vendor"?`<div class="field"><span>Services you offer</span>${ck("svc",CATS)}${moreChecks("svc","su-ms")}</div>
        <label class="field"><span>Anything else? (optional, separate with commas)</span><input type="text" id="su-othersvc" name="othersvc" placeholder="Anything not listed above"></label>
        <p class="small insnote" id="su-insnote" aria-live="polite" hidden></p>`:""}
      <div class="field"><span>${m==="agent"?"Where do you list homes?":"Where do you work?"}</span>${ck("area",AREAS)}</div>
      ${m==="vendor"?`<div class="grid">${sel("years","Years in business",YEARS)}${sel("team","Team size",TEAM)}${sel("lead","Typical lead time",LEAD)}</div>
        <label class="field"><span>Agent references (2 to 3 names and numbers)</span><textarea id="su-refs" name="references"></textarea></label>
        <label class="field"><span>How did you hear about Orbyt?</span><input type="text" id="su-heard" name="heard"></label>`:""}
      <div class="grid"><label class="field"><span>Create a password (8+ characters)</span><input type="password" id="su-pass" name="password" autocomplete="new-password" required></label>
        <label class="field"><span>Type it again</span><input type="password" id="su-pass2" name="password2" autocomplete="new-password" required></label></div>${showPw("su-show")}
      ${m==="vendor"?`<div class="reviewagree"><div class="eyebrow">Review and agree</div>
        <h2>Your fees</h2><p class="small" style="margin:0">You only pay when an introduction turns into a paid job. The client pays you directly, the same as always.</p>${signupFees()}
        ${keyHighlights("vendor")}
        <h2>Your business</h2>${bizFields("su")}
        <label class="checkrow top"><input type="checkbox" id="su-terms" name="terms"> <span>I've read and agree to the ${termsLink("vendor")}, including the fees above.</span></label>
        ${authorityBox("su")}
        <label class="checkrow top"><input type="checkbox" id="su-optout" name="optout"> <span>If you'd rather not receive Orbyt updates and announcements, tick this box.</span></label></div>`
      :`<label class="checkrow top"><input type="checkbox" id="su-terms" name="terms"> <span>I agree to the ${termsLink(m)}.</span></label>`}
      <p class="small" style="margin:0">Read how Orbyt handles your information in our <a href="${esc(new URL("privacy.html",portalHome()).href)}" target="_blank" rel="noopener">Privacy Policy</a>.</p>${authMsg()}
      <div class="actions"><button class="btn" type="submit">Join Orbyt</button><button class="btn ghost" type="button" data-act="authmode" data-m="signin">Back to sign in</button></div>
    </form></div></section>`;
}
async function enter(user){
  if(S.recovering)return;   // finish choosing a new password first
  S.uid=user.id;S.email=user.email;
  const{data:prof}=await sb.from("profiles").select("*").eq("id",user.id).maybeSingle();
  if(S.recovering)return;
  S.me=prof||null;S.authReady=true;
  if(!prof||prof.status==="pending"){S.authMode="pending";S.pendingName=prof&&prof.full_name?prof.full_name.split(" ")[0]:"";render();return}
  if(prof.status==="declined"){S.authMode="declined";render();return}
  if(prof.role==="agent"||prof.role==="vendor")sb.rpc("note_terms_login").then(()=>{},()=>{});
  let role="orbyt";
  if(prof.role==="agent")role="agent:"+(prof.full_name||prof.email);
  if(prof.role==="vendor"){const{data:v}=await sb.from("vendors").select("id").eq("user_id",user.id).maybeSingle();role=v?"vendor:"+v.id:"vendor:none"}
  S.session=role;S.role=role;S.tab=role==="orbyt"?"dash":"tasks";S.authMode="signin";
  const db=makeSupabaseDb();S.db=db;S.assets=liveAssets;S.canWrite=true;
  S.downloads={save:async({filename,data})=>{const a=document.createElement("a");a.href=URL.createObjectURL(new Blob([data]));a.download=filename;document.body.appendChild(a);a.click();a.remove();return{status:"saved"}}};
  subscribeAll(db);render();
  try{await db.reload()}catch(e){console.error(e);toast("Couldn't load your projects. Refresh to try again.")}
  setInterval(()=>{if(document.visibilityState==="visible"&&!S.busy)db.reload().catch(()=>{})},30000);
}
function subscribeAll(db){
  db.collection("teams").onSnapshot(snap=>{S.teams={};snap.docs.forEach(d=>S.teams[d.id]=d.data());schedule()});
  db.collection("signups").onSnapshot(snap=>{S.signups=snap.docs.map(d=>({id:d.id,...d.data()}));schedule()});
  db.collection("markets").onSnapshot(snap=>{S.markets=snap.docs.map(d=>({id:d.id,...d.data()}));schedule()});
  for(const side of["agents","vendors"])db.collection("private/contacts/"+side).onSnapshot(snap=>{S.contacts={...S.contacts,[side]:snap.docs.map(d=>({id:d.id,...d.data()}))};schedule()});
  db.collection("private/timelog/entries").onSnapshot(snap=>{S.timelog=snap.docs.map(d=>({id:d.id,...d.data()}));schedule()});
  db.collection("private/spend/entries").onSnapshot(snap=>{S.spend=snap.docs.map(d=>({id:d.id,...d.data()}));schedule()});
  db.doc("private/config").onSnapshot(d=>{S.config=d.exists?d.data():{};schedule()});
  db.collection("private/notes/vendors").onSnapshot(snap=>{S.vnotes={};snap.docs.forEach(d=>S.vnotes[d.id]=d.data());schedule()});
  for(const n of["vendors","projects","bids","reviews","mytasks","taskstate","favorites","settings"])db.collection(n).onSnapshot(snap=>{
    if(n==="taskstate"||n==="favorites"||n==="settings"){S[n]={};snap.docs.forEach(d=>S[n][d.id]=d.data())}else S[n]=snap.docs.map(d=>({id:d.id,...d.data()}));
    S.loaded[n]=true;schedule()});
}

/* ---------- quote viewer and client links ---------- */
function quoteViewer(){
  const b=S.bids.find(x=>x.id===S.quoteView);if(!b){S.quoteView=null;return""}
  const url=signedUrl(b.pdfId);
  const body=!url?`<p class="small">Opening the quote...</p>`:b.pdfIsImage?`<img class="quoteimg" src="${esc(url)}" alt="Quote from ${esc(bidName(b))}">`
    :`<iframe class="quoteframe" src="${esc(url)}" title="Quote from ${esc(bidName(b))}"></iframe><p class="small" style="margin:0"><a href="${esc(url)}" target="_blank" rel="noopener">Open in a new tab</a></p>`;
  return `<div class="scrim" data-act="closequote"></div><div class="vcard wide" role="dialog" aria-modal="true" aria-labelledby="qv-title">
    <div class="vchead"><div style="min-width:0"><div class="eyebrow">${esc(b.category)} quote</div><h2 id="qv-title" style="font-weight:500;margin-top:4px">${esc(bidName(b))}</h2><div class="small">${esc(b.pdfName||"")}</div></div>
      <button class="xbtn" id="qv-close" data-act="closequote" aria-label="Close">×</button></div>${body}</div>`;
}
const clientUrl=t=>portalHome()+"?quotes="+t;
function clientLinkBlock(p){
  const l=(D.client_links||[]).find(x=>x.project_id===p.id&&!x.revoked_at);
  if(!l)return `<div class="callout"><p style="margin:0"><span class="strong">Private link.</span> Give your client a page with these quotes that updates as new ones come in. No login needed, and you can turn it off anytime.</p>
    <div class="actions"><button class="btn ghost sm" data-act="makelink" data-id="${esc(p.id)}">Create a private link</button></div></div>`;
  const url=clientUrl(l.token);
  return `<div class="callout"><p style="margin:0"><span class="strong">Private link for your client</span></p><p class="small" id="cl-url" style="margin:0;overflow-wrap:anywhere">${esc(url)}</p>
    <div class="actions"><button class="btn ghost sm" data-act="copylink" data-url="${esc(url)}">Copy link</button><button class="linkbtn" data-act="revokelink" data-id="${esc(l.id)}">Turn off this link</button></div></div>`;
}
async function renderClientPage(token){
  $("#who").innerHTML="";
  const{data,error}=await sb.rpc("client_quotes",{p_token:token});
  if(error||!data){$("#app").innerHTML=`<section class="auth one"><div class="authcard"><div class="eyebrow">Quotes</div><h1>This link isn't active</h1><p>Ask your agent for a new link to your quotes.</p></div></section>`;return}
  const d=data,when=d.target_date?new Date(d.target_date+"T12:00:00").toLocaleDateString("en-US",{month:"long",day:"numeric"}):"";
  $("#app").innerHTML=`<section class="clientpage"><div class="eyebrow">Quotes for your ${d.client_type==="Buyer"?"new home":"listing"}</div><h1>${esc(d.address)}</h1>
    <p class="small">Prepared by ${esc(d.agent)} with Orbyt${when?" · "+(d.client_type==="Buyer"?"move-in ":"listing ")+esc(when):""}</p>
    ${(d.services||[]).map(s=>`<div class="section"><h2>${esc(s.service)}</h2>${(s.quotes||[]).length?`<div class="unrows">${s.quotes.map(q=>`<div class="unrow cs"><div style="min-width:0"><span class="strong">${esc(q.vendor||"Vendor")}</span>${q.booked?' <span class="pill set">Booked</span>':""}${q.rating?` <span class="small">★ ${esc(q.rating)} from ${q.review_count} ${q.review_count==1?"agent":"agents"}</span>`:""}${q.note?`<div class="small">${esc(q.note)}</div>`:""}</div>
      <div class="num unamt">${money(q.amount)}<div class="small">${esc([q.days?q.days+(q.days==1?" day":" days")+" of work":"",q.available_from?"can start "+fmtDate(q.available_from):""].filter(Boolean).join(" · "))}</div></div><div></div></div>`).join("")}</div>`:`<p class="small">Quotes are on the way.</p>`}</div>`).join("")}
    <p class="small">Questions? Reach ${esc(d.agent)}${d.agent_email?" at "+esc(d.agent_email):""}${d.agent_phone?" or "+esc(d.agent_phone):""}. You'll pay each vendor directly.</p></section>`;
}

document.addEventListener("click",async e=>{
  const t=e.target.closest("[data-act]");if(!t)return;const a=t.dataset.act;
  if(a==="signout"){await sb.auth.signOut();location.href=portalHome()}
  else if(a==="authmode"){S.authMode=t.dataset.m;S.authErr="";S.authNote="";render();window.scrollTo({top:0})}
  else if(a==="viewquote"){S.quoteView=t.dataset.id;render();$("#qv-close")?.focus()}
  else if(a==="closequote"){S.quoteView=null;render()}
  else if(a==="approveagent")guard(async()=>{fail((await sb.rpc("admin_set_user_status",{p_user:t.dataset.id,p_status:"active"})).error,"approve");await S.db.reload()},"Approved. They can sign in now.");
  else if(a==="makelink")guard(async()=>{fail((await sb.from("client_links").insert({project_id:t.dataset.id,created_by:S.uid})).error,"link");await S.db.reload()},"Private link created");
  else if(a==="revokelink")guard(async()=>{fail((await sb.from("client_links").update({revoked_at:new Date().toISOString()}).eq("id",t.dataset.id)).error,"link");await S.db.reload()},"Link turned off. It won't open anymore.");
  else if(a==="copylink"){const u=t.dataset.url;try{await navigator.clipboard.writeText(u);toast("Link copied")}catch(_){const el=$("#cl-url");if(el){const r=document.createRange();r.selectNodeContents(el);const s=getSelection();s.removeAllRanges();s.addRange(r)}toast("Selected. Copy it with your keyboard.")}}
});
document.addEventListener("change",e=>{const el=e.target;if(!el.matches||!el.matches("input[data-showpw]"))return;
  const f=el.closest("form");if(f)f.querySelectorAll('input[name="password"],input[name="password2"]').forEach(i=>i.type=el.checked?"text":"password")});
document.addEventListener("submit",async e=>{
  const f=e.target.closest("form[data-proto]");if(!f)return;e.preventDefault();e.stopImmediatePropagation();
  const fd=new FormData(f),email=String(fd.get("email")||"").trim().toLowerCase(),pass=String(fd.get("password")||""),kindOf=f.dataset.proto;
  const btn=f.querySelector('button[type="submit"]');if(btn)btn.disabled=true;
  const done=(err,note)=>{S.authErr=err||"";S.authNote=note||"";if(btn)btn.disabled=false;
    const e1=f.querySelector(".autherr"),n1=f.querySelector(".authnote");
    if(f.isConnected&&e1){e1.textContent=S.authErr;e1.hidden=!S.authErr;if(n1){n1.textContent=S.authNote;n1.hidden=!S.authNote}if(S.authErr)e1.scrollIntoView({block:"nearest"})}else render()};
  const pass2=String(fd.get("password2")??pass);
  try{
    if(kindOf==="signin"){if(!email||!pass)return done("Enter your email and password.");
      const{data,error}=await sb.auth.signInWithPassword({email,password:pass});if(error)return done(friendlyAuthError(error));S.authErr="";await enter(data.user);return}
    if(kindOf==="forgot"){if(!email)return done("Enter the email you signed up with.");
      const{error}=await sb.auth.resetPasswordForEmail(email,{redirectTo:portalHome()});
      return done(error?friendlyAuthError(error):"","If that email has an account, a reset link is on its way.")}
    if(kindOf==="newpass"){if(pass.length<8)return done("Use a password with at least 8 characters.");if(pass!==pass2)return done("Those passwords don't match. Type them again.");
      const{data,error}=await sb.auth.updateUser({password:pass});if(error)return done(friendlyAuthError(error));toast("Password saved");S.recovering=false;S.authMode="signin";try{history.replaceState(null,"",location.pathname)}catch(_){}await enter(data.user);return}
    if(kindOf==="signup"){const m=f.dataset.kind,first=String(fd.get("first")||"").trim(),last=String(fd.get("last")||"").trim(),areas=fd.getAll("area");
      const svcs=[...new Set([...fd.getAll("svc"),...String(fd.get("othersvc")||"").split(",").map(x=>x.trim()).filter(Boolean).map(x=>x.charAt(0).toUpperCase()+x.slice(1))])];
      const err=!first||!last?"Add your first and last name.":!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)?"Enter a valid email.":m==="vendor"&&!String(fd.get("company")||"").trim()?"Add your company name."
        :m==="vendor"&&!svcs.length?"Pick or type at least one service you offer.":pass.length<8?"Use a password with at least 8 characters.":pass!==pass2?"Those passwords don't match. Type them again."
        :m==="vendor"&&!String(fd.get("legal")||"").trim()?"Add your legal business name.":m==="vendor"&&!fd.get("btype")?"Choose your business type."
        :m==="vendor"&&!String(fd.get("title")||"").trim()?"Add your title.":!fd.get("terms")?`Check the box to agree to the ${TERMS[m].title}.`
        :m==="vendor"&&!fd.get("authority")?"Check the box to confirm you have authority to agree for the business.":"";
      if(err)return done(err);
      const meta={ref:S.ref||"",role:m,full_name:first+" "+last,phone:String(fd.get("phone")||"").trim(),areas,terms_version:TERMS[m].version,user_agent:navigator.userAgent.slice(0,300)};
      if(m==="agent")meta.brokerage=String(fd.get("brokerage")||"").trim();
      else Object.assign(meta,bizData(fd),{marketing_opt_out:!!fd.get("optout"),company:String(fd.get("company")).trim(),website:String(fd.get("web")||"").trim(),instagram:igHandle(fd.get("instagram")),portfolio_url:String(fd.get("portfolio")||"").trim(),services:svcs,years_in_business:String(fd.get("years")||""),
        team_size:String(fd.get("team")||""),lead_time:String(fd.get("lead")||""),references:String(fd.get("references")||"").trim(),heard_about:String(fd.get("heard")||"").trim()});
      const{data,error}=await sb.auth.signUp({email,password:pass,options:{data:meta,emailRedirectTo:portalHome()}});
      if(error)return done(friendlyAuthError(error));
      if(data.session){S.authErr="";await enter(data.user);return}
      S.pendingEmail=email;S.authMode="checkemail";S.authErr="";if(btn)btn.disabled=false;render();return}
  }catch(x){console.error(x);done("Something went wrong. Check your connection and try again.")}
},true);

async function liveBoot(){
  // a password reset link: read it before Supabase tidies the address bar, so the new-password screen stays put
  const recovering=/type=recovery/.test(location.hash+location.search);
  sb=supabase.createClient(SB_URL,SB_KEY,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:true}});
  const q=new URLSearchParams(location.search);
  if(q.get("quotes")){S.authReady=true;await renderClientPage(q.get("quotes"));return}
  if(q.get("review")){S.authReady=true;await renderReviewPage(q.get("review"));return}
  // links from orbytconnect.com: ?join=agent or ?join=vendor opens that sign-up form
  // clean links: /join, /join/agent and /join/vendor (the older ?join=... links still work)
  const rf=String(q.get("ref")||"").toLowerCase();if(/^[0-9a-f]{8}$/.test(rf)){S.ref=rf;try{sessionStorage.setItem("orbyt-ref",rf)}catch(_){}}else{try{S.ref=sessionStorage.getItem("orbyt-ref")||""}catch(_){}}
  const path=location.pathname.replace(/\/+$/,"").toLowerCase(),pm=path.match(/^\/join(?:\/(agent|vendor))?$/);
  const join=q.get("join")||(pm&&pm[1]);if(join==="agent"||join==="vendor")S.authMode=join;else if(q.has("join")||pm)S.authMode="join";
  if(recovering){S.authMode="newpass";S.recovering=true}
  sb.auth.onAuthStateChange((ev)=>{if(ev==="PASSWORD_RECOVERY"){S.authMode="newpass";S.recovering=true;S.authReady=true;S.session=null;render()}});
  const{data:{session}}=await sb.auth.getSession();
  if(session&&S.authMode!=="newpass")await enter(session.user);else{S.authReady=true;render()}
}

/* ---------- Agents tab (admin) ---------- */
function agentRows(){
  const q=String(S.agQ||"").trim().toLowerCase(),em=x=>String(x||"").toLowerCase();
  const profs=(D.profiles||[]).filter(p=>p.role==="agent");
  const rows=profs.map(p=>{const ps=S.projects.filter(x=>x.agentId===p.id||(p.email&&em(x.agentEmail)===em(p.email)));
    const sh=S.projects.filter(x=>!ps.includes(x)&&(x.members||[]).some(m=>m.userId===p.id||(p.email&&em(m.email)===em(p.email))));
    return{id:p.id,name:p.full_name||p.email,email:p.email||"",phone:p.phone||"",brokerage:p.brokerage||"",areas:normAreas(p.areas||[]),status:p.status,joined:p.created_at,ps,sh}});
  // agents who are on projects (imported or added by Ashleigh) but haven't made an account
  const seen=new Set(profs.map(p=>em(p.email))),off={};
  for(const x of S.projects){const k=em(x.agentEmail)||"name:"+String(x.agent||"").toLowerCase();if(!x.agent||seen.has(em(x.agentEmail)))continue;
    const r=off[k]=off[k]||{id:"",name:x.agent,email:x.agentEmail||"",phone:x.agentPhone||"",brokerage:x.brokerage||"",areas:[],status:"none",joined:"",ps:[],sh:[]};
    r.ps.push(x);if(x.area&&!r.areas.includes(x.area))r.areas.push(x.area)}
  const order={pending:0,active:1,none:2,declined:3};
  return[...rows,...Object.values(off)].filter(r=>!q||[r.name,r.email,r.brokerage,r.phone,...r.areas].some(v=>String(v).toLowerCase().includes(q)))
    .sort((a,b)=>order[a.status]-order[b.status]||String(a.name).localeCompare(String(b.name)));
}
function agentsView(){
  const rows=agentRows(),all=(D.profiles||[]).filter(p=>p.role==="agent"),act=all.filter(p=>p.status==="active").length,pend=all.filter(p=>p.status==="pending").length;
  const pill={pending:'<span class="pill late">Waiting for approval</span>',active:'<span class="pill set">Active</span>',declined:'<span class="pill">Declined</span>',none:'<span class="pill">No account yet</span>'};
  return `<section class="section"><div class="sechead"><div><h2>Agents</h2><span class="small">${act} active${pend?` · ${pend} waiting for approval`:""}. Agents who are on a project but haven't made an account show as "No account yet."</span></div></div>
    <label class="field" style="max-width:360px;margin-bottom:12px"><span>Search</span><input type="text" id="ag-q" value="${esc(S.agQ||"")}" placeholder="Name, email, brokerage or area"></label>
    ${rows.length?`<div class="tablewrap"><table><thead><tr><th>Agent</th><th>Contact</th><th>Areas</th><th class="num">Projects</th><th>Status</th><th></th></tr></thead><tbody>
    ${rows.map(r=>{const live=r.ps.filter(p=>!p.listed).length,last=[...r.ps].sort((a,b)=>String(b.createdAt).localeCompare(String(a.createdAt)))[0];
      return `<tr><td><span class="strong">${esc(r.name)}</span>${r.brokerage?`<div class="small">${esc(r.brokerage)}</div>`:""}${r.joined?`<div class="small">Joined ${esc(fmtStamp(r.joined))}</div>`:""}${r.id&&r.status==="active"?agentTermsLine(r.id):""}${r.id&&referredByName(r.id)?`<div class="small">Referred by ${esc(referredByName(r.id))}</div>`:""}</td>
        <td>${r.email?`<a href="mailto:${esc(r.email)}">${esc(r.email)}</a>`:""}${r.phone?`<div class="small"><a href="tel:${esc(r.phone.replace(/[^\d+]/g,""))}">${esc(r.phone)}</a></div>`:""}</td>
        <td class="small">${esc(r.areas.join(", "))}</td>
        <td class="num">${r.ps.length}${r.ps.length?`<div class="small">${live} active</div>`:""}${last?`<div class="small"><button class="linkbtn" data-act="openmatch" data-id="${esc(last.id)}">${esc(last.address)}</button></div>`:""}${r.sh.length?`<div class="small">Shared on ${r.sh.length}: <button class="linkbtn" data-act="openmatch" data-id="${esc(r.sh[0].id)}">${esc(r.sh[0].address)}</button></div>`:""}</td>
        <td>${pill[r.status]||""}</td>
        <td style="white-space:nowrap">${!r.id?"":r.status==="pending"?`<button class="btn sm" data-act="agstatus" data-id="${esc(r.id)}" data-v="active">Approve</button> <button class="linkbtn" data-act="agstatus" data-id="${esc(r.id)}" data-v="declined">Decline</button>`
          :r.status==="active"?`<button class="linkbtn" data-act="agstatus" data-id="${esc(r.id)}" data-v="declined">Turn off access</button>`:`<button class="linkbtn" data-act="agstatus" data-id="${esc(r.id)}" data-v="active">Turn access back on</button>`}${r.id?` <button class="linkbtn" data-act="agedit" data-id="${esc(r.id)}">Edit</button> <button class="linkbtn" data-act="agdel" data-id="${esc(r.id)}">Delete</button>`:""}</td></tr>
        ${r.id&&S.agEdit===r.id?`<tr class="delrow"><td colspan="6">${personForm("agentedit",r.id,{name:r.name,email:r.email,phone:r.phone,brokerage:r.brokerage},"agent",true)}</td></tr>`:""}
        ${r.id&&S.agDel===r.id?`<tr class="delrow"><td colspan="6"><div class="callout" style="margin:0"><p style="margin:0"><span class="strong">Delete ${esc(r.name)} for good?</span> This removes their login and profile, and it can't be undone.</p>
          ${r.ps.length?`<label class="checkrow top" style="margin-top:8px"><input type="checkbox" id="agdel-proj"> <span>Also delete their ${r.ps.length} ${r.ps.length===1?"project":"projects"} (${esc(r.ps.map(x=>x.address).join(", "))}). Otherwise ${r.ps.length===1?"it stays":"they stay"} in your desk.</span></label>`:""}
          <div class="actions"><button class="btn sm danger" data-act="agdelgo" data-id="${esc(r.id)}">Delete for good</button><button class="btn ghost sm" data-act="agdel" data-id="">Cancel</button></div></div></td></tr>`:""}`}).join("")}
    </tbody></table></div>`:`<p class="small">${S.agQ?"No agents match that search.":"No agents yet. They show up here as soon as they sign up."}</p>`}</section>`;
}
document.addEventListener("input",e=>{if(e.target.id!=="ag-q")return;S.agQ=e.target.value;render();const el=$("#ag-q");if(el){el.focus();el.setSelectionRange(el.value.length,el.value.length)}},true);
document.addEventListener("click",e=>{const t=e.target.closest('[data-act="agstatus"]');if(!t||kind()!=="orbyt")return;const v=t.dataset.v;
  guard(async()=>{fail((await sb.rpc("admin_set_user_status",{p_user:t.dataset.id,p_status:v})).error,"status");await S.db.reload()},
    v==="active"?"Access is on. They can sign in now.":"Access is off. They can't sign in, and their projects stay in your desk.")});

/* ---------- Terms of Use: a checkbox, no signature. Fees shown up front. ---------- */
const TERMS={
  vendor:{version:"vendor-terms-2026-10-25",title:"Orbyt Vendor Terms of Use",path:"terms/vendor.html"},
  agent:{version:"agent-terms-2026-10-25",title:"Orbyt Agent Terms of Use",path:"terms/agent.html"}};
const termsUrl=r=>new URL(TERMS[r].path,portalHome()).href;
const termsLink=(r,label)=>`<a href="${esc(termsUrl(r))}" target="_blank" rel="noopener">${esc(label||TERMS[r].title)}</a>`;
const myRole=()=>kind()==="vendor"?"vendor":kind()==="agent"?"agent":"";
const myVendorId=()=>kind()==="vendor"?roleVal():"";
const acceptancesFor=uid=>(D.terms_acceptances||[]).filter(a=>uid&&a.user_id===uid).sort((a,b)=>String(b.accepted_at).localeCompare(String(a.accepted_at)));
const currentAcceptance=(uid,r)=>acceptancesFor(uid).find(a=>a.version===TERMS[r].version);
function needsTerms(){const r=myRole();if(!r||!S.uid||!Array.isArray(D.terms_acceptances))return false;
  if(r==="vendor"){const v=vendorById(myVendorId());if(!v||v.approved===false)return false}
  return !currentAcceptance(S.uid,r)}
const feesKey=()=>"orbyt-fees-seen-"+S.uid;
function feesSeen(){try{return localStorage.getItem(feesKey())==="1"}catch(_){return true}}
function markFeesSeen(){try{localStorage.setItem(feesKey(),"1")}catch(_){}}
function showTermsGate(){if(needsTerms())return true;
  if(myRole()!=="vendor"||!Array.isArray(D.terms_acceptances))return false;
  const v=vendorById(myVendorId());return !!(v&&v.approved!==false&&!feesSeen())}
function feeCalc(){const x=Number(S.agCalc||0);
  return `<div class="feecalc"><label class="field"><span>Try a job value ($)</span><input type="number" id="ag-calc" min="0" step="50" value="${esc(S.agCalc||"")}" placeholder="3000"></label>
    <p class="small" id="ag-calc-out" style="margin:0">${x>0?`First job with a new agent: <b>${money2(feeFirst(x))}</b> (${(feeFirst(x)/x*100).toFixed(1)}%). Repeat job with that agent: <b>${money2(feeRepeat(x))}</b>.`:"Enter an amount to see both fees."}</p></div>`}
function feesSection(){
  return `<section class="section agfees"><h2>What you pay, and when</h2>
    <p><b>You only pay when an introduction turns into a paid job.</b> No monthly fee and no sign-up fee. The client pays you directly, the same as always.</p>
    <div class="feegrid">
      <div class="feecard"><span class="eyebrow">First job with a new agent</span><table class="agtable"><tbody><tr><td>First $1,000</td><td>12%</td></tr><tr><td>$1,001 to $5,000</td><td>8%</td></tr><tr><td>Above $5,000</td><td>5%</td></tr></tbody></table>
        <p class="small" style="margin:0">Each portion is charged at its own rate, like tax brackets. $25 minimum, $600 cap per job.</p></div>
      <div class="feecard"><span class="eyebrow">Repeat jobs</span><p class="feebig">2%</p><p class="small" style="margin:0">On later jobs with that agent or their clients. $15 minimum, $100 cap per job.</p></div>
      <div class="feecard"><span class="eyebrow">Never a fee on</span><p class="small" style="margin:0">Staging extensions while a home is on the market, jobs cancelled before work starts, or anything the client doesn't pay you.</p>
        <span class="eyebrow" style="margin-top:10px;display:block">Optional</span><p class="small" style="margin:0">Promoted placement, $20 per promotion.</p></div></div>
    <p class="small"><b>Example:</b> a $3,000 first job is $120 on the first $1,000 plus $160 on the next $2,000, for a $280 fee. The same job as a repeat is $60.</p>
    ${feeCalc()}
    <p class="small" style="margin:0"><b>When it's due:</b> report your final invoice amount within 5 business days of finishing a job (you can do it right on the job in the portal). Orbyt sends an invoice, due 15 days after the job wraps. Fees more than 30 days past due add 1.5% a month, and new introductions pause until they're paid.</p></section>`}
const SHORT={
  vendor:["Reply to each intro within 48 hours with a yes, a no, or a question. Saying no is always fine, and it's much better than no reply. Going quiet on a request means fewer matches down the road.",
    "You contract with and bill the client directly, in your own name, and you're responsible for your work. Add Orbyt's short client notice (Schedule 2) to your quotes.",
    "Keep your licenses current and carry general liability insurance of at least $1M per occurrence and $2M aggregate. Depending on your services, Orbyt also needs to be named as an additional insured (Schedule 3).",
    "You cover claims about your work, Orbyt's liability is limited, and most disputes go to individual arbitration in San Diego."],
  agent:["Orbyt doesn't charge agents for introductions. Vendors pay Orbyt a fee on work that comes from them.",
    "Vendors are independent businesses. You or your client hire and pay them directly, and they're responsible for their work.",
    "Let your clients know the vendor is independent and Orbyt doesn't guarantee their work. Suggested wording is in Schedule 1.",
    "You decide who gets access to a property, following your brokerage, MLS and lockbox rules.",
    "Please don't help a vendor book around Orbyt to avoid their fee.",
    "Orbyt's liability is limited, and most disputes go to individual arbitration in San Diego."]};
const keyHighlights=r=>`<h2>Key Highlights</h2><ul class="tldr">${SHORT[r].map(x=>`<li>${esc(x)}</li>`).join("")}</ul>
  <p class="small" style="margin:0">This is a summary. The full ${termsLink(r,"Terms of Use")} are what count.</p>`;
const shortVersion=r=>`<section class="section">${keyHighlights(r)}</section>`;
/* ---------- vendor Review & Agree: business details, authority, marketing opt-out ---------- */
const BIZ_TYPES=["Sole proprietor","LLC","Corporation","Partnership"];
function bizFields(pre,v){v=v||{};
  return `<div class="grid"><label class="field"><span>Legal business name</span><input type="text" id="${pre}-legal" name="legal" value="${esc(v.legalName||"")}" data-bizname required>
      <small class="small">As it appears on your license or insurance</small></label>
    <label class="field"><span>DBA (optional)</span><input type="text" id="${pre}-dba" name="dba" value="${esc(v.dba||"")}"></label>
    <label class="field"><span>Business type</span><select id="${pre}-btype" name="btype"><option value="">Choose one</option>${BIZ_TYPES.map(x=>`<option ${v.businessType===x?"selected":""}>${esc(x)}</option>`).join("")}</select></label>
    <label class="field"><span>Your title</span><input type="text" id="${pre}-title" name="title" value="${esc(v.signerTitle||"")}" placeholder="Owner, manager, partner"></label></div>`}
const authorityBox=(pre,name)=>`<label class="checkrow top"><input type="checkbox" id="${pre}-auth" name="authority"> <span>I have authority to agree to these terms on behalf of <b class="bizname">${esc(name||"[Legal business name]")}</b>.</span></label>`;
function bizErr(fd){return !String(fd.get("legal")||"").trim()?"Add your legal business name.":!fd.get("btype")?"Choose your business type.":!String(fd.get("title")||"").trim()?"Add your title."
  :!fd.get("authority")?"Check the box to confirm you have authority to agree for the business.":""}
const bizData=fd=>({legal_name:String(fd.get("legal")||"").trim(),dba:String(fd.get("dba")||"").trim(),business_type:String(fd.get("btype")||""),signer_title:String(fd.get("title")||"").trim(),authority:!!fd.get("authority")});
function signupFees(){
  return `<div class="feegrid">
    <div class="feecard"><span class="eyebrow">First job with a new agent</span><table class="agtable"><tbody><tr><td>First $1,000</td><td>12%</td></tr><tr><td>$1,001 to $5,000</td><td>8%</td></tr><tr><td>Above $5,000</td><td>5%</td></tr></tbody></table>
      <p class="small" style="margin:0">Each portion at its own rate, like tax brackets. $25 minimum, $600 cap per job.</p></div>
    <div class="feecard"><span class="eyebrow">Repeat jobs</span><p class="feebig">2%</p><p class="small" style="margin:0">Later jobs with that agent or their clients. $15 minimum, $100 cap per job.</p></div>
    <div class="feecard"><span class="eyebrow">Good to know</span><p class="small" style="margin:0">Nothing to join and no monthly fee. Optional promoted placement is $20 per promotion. Fees more than 30 days past due add 1.5% a month, and new intros pause until they're paid.</p></div></div>`}
// the business name in the authority line follows what's typed
document.addEventListener("input",e=>{const el=e.target;if(!el.matches||!el.matches("input[data-bizname]"))return;const f=el.closest("form");
  f&&f.querySelectorAll(".bizname").forEach(b=>b.textContent=el.value.trim()||"[Legal business name]")},true);
const termsForm=r=>{const v=r==="vendor"?vendorById(myVendorId()):null;
  return `<form class="form" data-form="acceptterms" novalidate><h2>${r==="vendor"?"Vendor":"Agent"} Terms of Use</h2>
    <p class="small" style="margin:0">Read the full ${termsLink(r,"Terms of Use")}. They open in a new tab, where you can print or save a copy.</p>
    ${r==="vendor"?bizFields("tm",v):""}
    <label class="checkrow top"><input type="checkbox" id="tm-ok" name="ok"> <span>I've read and agree to the ${termsLink(r)}${r==="vendor"?", including the fees above":""}.</span></label>
    ${r==="vendor"?authorityBox("tm",v&&v.legalName):""}
    <p class="small" style="margin:0">Read how Orbyt handles your information in our <a href="${esc(new URL("privacy.html",portalHome()).href)}" target="_blank" rel="noopener">Privacy Policy</a>.</p>
    <p class="small warntext tmerr" role="alert" style="margin:0" hidden></p>
    <div class="actions"><button class="btn" type="submit">Agree and continue</button><button class="btn ghost" type="button" data-act="signout">Sign out</button></div></form>`};
function termsGate(){
  const r=myRole(),done=!!currentAcceptance(S.uid,r);
  if(r==="vendor"){const v=vendorById(myVendorId()),first=String(v.contactName||"").split(" ")[0]||v.name;
    return `<section class="hello"><div><div class="eyebrow">Welcome to the Orbyt network</div><h1>You're approved, ${esc(first)}</h1>
      <p>${done?"Before your first introduction, here's a quick look at what Orbyt costs and how it works.":"Before your first introduction, here's exactly what Orbyt costs, and the terms to agree to."}</p></div></section>
      ${feesSection()}${done?`${shortVersion("vendor")}<div class="actions" style="margin-bottom:28px"><button class="btn" data-act="feesok">Sounds good, take me to my dashboard</button>
        <span class="small">You agreed to the ${termsLink("vendor","Vendor Terms of Use")} when you signed up.</span></div>`:shortVersion("vendor")+termsForm("vendor")}`}
  const first=String((S.me&&S.me.full_name)||"").split(" ")[0];
  return `<section class="hello"><div><div class="eyebrow">Welcome to Orbyt</div><h1>One quick thing${first?", "+esc(first):""}</h1>
    <p>Before you start, please read and agree to the Agent Terms of Use.</p></div></section>${shortVersion("agent")}${termsForm("agent")}`;
}
document.addEventListener("submit",e=>{const f=e.target.closest('form[data-form="acceptterms"]');if(!f)return;e.preventDefault();e.stopImmediatePropagation();
  const r=myRole();if(!r)return;const el=f.querySelector(".tmerr"),fd=new FormData(f);
  const bad=r==="vendor"&&bizErr(fd)?bizErr(fd):!fd.get("ok")?`Check the box to agree to the ${TERMS[r].title}.`:"";
  if(bad){if(el){el.textContent=bad;el.hidden=false}return}
  const args={p_version:TERMS[r].version,p_user_agent:navigator.userAgent.slice(0,300)};
  guard(async()=>{let res=await sb.rpc("accept_terms",r==="vendor"?{...args,p_details:bizData(fd)}:args);
    // before update 10 is run, the database only knows the two-field version
    if(res.error&&r==="vendor"&&/function|p_details|schema cache/i.test(res.error.message||""))res=await sb.rpc("accept_terms",args);
    fail(res.error,"terms");
    markFeesSeen();await S.db.reload();window.scrollTo({top:0})},r==="vendor"?"Thanks! You're all set for introductions.":"Thanks! You're all set.")},true);
document.addEventListener("input",e=>{if(e.target.id!=="ag-calc")return;S.agCalc=e.target.value;const out=$("#ag-calc-out");if(!out)return;const x=Number(S.agCalc||0);
  out.innerHTML=x>0?`First job with a new agent: <b>${money2(feeFirst(x))}</b> (${(feeFirst(x)/x*100).toFixed(1)}%). Repeat job with that agent: <b>${money2(feeRepeat(x))}</b>.`:"Enter an amount to see both fees."},true);

/* signed vendor agreements from before the Terms of Use stay on file and viewable */
const agreementsFor=vid=>(D.vendor_agreements||[]).filter(a=>a.vendor_id===vid).sort((a,b)=>String(b.signed_at).localeCompare(String(a.signed_at)));
function agreementViewer(){
  const a=(D.vendor_agreements||[]).find(x=>x.id===S.agreementView);if(!a){S.agreementView=null;return""}
  return `<div class="scrim" data-act="agclose"></div><div class="vcard wide" role="dialog" aria-modal="true" aria-labelledby="ag-title">
    <div class="vchead"><div style="min-width:0"><div class="eyebrow">Signed ${esc(fmtStamp(a.signed_at))} by ${esc(a.signer_name)}</div><h2 id="ag-title" style="font-weight:500;margin-top:4px">Vendor Network Agreement</h2></div>
      <button class="xbtn" id="ag-close" data-act="agclose" aria-label="Close">×</button></div>
    <div class="actions"><button class="btn ghost sm" data-act="agprint" data-id="${esc(a.id)}">Print or save as PDF</button></div>
    <div class="agbox tall">${a.document_html}</div></div>`;
}
const termsWhen=a=>`${esc(fmtStamp(a.accepted_at))}${a.source==="signup"?" at sign-up":" in the portal"}`;
function agreementLine(v){const t=v.userId&&currentAcceptance(v.userId,"vendor"),old=agreementsFor(v.id)[0];if(!v.userId&&!old)return"";
  const rows=[];
  if(t)rows.push(`<p class="small" style="margin:6px 0 0">Agreed to the ${termsLink("vendor","Vendor Terms of Use")} ${termsWhen(t)}</p>`);
  else if(v.userId)rows.push(`<p class="small warntext" style="margin:6px 0 0">${v.approved===false?"Hasn't agreed to the current Vendor Terms of Use. They'll be asked right after you approve them.":"Hasn't agreed to the current Vendor Terms of Use yet. They'll be asked when they next sign in."}</p>`);
  if(old)rows.push(`<p class="small" style="margin:6px 0 0">Earlier agreement signed ${esc(fmtStamp(old.signed_at))} by ${esc(old.signer_name)} · <button class="linkbtn" data-act="agview" data-id="${esc(old.id)}">View</button></p>`);
  return rows.join("")}
const agreementPill=v=>v.userId&&v.approved!==false&&Array.isArray(D.terms_acceptances)&&!currentAcceptance(v.userId,"vendor")?' <span class="pill late">Terms not accepted</span>':"";
const agentTermsLine=uid=>{if(!uid)return"";const t=currentAcceptance(uid,"agent");
  return t?`<div class="small">Agreed to terms ${esc(fmtStamp(t.accepted_at))}</div>`:`<div class="small warntext">Hasn't agreed to terms yet</div>`};
const myAgreementBtn=()=>{const r=myRole();if(!r)return"";const old=r==="vendor"&&agreementsFor(myVendorId())[0];
  return `<button class="linkbtn" data-act="mydetails">My details</button><a class="linkbtn" href="${esc(termsUrl(r))}" target="_blank" rel="noopener">Terms of Use</a>${old?`<button class="linkbtn" data-act="agview" data-id="${esc(old.id)}">Signed agreement</button>`:""}`};
function printAgreement(html){
  const w=window.open("","_blank");if(!w){toast("Allow pop-ups for this site to print the agreement.");return}
  w.document.write(`<!doctype html><html><head><meta charset="utf-8"><title>Orbyt Vendor Network Agreement</title><style>body{font:15px/1.55 Georgia,serif;max-width:760px;margin:40px auto;padding:0 20px;color:#111}
    h2{font-size:22px}h3{font-size:17px;margin-top:28px}table{border-collapse:collapse;width:100%;margin:10px 0}td,th{border:1px solid #bbb;padding:6px 8px;text-align:left;vertical-align:top;font-size:14px}
    .agsign{font-style:italic;font-size:17px}.agblank{color:#888}<\/style></head><body>${html}</body></html>`);
  w.document.close();w.focus();setTimeout(()=>w.print(),300);
}
document.addEventListener("click",e=>{const t=e.target.closest("[data-act]");if(!t)return;const a=t.dataset.act;
  if(a==="agview"){S.vendorCard=null;S.agreementView=t.dataset.id;render();$("#ag-close")?.focus()}
  else if(a==="agclose"){S.agreementView=null;render()}
  else if(a==="feesok"){markFeesSeen();render();window.scrollTo({top:0})}
  else if(a==="agprint"){const rec=t.dataset.id&&(D.vendor_agreements||[]).find(x=>x.id===t.dataset.id);if(rec)printAgreement(rec.document_html)}},true);
document.addEventListener("keydown",e=>{if(e.key==="Escape"&&S.agreementView){S.agreementView=null;render()}});


/* ---------- Insurance by trade group: vendors upload, Ashleigh verifies with one click ---------- */
// Keep these lists in step with public.insurance_trades() in the database (orbyt-update-8.sql).
const INS_GROUPS={
  high:["general contractor / remodeling","roofing","plumbing","electric","hvac","concrete","flooring","drywall","fencing","garage doors","appliance repair","solar panel cleaning","pest control","tree service"],
  mid:["handyman","pool services","moving","junk removal","gutter cleaning","pressure washing","window cleaning","staging","landscaping"]};
const INS_LABEL={high:"Higher risk",mid:"Standard",low:"Lower risk"};
const insTrades=(svcs,g)=>(svcs||[]).filter(x=>(INS_GROUPS[g]||[]).includes(String(x).trim().toLowerCase()));
const insGroup=svcs=>insTrades(svcs,"high").length?"high":insTrades(svcs,"mid").length?"mid":"low";
const andList=a=>a.length<2?a.join(""):a.slice(0,-1).join(", ")+" and "+a[a.length-1];
const todayStr=()=>isoDay(new Date());
const addDaysTo=(iso,n)=>{const d=new Date(iso);d.setDate(d.getDate()+n);return isoDay(d)};
const longDate=d=>d?new Date(d+"T12:00:00").toLocaleDateString("en-US",{month:"long",day:"numeric",year:"numeric"}):"";
function insState(v){
  const g=insGroup(vsv(v)),cur=v.insurance||{},trades=insTrades(vsv(v),g).map(x=>x.toLowerCase());
  const fix=!!(v.insNoteAt&&(!cur.uploadedAt||Date.parse(v.insNoteAt)>Date.parse(cur.uploadedAt)));
  const has=!!cur.path&&!fix,verified=has&&v.insVerifiedPath===cur.path;
  const exp=verified?(v.insExpires||cur.expires||""):(cur.expires||""),t=todayStr();
  const expired=!!exp&&exp<t,expiring=verified&&!!exp&&!expired&&daysTo(exp)<=30;
  const due=v.approvedAt?addDaysTo(v.approvedAt,30):"",pastDue=!!due&&t>due;
  const good=verified&&!expired;
  const introsOk=g==="high"?good:g==="mid"?(good||(!pastDue&&!expired)):true;
  const state=fix?"fix":!cur.path?"needed":expired?"expired":!verified?"checking":expiring?"expiring":"verified";
  return{g,trades,cur,has,fix,verified,exp,expired,expiring,due,pastDue,introsOk,state,needAI:g!=="low"}}
// vendors Ashleigh added herself (no portal login) are managed by hand, so they're never held back
const insOk=v=>!v.userId||insState(v).introsOk;
function insRequirement(v,st){
  const t=andList(st.trades);
  if(st.g==="high")return `Because you offer ${t}, Orbyt needs your certificate of general liability insurance, naming Orbyt LLC as an additional insured, before your first introduction.`;
  if(st.g==="mid")return `Because you offer ${t}, Orbyt needs your certificate of general liability insurance, naming Orbyt LLC as an additional insured, ${st.pastDue?`by ${longDate(st.due)}. New introductions are paused until it's in.`:`by ${st.due?longDate(st.due):"30 days after you're approved"}. Introductions keep coming until then.`}`;
  return `Please upload a current certificate of your general liability insurance${st.due?` by ${longDate(st.due)}`:""}. Orbyt doesn't need to be named on it for your services.`}
function insEmailText(v,st){
  const who=[v.contactName,v.name].filter(Boolean);
  return st.needAI?`Hi,

Could you please send me a certificate of insurance for my general liability policy (and my commercial auto policy, if I have one) with this certificate holder and additional insured:

Orbyt LLC
711 S Nardo Ave, Suite 308
Solana Beach, CA 92075

Orbyt LLC needs to be an additional insured by endorsement, on a primary and non-contributory basis, with a waiver of subrogation. Please include the endorsement page. If my policy already has a blanket additional insured endorsement, a copy of that page works too.

Thank you!
${who.join("\n")}`:`Hi,

Could you please send me a current certificate of insurance for my general liability policy, with this certificate holder:

Orbyt LLC
711 S Nardo Ave, Suite 308
Solana Beach, CA 92075

Thank you!
${who.join("\n")}`}
const INS_PILL={needed:["Certificate needed","late"],fix:["Needs a fix","late"],checking:["Ashleigh is checking it",""],verified:["Confirmed","set"],expiring:["Renews soon","late"],expired:["Expired","late"]};
function insuranceCard(v){
  if(!v||v.approved===false)return"";
  const st=insState(v),[pl,pc]=INS_PILL[st.state],open=!["verified","checking"].includes(st.state);
  const subj="Certificate of insurance for Orbyt LLC",body=insEmailText(v,st);
  const form=`<form class="form inner" data-form="insupload" novalidate><div class="grid">
      <label class="field"><span>Certificate (PDF or photo)</span><input type="file" id="ins-file" name="file" accept="application/pdf,image/*"></label>
      <label class="field"><span>Policy expiration date</span><input type="date" id="ins-exp" name="expires"></label></div>
      <p class="small warntext inserr" role="alert" style="margin:0" hidden></p>
      <div class="actions"><button class="btn" type="submit">Upload certificate</button></div></form>`;
  if(!open)return `<section class="section"><div class="sechead" style="margin:0"><h2>Insurance <span class="pill ${pc}">${pl}</span></h2>
      <span class="small">${st.state==="verified"?`Good through ${esc(longDate(st.exp))}. I'll remind you before it expires.`:`Uploaded ${esc(fmtStamp(st.cur.uploadedAt))}. You'll get an email when it's confirmed.`}</span></div>
      <details class="insmore"><summary class="small">Upload a new certificate</summary>${form}</details></section>`;
  return `<section class="section inscard"><div class="sechead" style="margin:0"><h2>Insurance <span class="pill ${pc}">${pl}</span></h2></div>
    <p>${esc(st.state==="expired"?`Your certificate expired on ${longDate(st.exp)}. Please upload the renewed one.${st.g!=="low"?" New introductions are paused until it's in.":""}`:st.state==="expiring"?`Your certificate is good through ${longDate(st.exp)}. Once your policy renews, upload the new one so introductions keep coming.`:insRequirement(v,st))}</p>
    ${st.fix?`<p class="banner" style="margin:0 0 12px"><b>Ashleigh's note:</b> ${esc(v.insNote)}</p>`:""}
    <ol class="steps"><li><b>Send this to your insurance agent.</b> Copy it, or open it in your email. Agents can usually send the certificate the same day.
      <textarea class="insemail" id="ins-email" readonly rows="9" aria-label="Email to your insurance agent">${esc(body)}</textarea>
      <div class="actions"><button class="btn ghost sm" type="button" data-act="inscopy">Copy email</button><a class="btn ghost sm" href="mailto:?subject=${encodeURIComponent(subj)}&body=${encodeURIComponent(body)}">Open in email</a></div></li>
      <li><b>Upload the certificate when it comes back.</b>${form}</li></ol></section>`;
}
document.addEventListener("click",async e=>{const t=e.target.closest('[data-act="inscopy"]');if(!t)return;const ta=$("#ins-email");if(!ta)return;
  try{await navigator.clipboard.writeText(ta.value);toast("Copied. Paste it into an email to your insurance agent.")}catch(_){ta.select();toast("Selected. Copy it with your keyboard.")}});
document.addEventListener("submit",e=>{const f=e.target.closest('form[data-form="insupload"]');if(!f)return;e.preventDefault();e.stopImmediatePropagation();
  const v=vendorById(myVendorId());if(!v)return;const fd=new FormData(f),file=fd.get("file"),exp=String(fd.get("expires")||""),el=f.querySelector(".inserr");
  const err=!(file&&file.size)?"Choose the certificate file to upload.":file.size>15e6?"That file is over 15 MB. Try a PDF or a smaller photo.":!exp?"Add the policy expiration date from the certificate.":exp<todayStr()?"That date has already passed. Upload your current certificate.":"";
  if(err){if(el){el.textContent=err;el.hidden=false}return}
  guard(async()=>{const path=await putFile("vendor-files",v.id,file);
    fail((await sb.from("vendor_private").update({insurance:{path,name:file.name,expires:exp,uploadedAt:new Date().toISOString()},insurance_paths:[...new Set([...(v.insPaths||[]),path])]}).eq("vendor_id",v.id)).error,"insurance");
    await S.db.reload()},"Uploaded. Ashleigh will check it, usually within a day.")},true);
// sign-up: say what insurance their services need, as they pick them
function signupInsNote(){const f=document.querySelector('form[data-proto="signup"][data-kind="vendor"]'),el=$("#su-insnote");if(!f||!el)return;
  const fd=new FormData(f),svcs=[...fd.getAll("svc"),...String(fd.get("othersvc")||"").split(",").map(x=>x.trim()).filter(Boolean).map(canon)],g=insGroup(svcs);
  if(!svcs.length){el.hidden=true;return}const t=andList(insTrades(svcs,g).map(x=>x.toLowerCase()));
  el.innerHTML=g==="high"?`<b>Insurance:</b> because you offer ${esc(t)}, Orbyt needs to be named as an additional insured on your liability insurance before your first introduction. After you're approved, I'll give you a ready-made email to send your insurance agent.`
    :g==="mid"?`<b>Insurance:</b> because you offer ${esc(t)}, Orbyt needs to be named as an additional insured on your liability insurance within 30 days of approval. After you're approved, I'll give you a ready-made email to send your insurance agent.`
    :`<b>Insurance:</b> after you're approved, you'll upload a certificate of your general liability insurance.`;el.hidden=false}
document.addEventListener("change",e=>{if(e.target.closest&&e.target.closest('form[data-proto="signup"]'))signupInsNote()});
document.addEventListener("input",e=>{if(e.target.id==="su-othersvc")signupInsNote()});

/* Ashleigh's side: the check on the vendor card, and items on her dashboard */
function insuranceAdminLine(v){
  if(!v.userId||v.approved===false&&!(v.insurance||{}).path)return v.userId?`<p class="small" style="margin:6px 0 0"><span class="strong">Insurance group:</span> ${INS_LABEL[insGroup(vsv(v))]}${insGroup(vsv(v))!=="low"?" (Orbyt named as additional insured)":""}</p>`:"";
  const st=insState(v),[pl0,pc]=INS_PILL[st.state],pl=st.state==="checking"?"Ready to check":st.state==="fix"?"Fix requested":pl0,url=st.cur.path?signedUrl("vendor-files:"+st.cur.path):"";
  const rule=st.g==="high"?"Orbyt named as additional insured, before introductions":st.g==="mid"?`Orbyt named as additional insured, by ${fmtDate(st.due)||"30 days after approval"}`:"Certificate only";
  let h=`<div class="inscheck"><p class="small" style="margin:6px 0 0"><span class="strong">Insurance:</span> <span class="pill ${pc}">${pl}</span> ${INS_LABEL[st.g]}${st.trades.length?" ("+esc(andList(st.trades))+")":""} · ${esc(rule)}
    ${st.exp?` · good through ${esc(fmtDate(st.exp))}`:""}${!st.introsOk?' · <span class="warntext">Introductions paused</span>':""}</p>`;
  if(st.cur.path)h+=`<p class="small" style="margin:4px 0 0">${url?`<a href="${esc(url)}" target="_blank" rel="noopener">Open certificate</a>`:"Opening certificate..."} · uploaded ${esc(fmtStamp(st.cur.uploadedAt))}</p>`;
  if(st.has&&!st.verified)h+=`<form class="insverify" data-form="insverify" data-id="${esc(v.id)}">
      <p class="small" style="margin:6px 0 0">${st.needAI?"Check that Orbyt LLC is listed as an additional insured (with the endorsement page), and the dates.":"Check the dates and that it's general liability coverage."}</p>
      <div class="actions"><label class="field" style="max-width:190px"><span>Good through</span><input type="date" name="expires" id="iv-exp-${esc(v.id)}" value="${esc(st.cur.expires||"")}"></label>
      <button class="btn sm" type="submit" name="do" value="ok">Verified</button><button class="linkbtn" type="button" data-act="insfix" data-id="${esc(v.id)}">Something's not right</button></div>
      ${S.insFix===v.id?`<label class="field"><span>What needs fixing? ${esc(v.name)} gets this in an email.</span><input type="text" name="note" id="iv-note-${esc(v.id)}" placeholder="Orbyt LLC isn't listed as an additional insured"></label>
        <div class="actions"><button class="btn ghost sm" type="submit" name="do" value="fix">Send to ${esc(firstName(v.contactName||v.name))}</button></div>`:""}</form>`;
  return h+"</div>"}
document.addEventListener("click",e=>{const t=e.target.closest('[data-act="insfix"]');if(!t||kind()!=="orbyt")return;S.insFix=S.insFix===t.dataset.id?null:t.dataset.id;render()});
document.addEventListener("submit",e=>{const f=e.target.closest('form[data-form="insverify"]');if(!f||kind()!=="orbyt")return;e.preventDefault();e.stopImmediatePropagation();
  const v=vendorById(f.dataset.id);if(!v)return;const fd=new FormData(f),act=(e.submitter&&e.submitter.value)||"ok",cur=v.insurance||{};
  if(act==="fix"){const note=String(fd.get("note")||"").trim();if(!note){toast("Add a short note about what needs fixing.");return}
    guard(async()=>{fail((await sb.from("vendor_admin").update({insurance_note:note,insurance_note_at:new Date().toISOString()}).eq("vendor_id",v.id)).error,"insurance");S.insFix=null;await S.db.reload()},`Sent. ${v.name} will upload a new certificate.`);return}
  const exp=String(fd.get("expires")||"");if(!exp){toast("Add the date the policy is good through.");return}
  guard(async()=>{fail((await sb.from("vendor_admin").update({insurance_verified_path:cur.path,insurance_verified_at:new Date().toISOString(),insurance_expires:exp,insured:true}).eq("vendor_id",v.id)).error,"insurance");await S.db.reload()},
    `Verified. ${v.name} gets a confirmation email.`)},true);
function insuranceAlerts(){const A=[];
  for(const v of S.vendors.filter(v=>v.userId&&v.approved!==false)){const st=insState(v);
    if(st.has&&!st.verified)A.push({id:"ins-"+v.id+"-"+st.cur.path,cls:"k-ink",urgent:st.g==="high",label:"Check insurance",title:`Check ${v.name}'s insurance certificate`,
      meta:[INS_LABEL[st.g]+(st.needAI?", Orbyt named as additional insured":""),st.cur.expires?"good through "+fmtDate(st.cur.expires):"",ago(st.cur.uploadedAt)].filter(Boolean).join(" · "),
      when:st.cur.uploadedAt||"",act:{a:"vcard",id:v.id,label:"Check"},auto:false});
    else if(st.verified&&st.expired&&st.g!=="low")A.push({id:"insexp-"+v.id+"-"+st.exp,cls:"k-warn",urgent:true,label:"Insurance expired",title:`${v.name}'s insurance expired ${fmtDate(st.exp)}`,
      meta:"Introductions are paused. They've been emailed to upload the renewal.",when:st.exp,act:{a:"vcard",id:v.id,label:"Open"},auto:false})}
  return A}


/* ---------- deleting agents and vendors (Ashleigh only, mostly for test accounts) ---------- */
async function removeFolder(bucket,folder){try{const{data}=await sb.storage.from(bucket).list(folder,{limit:1000});
  if(data&&data.length)await sb.storage.from(bucket).remove(data.map(f=>folder+"/"+f.name))}catch(_){}}
function deleteVendorBlock(v){if(kind()!=="orbyt"||!S.canWrite)return"";
  if(S.vDel!==v.id)return `<div class="actions" style="margin-top:6px"><button class="linkbtn warntext" data-act="vdel" data-id="${esc(v.id)}">Delete vendor</button></div>`;
  const n=S.bids.filter(b=>b.vendorId===v.id).length;
  return `<div class="callout" style="margin:8px 0 0"><p style="margin:0"><span class="strong">Delete ${esc(v.name)} for good?</span> This removes their profile${v.userId?", login":""}${n?`, ${n} ${n===1?"bid":"bids"}`:""} and reviews, and it can't be undone.</p>
    <div class="actions"><button class="btn sm danger" data-act="vdelgo" data-id="${esc(v.id)}">Delete for good</button><button class="btn ghost sm" data-act="vdel" data-id="">Cancel</button></div></div>`}
document.addEventListener("click",e=>{const t=e.target.closest('[data-act="agdel"],[data-act="agdelgo"],[data-act="vdel"],[data-act="vdelgo"]');if(!t||kind()!=="orbyt")return;
  const a=t.dataset.act,id=t.dataset.id;
  if(a==="agdel"){S.agDel=id||null;render();return}
  if(a==="vdel"){S.vDel=id||null;render();return}
  if(a==="agdelgo"){const withP=!!($("#agdel-proj")&&$("#agdel-proj").checked),ps=withP?(S.projects||[]).filter(p=>p.agentId===id):[];
    guard(async()=>{for(const p of ps)for(const b of S.bids.filter(b=>b.projectId===p.id))await removeFolder("quotes",b.id);
      fail((await sb.rpc("admin_delete_account",{p_user:id,p_vendor:null,p_projects:withP})).error,"delete");S.agDel=null;await S.db.reload()},"Deleted.");return}
  if(a==="vdelgo"){const v=vendorById(id);if(!v)return;
    guard(async()=>{await removeFolder("vendor-files",id);await removeFolder("vendor-photos",id);for(const b of S.bids.filter(b=>b.vendorId===id))await removeFolder("quotes",b.id);
      fail((await sb.rpc("admin_delete_account",{p_user:v.userId||null,p_vendor:id,p_projects:false})).error,"delete");S.vDel=null;S.vendorCard=null;await S.db.reload()},`Deleted ${v.name}.`)}});


/* ---------- editing people: My details (agents and vendors), Edit on the Agents tab, Change agent on projects ---------- */
function personForm(kindOf,id,d,role,admin){
  const f=(k,label,type,val,extra="")=>`<label class="field"><span>${label}</span><input type="${type}" id="pf-${kindOf}-${k}" name="${k}" value="${esc(val||"")}" ${extra}></label>`;
  return `<form class="form inner" data-form="${kindOf}" data-id="${esc(id)}" novalidate><div class="grid">
      ${role==="vendor"&&!admin?f("company","Company name","text",d.company):""}
      ${f("name",role==="vendor"?"Your name":"Name","text",d.name)}${f("phone","Mobile phone","tel",d.phone)}
      ${role==="agent"?f("brokerage","Brokerage","text",d.brokerage):""}${role==="vendor"&&!admin?f("web","Website","text",d.web):""}
      ${admin?f("email","Login email","email",d.email):""}</div>
    ${admin?`<p class="small" style="margin:0">Changing the login email switches their sign-in right away, with no confirmation email, so double-check the spelling. Their projects follow the new email.</p>`:""}
    <p class="small warntext pferr" role="alert" style="margin:0" hidden></p>
    <div class="actions"><button class="btn sm" type="submit">Save</button><button class="btn ghost sm" type="button" data-act="${admin?"agedit":"mydetailsclose"}" data-id="">Cancel</button></div></form>`}
function myDetailsView(){
  const r=myRole(),me=S.me||{},v=r==="vendor"?vendorById(myVendorId()):null;
  const d=r==="vendor"?{company:v&&v.name,name:me.full_name||(v&&v.contactName),phone:me.phone||(v&&v.phone),web:v&&v.web}:{name:me.full_name,phone:me.phone,brokerage:me.brokerage};
  return `<div class="scrim" data-act="mydetailsclose"></div><div class="vcard" role="dialog" aria-modal="true" aria-labelledby="md-title">
    <div class="vchead"><div><div class="eyebrow">Your account</div><h2 id="md-title" style="font-weight:500;margin-top:4px">My details</h2></div><button class="xbtn" data-act="mydetailsclose" aria-label="Close">×</button></div>
    ${personForm("mydetails","",d,r,false)}
    <form class="form inner" data-form="myemail" novalidate style="margin-top:18px"><h3 style="margin:0">Login email</h3>
      <p class="small" style="margin:0">You sign in with <b>${esc(S.email||me.email||"")}</b>. Changing brokerages or companies? Enter your new email and we'll send a confirmation link to it. Your login switches once you click it.</p>
      <label class="field"><span>New email</span><input type="email" id="md-email" name="email" autocomplete="email"></label>
      <p class="small warntext emerr" role="alert" style="margin:0" hidden></p><p class="small emok" style="margin:0" hidden></p>
      <div class="actions"><button class="btn ghost sm" type="submit">Send confirmation link</button></div></form></div>`}
function changeAgentBlock(p){
  if(S.chAgent!==p.id)return `<div style="margin-top:4px"><button class="linkbtn small" data-act="chagent" data-id="${esc(p.id)}">Change agent</button></div>`;
  const agents=(D.profiles||[]).filter(x=>x.role==="agent"&&x.status!=="declined").sort((a,b)=>String(a.full_name||a.email).localeCompare(String(b.full_name||b.email)));
  return `<form class="form inner" data-form="chagent" data-id="${esc(p.id)}" novalidate style="max-width:560px"><h3 style="margin:8px 0 0">Change the agent on this project</h3>
    <label class="field"><span>Agent</span><select name="who" id="ca-who-${esc(p.id)}"><option value="">Choose an agent</option>
      ${agents.map(a=>`<option value="${esc(a.id)}" ${a.id===p.agentId?"selected":""}>${esc(a.full_name||a.email)}${a.brokerage?" ("+esc(a.brokerage)+")":""}</option>`).join("")}<option value="new">Someone without an account yet</option></select></label>
    <div class="grid canew" ${S.chAgentNew?"":"hidden"}>
      <label class="field"><span>Name</span><input type="text" name="name" id="ca-name-${esc(p.id)}"></label><label class="field"><span>Email</span><input type="email" name="email" id="ca-email-${esc(p.id)}"></label>
      <label class="field"><span>Mobile phone</span><input type="tel" name="phone" id="ca-phone-${esc(p.id)}"></label><label class="field"><span>Brokerage</span><input type="text" name="brokerage" id="ca-brok-${esc(p.id)}"></label></div>
    <p class="small" style="margin:0">The project moves to them with its vendors and bids. If they don't have an account yet, it links to them when they sign up with that email.</p>
    <div class="actions"><button class="btn sm" type="submit">Move project</button><button class="btn ghost sm" type="button" data-act="chagent" data-id="">Cancel</button></div></form>`}
const okEmail=x=>/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(x);
const pfErr=(f,m)=>{const el=f.querySelector(".pferr");if(el){el.textContent=m;el.hidden=!m}};
document.addEventListener("click",e=>{const t=e.target.closest('[data-act="mydetails"],[data-act="mydetailsclose"],[data-act="agedit"],[data-act="chagent"]');if(!t)return;const a=t.dataset.act;
  if(a==="mydetails"){S.myDetails=true;render();return}
  if(a==="mydetailsclose"){S.myDetails=false;render();return}
  if(kind()!=="orbyt")return;
  if(a==="agedit"){S.agEdit=t.dataset.id||null;S.agDel=null;render();return}
  if(a==="chagent"){S.chAgent=t.dataset.id||null;S.chAgentNew=false;render()}});
document.addEventListener("change",e=>{const sel=e.target.closest&&e.target.closest('form[data-form="chagent"] select[name="who"]');if(!sel)return;
  S.chAgentNew=sel.value==="new";const g=sel.form.querySelector(".canew");if(g)g.hidden=!S.chAgentNew});
document.addEventListener("keydown",e=>{if(e.key==="Escape"&&S.myDetails){S.myDetails=false;render()}});
document.addEventListener("submit",e=>{const f=e.target.closest('form[data-form="mydetails"],form[data-form="myemail"],form[data-form="agentedit"],form[data-form="chagent"]');if(!f)return;
  e.preventDefault();e.stopImmediatePropagation();const fd=new FormData(f),g=k=>String(fd.get(k)||"").trim(),k=f.dataset.form;
  if(k==="mydetails"){if(!g("name"))return pfErr(f,"Add your name.");const r=myRole();
    guard(async()=>{fail((await sb.from("profiles").update(r==="agent"?{full_name:g("name"),phone:g("phone")||null,brokerage:g("brokerage")||null}:{full_name:g("name"),phone:g("phone")||null}).eq("id",S.uid)).error,"details");
      if(r==="vendor"){const vid=myVendorId();fail((await sb.from("vendors").update({name:g("company")||undefined,website:g("web")||null}).eq("id",vid)).error,"details")}
      const{data}=await sb.from("profiles").select("*").eq("id",S.uid).maybeSingle();if(data){S.me=data;if(r==="agent")S.role=S.session="agent:"+(data.full_name||data.email)}
      S.myDetails=false;await S.db.reload()},"Saved.");return}
  if(k==="myemail"){const em=g("email").toLowerCase(),er=f.querySelector(".emerr"),okp=f.querySelector(".emok");
    const show=(m,good)=>{if(er){er.textContent=good?"":m;er.hidden=good||!m}if(okp){okp.textContent=good?m:"";okp.hidden=!good}};
    if(!okEmail(em))return show("Enter a valid email.");if(em===String(S.email||"").toLowerCase())return show("That's already your login email.");
    (async()=>{const btn=f.querySelector("button");if(btn)btn.disabled=true;
      const{error}=await sb.auth.updateUser({email:em},{emailRedirectTo:portalHome()});if(btn)btn.disabled=false;
      if(error)return show(/already|registered|exists/i.test(error.message)?"That email already has an Orbyt account.":"That didn't go through. Try again in a minute.");
      show(`Check ${em} for a confirmation link. You may also get one at your current address. Your login switches once you confirm.`,true)})();return}
  if(k==="agentedit"){const id=f.dataset.id,prof=(D.profiles||[]).find(x=>x.id===id);if(!prof)return;const em=g("email").toLowerCase();
    if(!g("name"))return pfErr(f,"Add their name.");if(!okEmail(em))return pfErr(f,"Enter a valid email.");
    guard(async()=>{fail((await sb.from("profiles").update({full_name:g("name"),phone:g("phone")||null,brokerage:g("brokerage")||null}).eq("id",id)).error,"details");
      if(em!==String(prof.email||"").toLowerCase())fail((await sb.rpc("admin_set_email",{p_user:id,p_email:em})).error,"email");
      S.agEdit=null;await S.db.reload()},"Saved. Their projects are updated too.");return}
  if(k==="chagent"){const pid=f.dataset.id,who=g("who");let row;
    if(!who){toast("Choose an agent.");return}
    if(who==="new"){const em=g("email").toLowerCase();if(!g("name")||!okEmail(em)){toast("Add their name and a valid email.");return}
      const ex=(D.profiles||[]).find(x=>String(x.email||"").toLowerCase()===em);
      row={agent_name:g("name"),agent_email:em,agent_phone:g("phone")||null,brokerage:g("brokerage")||null,agent_id:ex&&ex.role==="agent"?ex.id:null}}
    else{const a=(D.profiles||[]).find(x=>x.id===who);if(!a)return;row={agent_name:a.full_name||a.email,agent_email:a.email,agent_phone:a.phone||null,brokerage:a.brokerage||null,agent_id:a.id}}
    guard(async()=>{fail((await sb.from("projects").update(row).eq("id",pid)).error,"project");S.chAgent=null;S.chAgentNew=false;await S.db.reload()},`Moved to ${row.agent_name}.`)}},true);

/* ---------- review requests: approved vendors invite up to 10 past clients (agents) to review them ---------- */
// Keep RR_LIMIT in step with public.review_request_limit() in the database (orbyt-update-10.sql).
const RR_LIMIT=10;
const rrKey=()=>"orbyt-rr-hidden-"+S.uid;
function rrHidden(){try{return localStorage.getItem(rrKey())==="1"}catch(_){return false}}
function rrSetHidden(on){try{on?localStorage.setItem(rrKey(),"1"):localStorage.removeItem(rrKey())}catch(_){}}
const rrFor=vid=>(D.review_requests||[]).filter(q=>q.vendor_id===vid);
const rrRow=i=>`<div class="grid rrrow"><label class="field"><span>Agent name</span><input type="text" id="rr-name-${i}" name="rrname" autocomplete="off"></label>
  <label class="field"><span>Agent email</span><input type="email" id="rr-email-${i}" name="rremail" autocomplete="off"></label></div>`;
function rrForm(left,first){const n=Math.min(3,left);
  return `<form class="form inner" data-form="rrsend" novalidate data-left="${left}">
    <div class="rrrows">${Array.from({length:n},(_,i)=>rrRow(i)).join("")}</div>
    ${left>n?`<div><button class="linkbtn" type="button" data-act="rradd">Add another agent</button> <span class="small">You can invite ${left} more.</span></div>`:""}
    <label class="field"><span>A personal note (optional)</span><textarea id="rr-note" name="note" rows="3" maxlength="600" placeholder="Thanks again for having us on the Del Mar listing. A quick review would mean a lot."></textarea></label>
    <p class="small" style="margin:0">Please don't offer anything in exchange for a review. I check each one before it's posted, and honest reviews are welcome, including critical ones.</p>
    <p class="small warntext rrerr" role="alert" style="margin:0" hidden></p>
    <div class="actions"><button class="btn" type="submit">Send review requests</button>${first?`<button class="btn ghost" type="button" data-act="rrhide">Not now</button>`:""}</div></form>`}
function reviewInviteCard(v){
  if(!v||v.approved===false||!v.userId||!Array.isArray(D.review_requests))return"";
  const sent=rrFor(v.id),left=Math.max(0,RR_LIMIT-sent.length),done=sent.filter(q=>q.completed_at).length;
  if(!sent.length&&rrHidden())return `<section class="section"><div class="sechead" style="margin:0"><div><h2>Reviews from past clients</h2>
      <span class="small">Invite up to ${RR_LIMIT} agents you've worked with to review you.</span></div><button class="btn ghost sm" data-act="rrshow">Invite agents</button></div></section>`;
  const status=q=>q.completed_at?`<span class="pill set">Reviewed</span>`:q.reminded_at?`<span class="pill">Reminder sent</span>`:`<span class="pill">Waiting</span>`;
  const list=sent.length?`<div class="tablewrap"><table><thead><tr><th>Agent</th><th>Invited</th><th>Status</th></tr></thead><tbody>${sent.map(q=>`<tr>
      <td><span class="strong">${esc(q.agent_name)}</span><div class="small">${esc(q.agent_email)}</div></td><td class="small">${esc(fmtStamp(q.created_at))}</td><td>${status(q)}</td></tr>`).join("")}</tbody></table></div>`:"";
  if(!sent.length)return `<section class="section rrcard"><div class="sechead" style="margin:0"><h2>Get your first reviews</h2></div>
    <p>Agents look at reviews before they book someone new. Invite up to ${RR_LIMIT} agents you've worked with, and I'll email each one a private link to review you. They don't need an account, and it takes about two minutes.</p>
    <p class="small" style="margin:0">Their reviews show on your profile as past client reviews once I've checked them. Anyone who hasn't replied gets one reminder after 5 days.</p>
    ${rrForm(left,true)}</section>`;
  return `<section class="section rrcard"><div class="sechead" style="margin:0"><div><h2>Reviews from past clients</h2>
      <span class="small">${sent.length} invited · ${done} reviewed. Reviews show on your profile once I've checked them.</span></div></div>
    ${list}${left?`<details class="insmore"${S.rrMore?" open":""}><summary class="small">Invite more agents (${left} left)</summary>${rrForm(left)}</details>`:`<p class="small" style="margin:8px 0 0">You've invited all ${RR_LIMIT} agents. Reviews from jobs booked through Orbyt add up from here.</p>`}</section>`;
}
document.addEventListener("click",e=>{const t=e.target.closest("[data-act]");if(!t)return;const a=t.dataset.act;
  if(a==="rrhide"){rrSetHidden(true);render()}
  else if(a==="rrshow"){rrSetHidden(false);render();$("#rr-name-0")?.focus()}
  else if(a==="rradd"){const f=t.closest("form"),box=f&&f.querySelector(".rrrows");if(!box)return;const n=box.querySelectorAll(".rrrow").length,left=Number(f.dataset.left||0);
    if(n>=left)return;box.insertAdjacentHTML("beforeend",rrRow(n));box.querySelector(`#rr-name-${n}`)?.focus();if(n+1>=left)t.parentElement.hidden=true}},true);
document.addEventListener("submit",e=>{const f=e.target.closest('form[data-form="rrsend"]');if(!f)return;e.preventDefault();e.stopImmediatePropagation();
  const er=f.querySelector(".rrerr"),show=m=>{if(er){er.textContent=m;er.hidden=!m}};
  const names=[...f.querySelectorAll('input[name="rrname"]')].map(x=>x.value.trim()),mails=[...f.querySelectorAll('input[name="rremail"]')].map(x=>x.value.trim().toLowerCase());
  const inv=[],seen=new Set();
  for(let i=0;i<names.length;i++){const n=names[i],m=mails[i];if(!n&&!m)continue;
    if(!n)return show(`Add a name for ${m}.`);if(!okEmail(m))return show(`Check the email for ${n}.`);
    if(seen.has(m))return show(`${m} is listed twice.`);seen.add(m);inv.push({name:n,email:m})}
  if(!inv.length)return show("Add at least one agent's name and email.");show("");
  const note=String(new FormData(f).get("note")||"").trim();
  guard(async()=>{fail((await sb.rpc("send_review_requests",{p_invites:inv,p_note:note||null})).error,"review requests");S.rrMore=false;await S.db.reload()},
    `Sent to ${inv.length} ${inv.length===1?"agent":"agents"}. Their reviews show up once I've checked them.`)},true);
document.addEventListener("toggle",e=>{const d=e.target;if(d.matches&&d.matches(".rrcard details"))S.rrMore=d.open},true);

// for Ashleigh, on the vendor's card
function businessLine(v){const bits=[v.legalName?"Legal name: "+v.legalName:"",v.dba?"DBA "+v.dba:"",v.businessType,v.signerTitle?`${v.contactName||"Signer"}, ${v.signerTitle}`:""].filter(Boolean);
  if(!bits.length&&!v.marketingOptOut)return"";
  return `<p class="small" style="margin:6px 0 0">${esc(bits.join(" · "))}${v.marketingOptOut?`${bits.length?" · ":""}Opted out of Orbyt updates`:""}</p>`}
function reviewReqLine(v){if(!Array.isArray(D.review_requests))return"";const q=rrFor(v.id);if(!q.length)return"";
  return `<p class="small" style="margin:6px 0 0">Review requests: ${q.length} sent, ${q.filter(x=>x.completed_at).length} reviewed (${esc(q.map(x=>x.agent_name+(x.completed_at?", reviewed":"")).join("; "))})</p>`}
// a label on reviews from past clients, so they're never mistaken for jobs booked through Orbyt
const revSource=r=>r&&r.source==="past_client"?` <span class="pill">Past client</span>`:"";
const revWho=r=>r&&r.source==="past_client"?[r.agent||"Agent",r.brokerage].filter(Boolean).join(", ")+(r.workWhen?` · work in ${r.workWhen}`:""):(r&&r.agent)||"Agent";

/* ---------- the review page behind a private link (no login) ---------- */
const reviewCard=(eyebrow,title,body)=>`<section class="auth one"><div class="authcard"><div class="eyebrow">${eyebrow}</div><h1>${title}</h1>${body}</div></section>`;
async function renderReviewPage(token){
  $("#who").innerHTML="";
  const{data,error}=await sb.rpc("review_request_get",{p_token:token});
  if(error||!data){$("#app").innerHTML=reviewCard("Review","This review link isn't active",`<p>If you were asked for a review, reply to the email and I'll send a new link.</p><p class="small">Ashleigh at Orbyt</p>`);return}
  if(data.done){$("#app").innerHTML=reviewCard("Review","Thanks, your review is in",`<p>I'll check it and add it to ${esc(data.vendor)}'s profile.</p><p class="small">Ashleigh at Orbyt</p>`);return}
  const svc=(data.services||[]).slice(0,3).join(", ");
  const stars=[5,4,3,2,1].map(n=>`<input type="radio" id="rv-star-${n}" name="rating" value="${n}"><label for="rv-star-${n}" title="${n} ${n===1?"star":"stars"}"><span aria-hidden="true">★</span><span class="sr">${n} ${n===1?"star":"stars"}</span></label>`).join("");
  $("#app").innerHTML=reviewCard("Review"+(svc?" · "+esc(svc):""),`How was working with ${esc(data.vendor)}?`,`
    <p class="small" style="margin:0">${esc(data.vendor)} asked for your review. It helps other San Diego agents find good people. No account needed.</p>
    <form class="authform" data-form="reviewsubmit" data-token="${esc(token)}" novalidate>
      <fieldset class="field" style="border:0;padding:0;margin:0"><legend class="legend">Your rating</legend><div class="starpick">${stars}</div></fieldset>
      <label class="field"><span>About the work</span><textarea id="rv-comment" name="comment" rows="5" maxlength="2000" placeholder="What did they do, and how did it go? Quality, communication, timing, anything another agent should know."></textarea></label>
      <div class="grid"><label class="field"><span>Your name</span><input type="text" id="rv-name" name="name" value="${esc(data.agent_name||"")}" autocomplete="name"></label>
        <label class="field"><span>Your brokerage</span><input type="text" id="rv-brokerage" name="brokerage" autocomplete="organization"></label></div>
      <label class="field"><span>About when was the job? (optional)</span><input type="text" id="rv-when" name="when" maxlength="40" placeholder="Spring 2026"></label>
      <p class="small" style="margin:0">I check every review before it's posted. Your name, brokerage and review show on their Orbyt profile, never your email. Read the <a href="${esc(new URL("privacy.html",portalHome()).href)}" target="_blank" rel="noopener">Privacy Policy</a>.</p>
      <p class="small warntext rverr" role="alert" style="margin:0" hidden></p>
      <button class="btn" type="submit">Send my review</button></form>`);
}
document.addEventListener("submit",async e=>{const f=e.target.closest('form[data-form="reviewsubmit"]');if(!f)return;e.preventDefault();e.stopImmediatePropagation();
  const fd=new FormData(f),g=k=>String(fd.get(k)||"").trim(),er=f.querySelector(".rverr"),show=m=>{if(er){er.textContent=m;er.hidden=!m;if(m)er.scrollIntoView({block:"nearest"})}};
  const rating=Number(fd.get("rating")||0);
  const bad=!rating?"Pick a star rating.":!g("comment")?"Add a few words about the work.":!g("name")?"Add your name.":!g("brokerage")?"Add your brokerage.":"";
  if(bad)return show(bad);show("");
  const btn=f.querySelector('button[type="submit"]');if(btn)btn.disabled=true;
  const{error}=await sb.rpc("review_request_submit",{p_token:f.dataset.token,p_rating:rating,p_comment:g("comment"),p_name:g("name"),p_brokerage:g("brokerage"),p_when:g("when")||null});
  if(btn)btn.disabled=false;
  if(error){console.error(error);return show(/already been sent|isn't active|Pick|Add /.test(error.message||"")?String(error.message).replace(/^.*?ERROR:\s*/,""):"That didn't send. Check your connection and try again.")}
  $("#app").innerHTML=reviewCard("Review","Thank you!",`<p>Your review is in. I'll check it and add it to the profile, usually within a day.</p><p class="small">Ashleigh at Orbyt</p>`);window.scrollTo({top:0})},true);

/* ---------- removing a service from a project: one database call, so agents can close open requests too ---------- */
async function removeService(p,c){
  const{error}=await sb.rpc("remove_project_service",{p_project:p.id,p_category:c});
  // before update 11 is run, Ashleigh can still do it the old way
  if(error&&kind()==="orbyt"&&/function|schema cache/i.test(error.message||"")){
    for(const b of bidsFor(p.id,c))if(["requested","submitted","changes"].includes(b.status))fail((await sb.from("bids").update({status:"passed"}).eq("id",b.id)).error,"bid");
    fail((await sb.from("projects").update({categories:(p.categories||[]).filter(x=>x!==c)}).eq("id",p.id)).error,"project")}
  else fail(error,"remove service");
  await S.db.reload();
}


/* ---------- portfolio, referrals, and folding the dashboard so jobs come first ---------- */
const igHandle=x=>{let s=String(x||"").trim();if(!s)return"";const m=s.match(/instagram\.com\/([A-Za-z0-9._]+)/i);if(m)s=m[1];return s.replace(/^@+/,"").replace(/[^A-Za-z0-9._]/g,"").slice(0,30)};
const igUrl=x=>{const h=igHandle(x);return h?"https://www.instagram.com/"+h+"/":""};
function referredByName(uid){const p=(D.profiles||[]).find(x=>x.id===uid);if(!p||!p.referred_by)return"";const r=(D.profiles||[]).find(x=>x.id===p.referred_by);
  if(!r)return"";if(r.role==="vendor"){const v=(D.vendors||[]).find(x=>x.user_id===r.id);if(v)return v.name+(r.full_name?" ("+r.full_name+")":"")}return r.full_name||r.email}
// fold state: per viewer, remembered in this browser when possible
function foldOpen(key,dflt){S.folds=S.folds||{};if(key in S.folds)return S.folds[key];try{const x=localStorage.getItem("orbyt-fold-"+S.uid+"-"+key);if(x!==null)return(S.folds[key]=x==="1")}catch(_){}return!!dflt}
document.addEventListener("toggle",e=>{const d=e.target;if(!d.matches||!d.matches("details.fold[data-fold]"))return;S.folds=S.folds||{};S.folds[d.dataset.fold]=d.open;
  try{localStorage.setItem("orbyt-fold-"+S.uid+"-"+d.dataset.fold,d.open?"1":"0")}catch(_){}},true);
const fold=(key,title,pill,hint,body,dflt)=>body?`<details class="fold" data-fold="${key}" ${foldOpen(key,dflt)?"open":""}><summary><span class="foldtitle">${title}</span>${pill||""}${hint?`<span class="small foldhint">${hint}</span>`:""}</summary><div class="foldbody">${body}</div></details>`:"";
function vendorFolds(v){
  if(!v||kind()!=="vendor")return"";
  const parts=[];
  if(v.approved!==false){const st=insState(v),[pl,pc]=INS_PILL[st.state];
    parts.push(fold("ins","Insurance",`<span class="pill ${pc}">${pl}</span>`,st.state==="needed"&&st.g==="high"?"Needed before your first introduction":st.state==="needed"&&st.due?"Due "+fmtDate(st.due):"",insuranceCard(v),false))}
  const n=[v.web,v.instagram,v.portfolioUrl,v.portfolioPdf].filter(Boolean).length;
  parts.push(fold("port","Portfolio",n?`<span class="pill set">${n} added</span>`:`<span class="pill late">Add your work</span>`,"Website, Instagram, a link or a PDF",portfolioCard(v),false));
  const pr=vPricing(v),hasP=statedTier(v)||priceItems(v).length||pr.minimum;
  parts.push(fold("price","Typical pricing",hasP?'<span class="pill set">Added</span>':'<span class="pill">Not added yet</span>',"Helps me match you to the right homes",vendorPricingCard(v),S.openForm==="pricing"));
  if(typeof reviewInviteCard==="function"&&v.approved!==false){const sent=typeof rrFor==="function"?rrFor(v.id):[];
    parts.push(fold("rr","Reviews from past clients",sent.length?`<span class="pill">${sent.length} invited</span>`:"","Invite agents you've worked with",reviewInviteCard(v),!!S.rrMore))}
  parts.push(fold("refer","Refer someone to Orbyt",refCountPill(),"A ready-made message to send",referralCard("vendor"),false));
  return `<section class="section folds"><div class="sechead" style="margin-bottom:8px"><div><h2>Your profile</h2><span class="small">Finish these when you have a minute. Tap one to open it.</span></div></div>${parts.join("")}</section>`}
function agentFolds(){if(kind()!=="agent"||!S.canWrite)return"";
  return `<section class="section folds" style="margin-top:24px">${fold("refer","Refer someone to Orbyt",refCountPill(),"Know an agent or vendor who'd like Orbyt?",referralCard("agent"),false)}</section>`}
// portfolio card
function portfolioCard(v){
  const pdf=v.portfolioPdf?blobHref(v.portfolioPdf):"";
  return `<form class="form inner" data-form="portfolio" novalidate><p class="small" style="margin:0">Agents see these on your profile when I introduce you. Add whatever shows your work best.</p>
    <div class="grid"><label class="field"><span>Website</span><input type="text" id="pt-web" name="web" value="${esc(v.web||"")}" placeholder="yourbusiness.com"></label>
      <label class="field"><span>Instagram</span><input type="text" id="pt-ig" name="instagram" value="${esc(v.instagram?"@"+v.instagram:"")}" placeholder="@yourbusiness"></label>
      <label class="field"><span>Portfolio link</span><input type="text" id="pt-port" name="portfolio" value="${esc(v.portfolioUrl||"")}" placeholder="Google Drive, Houzz, Dropbox or anywhere"></label>
      <label class="field"><span>${v.portfolioPdf?"Replace your portfolio PDF":"Portfolio PDF"}</span><input type="file" id="pt-pdf" name="pdf" accept="application/pdf"></label></div>
    ${v.portfolioPdf?`<p class="small" style="margin:0">On file: <a href="${esc(pdf)}" target="_blank" rel="noopener">${esc(v.portfolioPdfName||"Portfolio PDF")}</a> · <button class="linkbtn" type="button" data-act="ptpdfdel">Remove</button></p>`:""}
    <p class="small warntext pterr" role="alert" style="margin:0" hidden></p>
    <div class="actions"><button class="btn sm" type="submit">Save portfolio</button></div></form>`}
const normUrl=x=>{const s=String(x||"").trim();return!s?"":/^https?:\/\//i.test(s)?s:"https://"+s};
document.addEventListener("submit",e=>{const f=e.target.closest('form[data-form="portfolio"]');if(!f)return;e.preventDefault();e.stopImmediatePropagation();
  const v=vendorById(myVendorId());if(!v)return;const fd=new FormData(f),file=fd.get("pdf"),el=f.querySelector(".pterr");
  if(file&&file.size&&(file.type!=="application/pdf"||file.size>25e6)){if(el){el.textContent=file.type!=="application/pdf"?"Choose a PDF file.":"That PDF is over 25 MB. Try a smaller version.";el.hidden=false}return}
  guard(async()=>{const row={website:String(fd.get("web")||"").trim()||null,instagram:igHandle(fd.get("instagram"))||null,portfolio_url:normUrl(fd.get("portfolio"))||null};
    if(file&&file.size){const old=v.portfolioPdfPath;const path=await putFile("vendor-photos",v.id,file);Object.assign(row,{portfolio_pdf:path,portfolio_pdf_name:file.name.slice(0,120)});
      if(old)try{await sb.storage.from("vendor-photos").remove([old])}catch(_){}}
    fail((await sb.from("vendors").update(row).eq("id",v.id)).error,"portfolio");await S.db.reload()},"Portfolio saved. Agents see it on your profile.")},true);
document.addEventListener("click",e=>{const t=e.target.closest('[data-act="ptpdfdel"]');if(!t)return;const v=vendorById(myVendorId());if(!v||!v.portfolioPdfPath)return;
  guard(async()=>{try{await sb.storage.from("vendor-photos").remove([v.portfolioPdfPath])}catch(_){}
    fail((await sb.from("vendors").update({portfolio_pdf:null,portfolio_pdf_name:null}).eq("id",v.id)).error,"portfolio");await S.db.reload()},"Removed.")});
// referral card: a ready-made message with the person's own sign-up link
const refCode=()=>String(S.uid||"").slice(0,8);
const refLink=who=>new URL("join/"+who,portalHome()).href+"?ref="+refCode();
function refCountPill(){if(S.refCount==null&&!S.refCountLoading&&sb){S.refCountLoading=true;sb.rpc("my_referral_count").then(({data})=>{S.refCount=data||0;schedule()},()=>{S.refCount=0})}
  return S.refCount?`<span class="pill set">${S.refCount} joined</span>`:""}
function refMessage(me,who){const link=refLink(who);
  if(me==="vendor"&&who==="vendor")return `Hi! I've been getting work through Orbyt, a vendor network here in San Diego that connects local pros with real estate agents getting homes ready to sell. Every vendor joins with references from agents, and you only pay when an introduction turns into a paid job. I think you'd be a great fit. You can apply here: ${link}`;
  if(me==="vendor")return `Hi! I've joined Orbyt, a free service that matches agents with trusted local vendors for every listing, from staging and cleaning to repairs and photography. You send one request and get bids side by side. If you're prepping a listing soon, it's worth a look: ${link}`;
  if(who==="vendor")return `Hi! I use Orbyt to line up vendors for my listings, and I'd love to see you in the network. Agents book trusted local pros through it, and you only pay when an introduction turns into a paid job. You can apply here: ${link}`;
  return `Hi! I've been using Orbyt to line up vendors for my listings. You send one request, Ashleigh matches you with vetted local pros, and you compare bids side by side. It's free for agents. Thought you'd like it: ${link}`}
function referralCard(me){const who=S.refWho||(me==="vendor"?"vendor":"agent"),msg=refMessage(me,who),subj=who==="vendor"?"An easier way to get listing work":"An easier way to line up vendors for your listings";
  return `<div class="refcard"><p class="small" style="margin:0">Know someone who'd be a good fit? Send them this. It includes your own sign-up link, so I'll know they came from you.</p>
    <div class="seg" role="group" aria-label="Who are you inviting?"><button type="button" class="segbtn ${who==="agent"?"on":""}" data-act="refwho" data-v="agent" aria-pressed="${who==="agent"}">An agent</button><button type="button" class="segbtn ${who==="vendor"?"on":""}" data-act="refwho" data-v="vendor" aria-pressed="${who==="vendor"}">A vendor</button></div>
    <textarea class="insemail" id="ref-msg" rows="6" aria-label="Message to send">${esc(msg)}</textarea>
    <div class="actions"><button class="btn ghost sm" type="button" data-act="refcopy">Copy message</button><a class="btn ghost sm" href="mailto:?subject=${encodeURIComponent(subj)}&body=${encodeURIComponent(msg)}">Email it</a><a class="btn ghost sm" href="sms:?&body=${encodeURIComponent(msg)}">Text it</a></div></div>`}
document.addEventListener("click",async e=>{const t=e.target.closest('[data-act="refwho"],[data-act="refcopy"]');if(!t)return;
  if(t.dataset.act==="refwho"){S.refWho=t.dataset.v;render();return}
  const ta=$("#ref-msg");if(!ta)return;try{await navigator.clipboard.writeText(ta.value);toast("Copied. Paste it into a text or email.")}catch(_){ta.select();toast("Selected. Copy it with your keyboard.")}});

// list price only applies to listings
document.addEventListener("change",e=>{if(e.target.id!=="np-ctype")return;const f=e.target.form,w=f&&f.querySelector(".np-lp");if(w)w.hidden=e.target.value==="Buyer"});
