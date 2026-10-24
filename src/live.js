/* =====================================================================
   Orbyt portal: live data layer (Supabase)
   The screens talk to S.db the same way they did in the prototype.
   This file translates those reads and saves into the Supabase tables.
   ===================================================================== */
const SB_URL="https://wqlsmrkmmbydqsuooshc.supabase.co";
const SB_KEY="sb_publishable_vmIhLd3MJNWkraNwDe4n_Q_DAMFLavF";
let sb=null;
const D={};                       // raw rows, by table
const TABLES=["profiles","vendors","vendor_admin","vendor_private","vendor_notes","projects","project_private","project_admin",
  "project_members","default_shares","bids","invoices","reviews","favorites","task_checks","client_links","my_tasks","time_logs",
  "spend","contacts","market_requests","settings","vendor_agreements"];
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
  let out=[],from=0;
  for(;;){const{data,error}=await sb.from(t).select("*").range(from,from+999);
    if(error){console.error("load "+t,error);return out}
    out=out.concat(data||[]);if(!data||data.length<1000)return out;from+=1000}
}

/* ---------- shaping rows for the screens ---------- */
function appVendors(){const A=byKey(D.vendor_admin,"vendor_id"),P=byKey(D.vendor_private,"vendor_id");
  return(D.vendors||[]).map(v=>{const a=A[v.id]||{},p=P[v.id]||{},coi=(p.insurance_paths||[]).map(x=>"vendor-files:"+x);
    return{id:v.id,userId:v.user_id,name:v.name,contactName:v.contact_name||"",email:v.email||"",phone:v.phone||"",web:v.website||"",
      services:v.services||[],category:(v.services||[])[0]||"",areas:normAreas(v.areas||[]),areaNote:v.area_note||"",years:v.years_in_business||"",
      team:v.team_size||"",leadTime:v.lead_time||"",worksWithAgents:v.works_with_agents||"",portfolioUrl:v.portfolio_url||"",
      photoIds:(v.photo_paths||[]).map(x=>"vendor-photos:"+x),available:v.available!==false,source:v.source||"",createdAt:v.created_at,
      approved:a.vendor_id?!!a.approved:(kind()==="orbyt"?false:true),featured:!!a.featured,licensed:!!a.licensed,insured:!!a.insured,repeatJobs:a.repeat_jobs||0,approvedAt:a.approved_at,
      pricing:p.pricing||{},references:p.references_text||"",heard:p.heard_about||"",signupNotes:p.signup_notes||"",promoInterest:p.promo_interest||"",coiIds:coi,coiId:coi[0]||"",coiUrl:p.coi_url||""}})}
function appProjects(){const PP=byKey(D.project_private,"project_id"),PA=byKey(D.project_admin,"project_id");
  return(D.projects||[]).map(p=>{const pp=PP[p.id]||{},pa=PA[p.id]||{};
    return{id:p.id,agent:p.agent_name,agentId:p.agent_id,agentEmail:p.agent_email||"",agentPhone:p.agent_phone||"",brokerage:p.brokerage||"",
      address:p.address,area:normArea(p.area||""),clientType:p.client_type,targetDate:p.target_date||"",categories:p.categories||[],notes:p.notes||"",
      addedServices:p.added_services||{},listed:!!p.listed,listedAt:p.listed_at,source:p.source||"",createdBy:p.created_by||"",createdAt:p.created_at,
      client:pp.client_name||"",budget:pp.budget||"",pmInterest:pp.pm_interest||"",optionRequests:pp.option_requests||{},
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
  rating:r.rating,comment:r.comment||"",approved:!!r.approved,createdAt:r.created_at}))}
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
const PROJ_MAP={agent:"agent_name",agentEmail:"agent_email",agentPhone:"agent_phone",brokerage:"brokerage",address:"address",area:"area",clientType:"client_type",
  targetDate:"target_date",categories:"categories",notes:"notes",addedServices:"added_services",listed:"listed",listedAt:"listed_at",source:"source",createdBy:"created_by"};
const PPRIV_MAP={client:"client_name",budget:"budget",pmInterest:"pm_interest",optionRequests:"option_requests"};
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
        ${m==="agent"?`<label class="field"><span>Brokerage</span><input type="text" id="su-brokerage" name="brokerage"></label>`:`<label class="field"><span>Website</span><input type="text" id="su-web" name="web"></label>`}</div>
      ${m==="vendor"?`<div class="field"><span>Services you offer</span>${ck("svc",CATS)}</div>
        <label class="field"><span>Other services (optional, separate with commas)</span><input type="text" id="su-othersvc" name="othersvc" list="su-moresvc" placeholder="Pressure washing, junk removal, roof repair"></label>
        <datalist id="su-moresvc">${MORE_SERVICES.map(x=>`<option value="${esc(x)}">`).join("")}</datalist>`:""}
      <div class="field"><span>${m==="agent"?"Where do you list homes?":"Where do you work?"}</span>${ck("area",AREAS)}</div>
      ${m==="vendor"?`<div class="grid">${sel("years","Years in business",YEARS)}${sel("team","Team size",TEAM)}${sel("lead","Typical lead time",LEAD)}</div>
        <label class="field"><span>Agent references (2 to 3 names and numbers)</span><textarea id="su-refs" name="references"></textarea></label>
        <label class="field"><span>How did you hear about Orbyt?</span><input type="text" id="su-heard" name="heard"></label>`:""}
      <div class="grid"><label class="field"><span>Create a password (8+ characters)</span><input type="password" id="su-pass" name="password" autocomplete="new-password" required></label>
        <label class="field"><span>Type it again</span><input type="password" id="su-pass2" name="password2" autocomplete="new-password" required></label></div>${showPw("su-show")}${authMsg()}
      <div class="actions"><button class="btn" type="submit">Join Orbyt</button><button class="btn ghost" type="button" data-act="authmode" data-m="signin">Back to sign in</button></div>
    </form></div></section>`;
}
async function enter(user){
  S.uid=user.id;S.email=user.email;
  const{data:prof}=await sb.from("profiles").select("*").eq("id",user.id).maybeSingle();
  S.me=prof||null;S.authReady=true;
  if(!prof||prof.status==="pending"){S.authMode="pending";S.pendingName=prof&&prof.full_name?prof.full_name.split(" ")[0]:"";render();return}
  if(prof.status==="declined"){S.authMode="declined";render();return}
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
const clientUrl=t=>location.origin+location.pathname+"?quotes="+t;
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
  if(a==="signout"){await sb.auth.signOut();location.href=location.pathname}
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
      const{error}=await sb.auth.resetPasswordForEmail(email,{redirectTo:location.origin+location.pathname});
      return done(error?friendlyAuthError(error):"","If that email has an account, a reset link is on its way.")}
    if(kindOf==="newpass"){if(pass.length<8)return done("Use a password with at least 8 characters.");if(pass!==pass2)return done("Those passwords don't match. Type them again.");
      const{data,error}=await sb.auth.updateUser({password:pass});if(error)return done(friendlyAuthError(error));toast("Password saved");S.authMode="signin";await enter(data.user);return}
    if(kindOf==="signup"){const m=f.dataset.kind,first=String(fd.get("first")||"").trim(),last=String(fd.get("last")||"").trim(),areas=fd.getAll("area");
      const svcs=[...new Set([...fd.getAll("svc"),...String(fd.get("othersvc")||"").split(",").map(x=>x.trim()).filter(Boolean).map(x=>x.charAt(0).toUpperCase()+x.slice(1))])];
      const err=!first||!last?"Add your first and last name.":!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)?"Enter a valid email.":m==="vendor"&&!String(fd.get("company")||"").trim()?"Add your company name."
        :m==="vendor"&&!svcs.length?"Pick or type at least one service you offer.":pass.length<8?"Use a password with at least 8 characters.":pass!==pass2?"Those passwords don't match. Type them again.":"";
      if(err)return done(err);
      const meta={role:m,full_name:first+" "+last,phone:String(fd.get("phone")||"").trim(),areas};
      if(m==="agent")meta.brokerage=String(fd.get("brokerage")||"").trim();
      else Object.assign(meta,{company:String(fd.get("company")).trim(),website:String(fd.get("web")||"").trim(),services:svcs,years_in_business:String(fd.get("years")||""),
        team_size:String(fd.get("team")||""),lead_time:String(fd.get("lead")||""),references:String(fd.get("references")||"").trim(),heard_about:String(fd.get("heard")||"").trim()});
      const{data,error}=await sb.auth.signUp({email,password:pass,options:{data:meta,emailRedirectTo:location.origin+location.pathname}});
      if(error)return done(friendlyAuthError(error));
      if(data.session){S.authErr="";await enter(data.user);return}
      S.pendingEmail=email;S.authMode="checkemail";S.authErr="";if(btn)btn.disabled=false;render();return}
  }catch(x){console.error(x);done("Something went wrong. Check your connection and try again.")}
},true);

async function liveBoot(){
  sb=supabase.createClient(SB_URL,SB_KEY,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:true}});
  const q=new URLSearchParams(location.search);
  if(q.get("quotes")){S.authReady=true;await renderClientPage(q.get("quotes"));return}
  // links from orbytconnect.com: ?join=agent or ?join=vendor opens that sign-up form
  const join=q.get("join");if(join==="agent"||join==="vendor")S.authMode=join;else if(q.has("join"))S.authMode="join";
  sb.auth.onAuthStateChange((ev)=>{if(ev==="PASSWORD_RECOVERY"){S.authMode="newpass";S.authReady=true;S.session=null;render()}});
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
      return `<tr><td><span class="strong">${esc(r.name)}</span>${r.brokerage?`<div class="small">${esc(r.brokerage)}</div>`:""}${r.joined?`<div class="small">Joined ${esc(fmtStamp(r.joined))}</div>`:""}</td>
        <td>${r.email?`<a href="mailto:${esc(r.email)}">${esc(r.email)}</a>`:""}${r.phone?`<div class="small"><a href="tel:${esc(r.phone.replace(/[^\d+]/g,""))}">${esc(r.phone)}</a></div>`:""}</td>
        <td class="small">${esc(r.areas.join(", "))}</td>
        <td class="num">${r.ps.length}${r.ps.length?`<div class="small">${live} active</div>`:""}${last?`<div class="small"><button class="linkbtn" data-act="openmatch" data-id="${esc(last.id)}">${esc(last.address)}</button></div>`:""}${r.sh.length?`<div class="small">Shared on ${r.sh.length}: <button class="linkbtn" data-act="openmatch" data-id="${esc(r.sh[0].id)}">${esc(r.sh[0].address)}</button></div>`:""}</td>
        <td>${pill[r.status]||""}</td>
        <td style="white-space:nowrap">${!r.id?"":r.status==="pending"?`<button class="btn sm" data-act="agstatus" data-id="${esc(r.id)}" data-v="active">Approve</button> <button class="linkbtn" data-act="agstatus" data-id="${esc(r.id)}" data-v="declined">Decline</button>`
          :r.status==="active"?`<button class="linkbtn" data-act="agstatus" data-id="${esc(r.id)}" data-v="declined">Turn off access</button>`:`<button class="linkbtn" data-act="agstatus" data-id="${esc(r.id)}" data-v="active">Turn access back on</button>`}</td></tr>`}).join("")}
    </tbody></table></div>`:`<p class="small">${S.agQ?"No agents match that search.":"No agents yet. They show up here as soon as they sign up."}</p>`}</section>`;
}
document.addEventListener("input",e=>{if(e.target.id!=="ag-q")return;S.agQ=e.target.value;render();const el=$("#ag-q");if(el){el.focus();el.setSelectionRange(el.value.length,el.value.length)}},true);
document.addEventListener("click",e=>{const t=e.target.closest('[data-act="agstatus"]');if(!t||kind()!=="orbyt")return;const v=t.dataset.v;
  guard(async()=>{fail((await sb.rpc("admin_set_user_status",{p_user:t.dataset.id,p_status:v})).error,"status");await S.db.reload()},
    v==="active"?"Access is on. They can sign in now.":"Access is off. They can't sign in, and their projects stay in your desk.")});

/* ---------- Vendor Network Agreement: fees up front, sign once approved ---------- */
const AGREEMENT_VERSION="vendor-v1";
const ENTITY_TYPES=["Sole proprietorship","Limited liability company","Corporation","Partnership"];
function vendorAgreementHtml(d){
  const e=x=>esc(x||""),blank=x=>x?e(x):"<span class=\"agblank\">Not given</span>";
  const ph=(x,label)=>x?e(x):`<span class="agblank">[${label}]</span>`;
  const party=`${ph(d.legal,"business legal name")}, a ${ph(d.state,"state")} ${ph(String(d.entity||"").toLowerCase(),"business type")}${d.dba?` doing business as ${e(d.dba)}`:""}, located at ${ph(d.address,"business address")}`;
  return `<div class="agdoc">
<h2>Vendor Network Agreement</h2>
<p>This Vendor Network Agreement (the <b>"Agreement"</b>) is entered into as of ${e(d.date)} (the <b>"Effective Date"</b>) by and between <b>Orbyt LLC</b>, a California limited liability company located at 711 S Nardo Ave, Suite 308, Solana Beach, California 92075 (<b>"Orbyt"</b>), and ${party} (<b>"Vendor"</b>). Orbyt and Vendor are each a <b>"party"</b> and together the <b>"parties."</b></p>
<p><b>1. How This Works.</b> Orbyt runs an on-demand, trusted vendor network that matches real estate agents with local vendors who can get homes ready to list. When Orbyt introduces Vendor to an agent for a specific listing or project, that is an <b>"Introduction,"</b> and that agent is an <b>"Introduced Agent."</b> The agent or the seller who hires Vendor for a job is the <b>"Client."</b> Orbyt decides which Introductions to make based on what each property needs. Orbyt does not promise any particular number of Introductions or jobs.</p>
<p><b>2. Vendor Standards.</b> Every vendor in the network is licensed and insured, and checked before they join. Vendor agrees to the following for as long as this Agreement is in effect:</p>
<p>(a) <b>Licenses.</b> Vendor will hold and keep current every license, registration, and permit required by law for the services it performs (for example, a California contractor's license where the job requires one).</p>
<p>(b) <b>Insurance.</b> Vendor will carry, at its own cost: commercial general liability insurance of at least $1,000,000 per occurrence and $2,000,000 in aggregate; workers' compensation insurance as required by California law if Vendor has employees; and commercial auto insurance if Vendor uses vehicles for its work. Vendor will send Orbyt a certificate of insurance before joining and any time Orbyt asks, and will tell Orbyt within five (5) business days if any required policy is cancelled, lapses, or is reduced.</p>
<p>(c) <b>Checks.</b> Orbyt may review Vendor's license status, insurance, references, and reviews before Vendor joins and at any time after.</p>
<p>(d) <b>Quality of work.</b> Vendor will do its work professionally, safely, and in line with the law; show up when committed; respond to Clients promptly; and follow each Client's instructions for property access and care of the home.</p>
<p><b>3. Vendor's Work and Its Clients.</b> Vendor quotes, contracts, schedules, invoices, and collects payment for each job directly with the Client, the same way it always does. Orbyt is not a party to Vendor's contract with any Client, does not supervise or direct Vendor's work, and does not guarantee that any Client will pay Vendor. Vendor is solely responsible for its work, its pricing, its warranties, and its employees and subcontractors.</p>
<p><b>4. Fees.</b> Vendor will pay Orbyt the fees in <b>Exhibit A</b> (the <b>"Fee Schedule"</b>). There is no monthly fee during the launch phase.</p>
<p>(a) <b>First job fee.</b> Applies to the first paid job Vendor completes for each Introduced Agent, or for a seller that agent represents.</p>
<p>(b) <b>Repeat fee.</b> Applies to each later job with the same Introduced Agent that is booked or arranged through Orbyt.</p>
<p>(c) <b>Job value.</b> Fees are calculated on the final amount Vendor bills the Client for the job, not including sales tax.</p>
<p>(d) <b>Staging extensions.</b> For staging jobs, fees apply to the initial staging contract only. Monthly extensions while the home is still on the market are not subject to any fee.</p>
<p>(e) <b>Reporting and payment.</b> Within five (5) business days after a job is completed, Vendor will report the final invoice amount to Orbyt. Orbyt may confirm the amount with the Introduced Agent and will then send Vendor an invoice. Payment is due within fifteen (15) days after the job is completed.</p>
<p>(f) <b>Cancelled or unpaid jobs.</b> No fee is owed on a job that is cancelled before any work is done, or for any amount the Client does not pay Vendor. If Vendor later collects that amount, the fee on it is due within fifteen (15) days of collection.</p>
<p>(g) <b>Late payment.</b> If a fee is past due, Orbyt may pause new Introductions and any promoted placement until it is paid. Amounts more than thirty (30) days past due accrue a late charge of 1.5% per month, or the maximum allowed by law if less.</p>
<p>(h) <b>No payments to agents.</b> No part of any fee is paid to or shared with any agent or brokerage.</p>
<p><b>5. First Job Protection.</b> Each Introduction is tied to a specific property (the "Introduced Property") and its seller. If, within twelve (12) months after an Introduction, Vendor does a job for the Introduced Property or its seller (including another property that seller owns or is selling) without reporting it to Orbyt, the first job fee still applies to that job. Vendor will not ask or encourage anyone it met through an Introduction to book outside of Orbyt to avoid the fee. This section does not apply if the Introduced Agent or seller had already contacted Vendor about the Introduced Property before the Introduction. Vendor must tell Orbyt within five (5) business days of the Introduction and share the earlier message, quote, or booking if Orbyt asks. Having worked with that agent or seller in the past does not, by itself, qualify. Work Vendor wins on its own with the Introduced Agent's other clients, without Orbyt's involvement, belongs to Vendor, and only repeat jobs booked through Orbyt carry the repeat fee.</p>
<p><b>6. Promoted Placement.</b> Vendor may choose to run promotions that increase its visibility to agents, at $20 per promotion, for the period stated when the promotion is purchased. Promotions are optional, paid in advance, and non-refundable once live. Orbyt does not guarantee any particular result from a promotion and may decline a promotion that is inaccurate or misleading.</p>
<p><b>7. Profile, Reviews, and Marketing.</b> Vendor will keep the information it gives Orbyt accurate and up to date. Vendor gives Orbyt a non-exclusive, royalty-free right to use Vendor's name, logo, photos of its work, service descriptions, and reviews to build Vendor's profile and to market the Orbyt vendor network, for as long as this Agreement is in effect (and in materials already published when it ends). Vendor confirms it has the right to share any photos or materials it provides, including permission from the homeowner where needed. Orbyt may display reviews from agents and Clients. Vendor will not post, buy, or arrange fake or paid reviews, and Orbyt may remove any review it reasonably believes is not genuine.</p>
<p><b>8. Confidentiality and Client Information.</b> Through Introductions and jobs, Vendor will receive private information, such as listing details before they go public, seller names and contact details, and property access information like lockbox, gate, and alarm codes (<b>"Client Information"</b>). Vendor will use Client Information only to do the job, keep it private, and share it only with its own team members who need it for the job. Vendor will not post photos, addresses, or details of a Client's home publicly without the Client's permission. Vendor will also keep Orbyt's non-public business information private, including its pricing, agent relationships, and plans. These obligations continue for two (2) years after this Agreement ends, and for property access information, for as long as it could still be used.</p>
<p><b>9. Independent Businesses.</b> Orbyt and Vendor are independent businesses. Neither is the other's employee, partner, joint venturer, or agent. Vendor is responsible for its own taxes and for the wages, benefits, and insurance of its employees and subcontractors. This Agreement is not exclusive: Vendor is free to work with anyone, and Orbyt is free to introduce other vendors in the same category. Orbyt is not a real estate broker and does not provide real estate, legal, construction, or design services under this Agreement.</p>
<p><b>10. Term and Ending This Agreement.</b> This Agreement starts on the Effective Date and continues until either party ends it. Either party may end it at any time with fourteen (14) days' written notice (email is fine). Orbyt may pause Introductions or end this Agreement right away if Vendor's required license or insurance lapses, if there is a safety concern or serious Client complaint, or if Vendor breaches this Agreement. After this Agreement ends, Vendor still owes fees for jobs that came from Introductions made before the end date, and Section 5 still applies to those Introductions.</p>
<p><b>11. Changes to Fees.</b> Orbyt may change the Fee Schedule or introduce subscription plans by giving Vendor at least thirty (30) days' notice by email. Changes apply only to Introductions made after the change takes effect. If Vendor does not agree to a change, Vendor may end this Agreement under Section 10 before the change takes effect.</p>
<p><b>12. Indemnity.</b> Vendor will defend, indemnify, and hold harmless Orbyt and its owners from any claims, losses, damages, and costs (including reasonable attorneys' fees) arising from Vendor's work, any property damage or injury caused by Vendor or its employees or subcontractors, Vendor's breach of this Agreement, or Vendor's violation of any law.</p>
<p><b>13. Limitation of Liability.</b> Neither party will be liable to the other for indirect, incidental, or consequential damages, such as lost profits, except for Vendor's obligations under Section 12 (Indemnity) and either party's breach of Section 8 (Confidentiality). Orbyt's total liability under this Agreement will not exceed the fees Vendor paid Orbyt in the twelve (12) months before the claim arose.</p>
<p><b>14. General.</b> This Agreement is governed by California law, and any dispute will be handled in the state or federal courts located in San Diego County, California. Notices may be sent by email to the addresses in the signature block. This Agreement, including Exhibits A and B, is the entire agreement between the parties about the vendor network and replaces any earlier discussions about it, except that any confidentiality agreement the parties signed before the Effective Date stays in effect for information shared under it. Except for fee changes under Section 11, any changes must be agreed in writing, and email from both parties counts. Vendor may not transfer this Agreement without Orbyt's written consent, except to a buyer of Vendor's business who agrees to its terms. If any part of this Agreement is found unenforceable, the rest stays in effect. Sections 4, 5, 8, 12, 13, and 14 survive after this Agreement ends. This Agreement may be signed electronically and in counterparts, and electronic and PDF signatures count as originals.</p>
<p>Agreed and accepted by the parties as of the Effective Date.</p>
<table class="agsig"><thead><tr><th>Orbyt LLC</th><th>${e(d.legal)}</th></tr></thead><tbody>
<tr><td>By: <span class="agsign">Ashleigh Stumler</span> (signed electronically)</td><td>By: ${d.signer?`<span class="agsign">${e(d.signer)}</span> (signed electronically)`:"<span class=\"agblank\">Signed when you click Agree</span>"}</td></tr>
<tr><td>Name: Ashleigh Stumler</td><td>Name: ${blank(d.signer)}</td></tr>
<tr><td>Title: Founder</td><td>Title: ${blank(d.title)}</td></tr>
<tr><td>Email: ashleigh@orbytconnect.com</td><td>Email: ${blank(d.email)}</td></tr>
<tr><td>Date: ${e(d.date)}</td><td>Date: ${e(d.date)}</td></tr></tbody></table>
<h3>Exhibit A: Fee Schedule (Launch Phase)</h3>
<p>Vendor pays only when an Introduction turns into a job. There is no monthly fee during the launch phase.</p>
<p><b>First job with a new Introduced Agent.</b> Sliding scale by job value. Each portion of the job is charged at its own rate, like tax brackets, so a bigger job never moves to a higher rate.</p>
<table class="agtable"><thead><tr><th>Portion of job value</th><th>Rate</th></tr></thead><tbody><tr><td>First $1,000</td><td>12%</td></tr><tr><td>$1,001 to $5,000</td><td>8%</td></tr><tr><td>Above $5,000</td><td>5%</td></tr></tbody></table>
<p>$25 minimum and $600 cap per job.</p>
<p><b>Repeat job with the same Introduced Agent, booked through Orbyt.</b> Flat 2% of job value. $15 minimum and $100 cap per job.</p>
<p><b>Promoted placement (optional).</b> $20 per promotion.</p>
<p><b>Example.</b> A $3,000 staging as a first job is $120 on the first $1,000 plus $160 on the next $2,000, for a $280 fee. A repeat staging of the same size with the same agent is $60.</p>
<h3>Exhibit B: Vendor Information</h3>
<table class="agtable"><tbody>
<tr><th>Business legal name</th><td>${blank(d.legal)}</td></tr><tr><th>DBA (if any)</th><td>${blank(d.dba)}</td></tr>
<tr><th>Service category</th><td>${blank(d.services)}</td></tr><tr><th>Service area</th><td>${blank(d.areas)}</td></tr>
<tr><th>License type and number</th><td>${blank(d.license)}</td></tr><tr><th>General liability carrier and policy number</th><td>${blank(d.carrier)}</td></tr>
<tr><th>Coverage limits</th><td>${blank(d.limits)}</td></tr><tr><th>Policy expiration date</th><td>${blank(d.expires)}</td></tr>
<tr><th>Workers' comp (if employees)</th><td>${blank(d.workcomp)}</td></tr><tr><th>Certificate of insurance attached</th><td>${e(d.coi||"No")}</td></tr>
<tr><th>Listings already discussed with an agent or seller before the Introduction (see Section 5)</th><td>${blank(d.prior)}</td></tr></tbody></table>
</div>`;
}
const myVendorId=()=>kind()==="vendor"?roleVal():"";
const agreementsFor=vid=>(D.vendor_agreements||[]).filter(a=>a.vendor_id===vid).sort((a,b)=>String(b.signed_at).localeCompare(String(a.signed_at)));
const currentAgreement=vid=>agreementsFor(vid).find(a=>a.version===AGREEMENT_VERSION);
function needsAgreement(){const v=vendorById(myVendorId());return !!(v&&v.approved!==false&&S.loaded.vendors&&!currentAgreement(v.id))}
const todayLong=()=>new Date().toLocaleDateString("en-US",{month:"long",day:"numeric",year:"numeric"});
function agreementDraft(v){const f=S.agForm||{};
  return{date:todayLong(),legal:f.legal??v.name,entity:f.entity||"",state:f.state??"California",dba:f.dba||"",address:f.address||"",signer:f.signer||"",title:f.title||"",
    email:S.me&&S.me.email||vEmail(v),services:vsv(v).join(", "),areas:(v.areas||[]).join(", "),license:f.license||"",carrier:f.carrier||"",limits:f.limits||"",expires:f.expires||"",
    workcomp:f.workcomp||"",coi:(v.coiIds||[]).length?"Yes, on file with Orbyt":"No, sending separately",prior:f.prior||""}}
function feeCalc(){const x=Number(S.agCalc||0);
  return `<div class="feecalc"><label class="field"><span>Try a job value ($)</span><input type="number" id="ag-calc" min="0" step="50" value="${esc(S.agCalc||"")}" placeholder="3000"></label>
    <p class="small" id="ag-calc-out" style="margin:0">${x>0?`First job with a new agent: <b>${money2(feeFirst(x))}</b> (${(feeFirst(x)/x*100).toFixed(1)}%). Repeat job with that agent: <b>${money2(feeRepeat(x))}</b>.`:"Enter an amount to see both fees."}</p></div>`}
function agreementGate(){
  const v=vendorById(myVendorId()),d=agreementDraft(v),f=S.agForm||{},first=String(v.contactName||"").split(" ")[0]||v.name;
  const fld=(k,label,opts={})=>`<label class="field"><span>${label}</span><input type="${opts.type||"text"}" id="ag-${k}" name="${k}" value="${esc(f[k]??(k==="legal"?v.name:k==="state"?"California":""))}" ${opts.req?"required":""} ${opts.ph?`placeholder="${esc(opts.ph)}"`:""}></label>`;
  return `<section class="hello"><div><div class="eyebrow">Welcome to the Orbyt network</div><h1>You're approved, ${esc(first)}</h1>
    <p>Before your first introduction, here's exactly what Orbyt costs, and the agreement to sign. It takes about five minutes.</p></div></section>
  <section class="section agfees"><h2>What you pay, and when</h2>
    <p><b>You only pay when an introduction turns into a paid job.</b> No monthly fee and no sign-up fee during launch. The client pays you directly, the same as always.</p>
    <div class="feegrid">
      <div class="feecard"><span class="eyebrow">First job with a new agent</span><table class="agtable"><tbody><tr><td>First $1,000</td><td>12%</td></tr><tr><td>$1,001 to $5,000</td><td>8%</td></tr><tr><td>Above $5,000</td><td>5%</td></tr></tbody></table>
        <p class="small" style="margin:0">Each portion is charged at its own rate, like tax brackets. $25 minimum, $600 cap per job.</p></div>
      <div class="feecard"><span class="eyebrow">Repeat jobs with that agent</span><p class="feebig">2%</p><p class="small" style="margin:0">When they book you again through Orbyt. $15 minimum, $100 cap per job. Work you win on your own with an agent's other clients is all yours.</p></div>
      <div class="feecard"><span class="eyebrow">Never a fee on</span><p class="small" style="margin:0">Staging extensions while a home is on the market, jobs cancelled before work starts, or anything the client doesn't pay you.</p>
        <span class="eyebrow" style="margin-top:10px;display:block">Optional</span><p class="small" style="margin:0">Promoted placement, $20 per promotion.</p></div></div>
    <p class="small"><b>Example:</b> a $3,000 first job is $120 on the first $1,000 plus $160 on the next $2,000, for a $280 fee. The same job as a repeat is $60.</p>
    ${feeCalc()}
    <p class="small" style="margin:0"><b>When it's due:</b> report your final invoice amount within 5 business days of finishing a job (you can do it right on the job in the portal). Orbyt sends an invoice, due 15 days after the job wraps. Fees more than 30 days past due add 1.5% a month, and new introductions pause until they're paid.</p></section>
  <form class="form" data-form="signagreement" novalidate><h2>Your business details</h2><p class="small" style="margin:0">These fill in the agreement below.</p>
    <div class="grid">${fld("legal","Business legal name",{req:1})}
      <label class="field"><span>Business type</span><select id="ag-entity" name="entity" required><option value="">Choose one</option>${ENTITY_TYPES.map(x=>`<option ${f.entity===x?"selected":""}>${x}</option>`).join("")}</select></label>
      ${fld("state","State where it's registered",{req:1})}${fld("dba","DBA, if any")}</div>
    ${fld("address","Business address",{req:1,ph:"Street, city, state, ZIP"})}
    <div class="grid">${fld("license","License type and number",{ph:"For example, C-33 Painting #123456"})}${fld("carrier","Liability insurance carrier and policy number")}
      ${fld("limits","Coverage limits",{ph:"$1M per occurrence / $2M aggregate"})}${fld("expires","Policy expiration date",{type:"date"})}${fld("workcomp","Workers' comp (if you have employees)",{ph:"Carrier and policy number, or None"})}</div>
    <label class="field"><span>Any listings you'd already discussed with an agent or seller before Orbyt? (optional)</span><textarea id="ag-prior" name="prior" rows="2">${esc(f.prior||"")}</textarea></label>
    <h2 style="margin-top:8px">The agreement</h2>
    <div class="agbox" tabindex="0" aria-label="Vendor Network Agreement">${vendorAgreementHtml(d)}</div>
    <div class="actions"><button class="linkbtn" type="button" data-act="agprint">Print or save a copy</button></div>
    <div class="grid">${fld("signer","Your full name (this is your signature)",{req:1})}${fld("title","Your title",{req:1,ph:"Owner"})}</div>
    <label class="checkrow"><input type="checkbox" id="ag-ok" name="ok"> I've read the Vendor Network Agreement, including the Fee Schedule in Exhibit A, and I agree to it on behalf of the business named above.</label>
    <p class="small warntext agerr" role="alert" style="margin:0" hidden></p>
    <div class="actions"><button class="btn" type="submit">Agree and sign</button><button class="btn ghost" type="button" data-act="signout">Sign out</button></div></form>`;
}
function agreementViewer(){
  const a=(D.vendor_agreements||[]).find(x=>x.id===S.agreementView);if(!a){S.agreementView=null;return""}
  return `<div class="scrim" data-act="agclose"></div><div class="vcard wide" role="dialog" aria-modal="true" aria-labelledby="ag-title">
    <div class="vchead"><div style="min-width:0"><div class="eyebrow">Signed ${esc(fmtStamp(a.signed_at))} by ${esc(a.signer_name)}</div><h2 id="ag-title" style="font-weight:500;margin-top:4px">Vendor Network Agreement</h2></div>
      <button class="xbtn" id="ag-close" data-act="agclose" aria-label="Close">×</button></div>
    <div class="actions"><button class="btn ghost sm" data-act="agprint" data-id="${esc(a.id)}">Print or save as PDF</button></div>
    <div class="agbox tall">${a.document_html}</div></div>`;
}
function agreementLine(v){if(!v.userId&&!agreementsFor(v.id).length)return"";const a=currentAgreement(v.id)||agreementsFor(v.id)[0];
  return a?`<p class="small" style="margin:6px 0 0">Agreement signed ${esc(fmtStamp(a.signed_at))} by ${esc(a.signer_name)}${a.signer_title?", "+esc(a.signer_title):""} · <button class="linkbtn" data-act="agview" data-id="${esc(a.id)}">View agreement</button></p>`
    :`<p class="small warntext" style="margin:6px 0 0">${v.approved===false?"They'll see the fees and sign the agreement right after you approve them.":"Agreement not signed yet. They'll be asked when they next sign in."}</p>`}
const agreementPill=v=>v.userId&&v.approved!==false&&!currentAgreement(v.id)?' <span class="pill late">Agreement not signed</span>':"";
const myAgreementBtn=()=>{if(kind()!=="vendor")return"";const a=currentAgreement(myVendorId());return a?`<button class="linkbtn" data-act="agview" data-id="${esc(a.id)}">My agreement</button>`:""};
function printAgreement(html){
  const w=window.open("","_blank");if(!w){toast("Allow pop-ups for this site to print the agreement.");return}
  w.document.write(`<!doctype html><html><head><meta charset="utf-8"><title>Orbyt Vendor Network Agreement</title><style>body{font:15px/1.55 Georgia,serif;max-width:760px;margin:40px auto;padding:0 20px;color:#111}
    h2{font-size:22px}h3{font-size:17px;margin-top:28px}table{border-collapse:collapse;width:100%;margin:10px 0}td,th{border:1px solid #bbb;padding:6px 8px;text-align:left;vertical-align:top;font-size:14px}
    .agsign{font-style:italic;font-size:17px}.agblank{color:#888}<\/style></head><body>${html}</body></html>`);
  w.document.close();w.focus();setTimeout(()=>w.print(),300);
}
document.addEventListener("input",e=>{const el=e.target;
  if(el.id==="ag-calc"){S.agCalc=el.value;const x=Number(el.value||0),out=$("#ag-calc-out");if(out)out.innerHTML=x>0?`First job with a new agent: <b>${money2(feeFirst(x))}</b> (${(feeFirst(x)/x*100).toFixed(1)}%). Repeat job with that agent: <b>${money2(feeRepeat(x))}</b>.`:"Enter an amount to see both fees.";return}
  const f=el.closest&&el.closest('form[data-form="signagreement"]');if(!f||!el.name||el.name==="ok")return;
  S.agForm={...(S.agForm||{}),[el.name]:el.value};
  const box=f.querySelector(".agbox");if(box){const v=vendorById(myVendorId());if(v){const top=box.scrollTop;box.innerHTML=vendorAgreementHtml(agreementDraft(v));box.scrollTop=top}}},true);
document.addEventListener("change",e=>{const el=e.target;const f=el.closest&&el.closest('form[data-form="signagreement"]');if(!f||el.tagName!=="SELECT")return;
  S.agForm={...(S.agForm||{}),[el.name]:el.value};const box=f.querySelector(".agbox"),v=vendorById(myVendorId());if(box&&v)box.innerHTML=vendorAgreementHtml(agreementDraft(v))},true);
document.addEventListener("click",e=>{const t=e.target.closest("[data-act]");if(!t)return;const a=t.dataset.act;
  if(a==="agview"){S.vendorCard=null;S.agreementView=t.dataset.id;render();$("#ag-close")?.focus()}
  else if(a==="agclose"){S.agreementView=null;render()}
  else if(a==="agprint"){const rec=t.dataset.id&&(D.vendor_agreements||[]).find(x=>x.id===t.dataset.id);
    if(rec)printAgreement(rec.document_html);else{const v=vendorById(myVendorId());if(v)printAgreement(vendorAgreementHtml(agreementDraft(v)))}}},true);
document.addEventListener("keydown",e=>{if(e.key==="Escape"&&S.agreementView){S.agreementView=null;render()}});
document.addEventListener("submit",e=>{const f=e.target.closest('form[data-form="signagreement"]');if(!f)return;e.preventDefault();e.stopImmediatePropagation();
  const v=vendorById(myVendorId());if(!v)return;const fd=new FormData(f),g=k=>String(fd.get(k)||"").trim();
  S.agForm={...(S.agForm||{}),legal:g("legal"),entity:g("entity"),state:g("state"),dba:g("dba"),address:g("address"),license:g("license"),carrier:g("carrier"),limits:g("limits"),
    expires:g("expires"),workcomp:g("workcomp"),prior:g("prior"),signer:g("signer"),title:g("title")};
  const err=!g("legal")?"Add your business's legal name.":!g("entity")?"Choose your business type.":!g("state")?"Add the state where your business is registered.":!g("address")?"Add your business address.":
    g("signer").split(/\s+/).filter(Boolean).length<2?"Type your full first and last name to sign.":!g("title")?"Add your title, like Owner.":!fd.get("ok")?"Check the box to agree to the Vendor Network Agreement.":"";
  const el=f.querySelector(".agerr");if(err){if(el){el.textContent=err;el.hidden=false;el.scrollIntoView({block:"nearest"})}return}
  const d=agreementDraft(v);
  guard(async()=>{
    const r=await sb.from("vendor_agreements").insert({vendor_id:v.id,version:AGREEMENT_VERSION,signer_name:d.signer,signer_title:d.title,signer_email:d.email,legal_name:d.legal,
      details:{entity:d.entity,state:d.state,dba:d.dba,address:d.address,license:d.license,carrier:d.carrier,limits:d.limits,expires:d.expires,workcomp:d.workcomp,prior:d.prior},
      document_html:vendorAgreementHtml(d),user_agent:navigator.userAgent.slice(0,300)});
    fail(r.error,"agreement");S.agForm=null;await S.db.reload();window.scrollTo({top:0})},"Signed. Welcome to Orbyt! A copy is under My agreement any time.")},true);
