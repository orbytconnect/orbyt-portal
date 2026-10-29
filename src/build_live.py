import re, pathlib, sys
HERE = pathlib.Path(__file__).resolve().parent
src = (HERE / "orbyt-portal.html").read_text()
live = (HERE / "live.js").read_text()
L = src.split("\n")

def find(prefix, start=0):
    for i in range(start, len(L)):
        if L[i].startswith(prefix):
            return i
    sys.exit("missing marker: " + prefix)

i_proto = find("/* ---------- prototype backend")
i_team = find("/* ---------- agent profile and project teams")
i_boot = find("/* ---------- boot ----------")
i_end = find("</script>", i_boot)

head = "\n".join(L[:i_proto])
team = "\n".join(L[i_team:i_boot])
tail = "\n".join(L[i_end:])

# team block: drop the prototype versions of agentProfile and isOnProject (live.js has its own)
team = re.sub(r"function agentProfile\(name\)\{.*?\n\}\n", "", team, count=1, flags=re.S)
team = re.sub(r"function isOnProject\(p,agent\)\{.*?\n\}\n", "", team, count=1, flags=re.S)
team = team.replace('const status=m=>{const a=accountFor(m.email);return a&&a.role?"Has access":"Invite sent"};',
                    'const status=m=>m.userId?"Has access":"Invite sent";')
assert "accountFor" not in team and "function agentProfile" not in team and "function isOnProject" not in team

out = head + "\n" + team + "\n" + live + """
document.addEventListener("keydown",e=>{if(e.key==="Escape"&&S.quoteView){S.quoteView=null;render()}});
liveBoot();
""" + tail

def sub(old, new, count=1):
    global out
    n = out.count(old)
    if n != count:
        sys.exit(f"expected {count} of: {old[:80]!r}, found {n}")
    out = out.replace(old, new)

# full HTML document for hosting
sub('<title>Orbyt Portal</title>\n<meta name="claude:viewport-fit-sides" content="cover">',
    '<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n<meta name="viewport" content="width=device-width,initial-scale=1">\n<title>Orbyt Portal</title>\n<meta name="robots" content="noindex">')
sub("</style>", """.quoteframe{width:100%;height:70vh;border:1px solid var(--line);border-radius:8px;background:#fff}
.clientpage{max-width:760px;margin:28px auto 40px}
.clientpage h1{margin:6px 0 4px}
</style>
</head>
<body>""")
sub("\n<script>\n/* typical order", '\n<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.117.3/dist/umd/supabase.js"></script>\n<script>\n/* typical order')
out = out.rstrip() + "\n</body>\n</html>\n"

# no saved prototype session
sub('S.session=localStorage.getItem("orbyt-portal-session")||null;if(S.session)S.role=S.session;', '')
# sign-in screen comes before the loading screen
sub("""  if(!allLoaded()&&!S.dbMissing)h+=`<div class="emptystate" style="margin-top:28px"><h2>Loading the desk</h2><p>Pulling in projects, vendors, bids and tasks.</p></div>`;
  else if(!S.session)h=protoBanner()+authView();""",
"""  if(!S.session)h=authView();
  else if(!allLoaded()&&!S.dbMissing)h+=`<div class="emptystate" style="margin-top:28px"><h2>Loading</h2><p>Pulling in your projects.</p></div>`;""")
# private link instead of the "coming soon" note
sub("""<p class="small" style="margin:0">A private link to this page is coming with the full Orbyt site. For now, send the message and screenshot this view if it helps.</p></div>`;""",
    """${clientLinkBlock(p)}</div>`;""")
sub("Your client sees vendor names, prices, timelines, ratings and the quote PDFs.",
    "Your client sees vendor names, prices, timelines and ratings.")
# Agents tab for Ashleigh
sub('''["vendors","Vendors and reviews",S.vendors.filter(v=>v.approved===false).length+pending],''',
    '''["vendors","Vendors and reviews",S.vendors.filter(v=>v.approved===false).length+pending],["agents","Agents",(D.profiles||[]).filter(p=>p.role==="agent"&&p.status==="pending").length],''')
sub('''["dash","pipeline","projects","vendors","invoicing","reports"].includes(S.tab)''', '''["dash","pipeline","projects","vendors","agents","invoicing","reports"].includes(S.tab)''')
sub('''  if(S.tab==="vendors")return h+rosterView();''', '''  if(S.tab==="vendors")return h+rosterView();
  if(S.tab==="agents")return h+agentsView();''')
# Vendor Network Agreement
sub("""h+=protoBanner()+(k==="vendor"?vendorView():""", """h+=protoBanner()+(showTermsGate()?termsGate():k==="vendor"?vendorView():""")
sub("""  if(S.quoteView&&S.session)h+=quoteViewer();""", """  if(S.quoteView&&S.session)h+=quoteViewer();
  else if(S.agreementView&&S.session)h+=agreementViewer();
  else if(S.myDetails&&S.session&&typeof myDetailsView==="function")h+=myDetailsView();""")
sub("""<button class="btn ghost sm" data-act="signout">Sign out</button>`;""", """${myAgreementBtn()}<button class="btn ghost sm" data-act="signout">Sign out</button>`;""")
sub("""v.insured?"Insurance checked":"Insurance not checked"}</p>""", """v.insured?"Insurance checked":"Insurance not checked"}</p>${agreementLine(v)}${kind()==="orbyt"?insuranceAdminLine(v)+businessLine(v)+reviewReqLine(v):""}""")
sub("""${v.approved===false?'<span class="pill late">Needs review</span>':""} ${v.featured?'<span class="pill featured">Featured</span>':""} ${v.sample?""", """${v.approved===false?'<span class="pill late">Needs review</span>':""}${agreementPill(v)} ${v.featured?'<span class="pill featured">Featured</span>':""} ${v.sample?""")
sub("Approved. They can be matched now.", "Approved. Next time they sign in, they'll see the fees, then they're ready for introductions.")
sub(".vcard.wide{width:min(720px,calc(100% - 32px))}", """.vcard.wide{width:min(720px,calc(100% - 32px))}
.agbox{max-height:420px;overflow:auto;border:1px solid var(--line);border-radius:10px;background:var(--surface);padding:6px 22px}.agbox.tall{max-height:68vh}
.insemail{width:100%;font:13px/1.5 inherit;margin:8px 0 4px;padding:10px;border:1px solid var(--line);border-radius:8px;background:var(--surface-2);color:var(--ink);resize:vertical}
.steps{margin:6px 0 0;padding-left:20px}.steps>li{margin:0 0 14px}.form.inner{margin:8px 0 0;padding:0;border:0;background:none}.insmore summary{cursor:pointer;margin-top:8px}.insnote{margin:0}
.canew[hidden],.np-lp[hidden]{display:none!important}
.folds .fold{border:1px solid var(--line);border-radius:12px;background:var(--surface);margin:0 0 10px}.fold>summary{cursor:pointer;list-style:none;display:flex;flex-wrap:wrap;align-items:center;gap:6px 10px;padding:14px 16px}
.fold>summary::-webkit-details-marker{display:none}.fold>summary::before{content:"";width:8px;height:8px;border-right:2px solid var(--muted);border-bottom:2px solid var(--muted);transform:rotate(-45deg);transition:transform .15s;margin-right:4px}
.fold[open]>summary::before{transform:rotate(45deg)}.foldtitle{font-weight:500}.foldhint{flex-basis:100%;margin-left:22px}@media(min-width:700px){.foldhint{flex-basis:auto;margin-left:auto}}
.foldbody{padding:0 16px 16px}.foldbody>section,.foldbody>.section{margin:0!important;padding:0;border:0;background:none;box-shadow:none}.foldbody>section>.sechead:first-child h2,.foldbody>section>.sechead:first-child>div>h2{display:none}
.statuslist{list-style:none;margin:4px 0 8px;padding:0;display:grid;gap:6px}.statuslist li{display:flex;gap:10px;align-items:flex-start}.statuslist .tick{flex:none;width:20px;height:20px;border-radius:50%;border:1.5px solid var(--line);display:inline-flex;align-items:center;justify-content:center;font-size:12px;margin-top:1px}
.statuslist li.isdone .tick{background:var(--teal-text);border-color:var(--teal-text);color:var(--surface)}.statuslist li.todo{color:var(--muted)}
.seg{display:inline-flex;border:1px solid var(--line);border-radius:999px;overflow:hidden;margin:10px 0 4px}.segbtn{font:inherit;font-size:14px;border:0;background:none;color:var(--ink);padding:6px 14px;cursor:pointer}.segbtn.on{background:var(--ink);color:var(--surface)}.checkrow.top{align-items:flex-start}.btn.danger{background:var(--warn);border-color:var(--warn);color:#fff}.delrow td{background:var(--surface-2)}.checkrow.top input{margin-top:3px}.tldr{margin:6px 0 10px;padding-left:20px}.tldr li{margin:4px 0}
.agdoc{font-size:14px;line-height:1.6}.agdoc h2{font-size:20px;font-weight:500;margin:14px 0 8px}.agdoc h3{font-size:16px;font-weight:500;margin:22px 0 6px}.agdoc p{margin:0 0 10px}
.agtable,.agsig{border-collapse:collapse;width:100%;min-width:0;margin:8px 0 12px;font-size:14px}.agtable th,.agsig th{font-size:14px;text-transform:none;letter-spacing:0;white-space:normal;background:none}.agtable td,.agtable th,.agsig td,.agsig th{border:1px solid var(--line);padding:6px 8px;text-align:left;vertical-align:top;font-weight:400}
.agtable th{width:45%;color:var(--ink-2)}.agsig th{font-weight:500}.agsign{font-style:italic;font-size:16px}.agblank{color:var(--muted)}
.feegrid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:12px;margin:12px 0}.feecard{border:1px solid var(--line);border-radius:10px;background:var(--surface);padding:14px 16px}
.feecard .agtable{margin:8px 0}.feebig{font-size:30px;margin:6px 0}.feecalc{display:flex;flex-wrap:wrap;gap:8px 18px;align-items:end;margin:6px 0 12px}.feecalc .field{max-width:200px}
.reviewagree{border-top:1px solid var(--line);padding-top:16px;display:flex;flex-direction:column;gap:12px}.reviewagree h2{font-size:20px;font-weight:500;margin:6px 0 0}.reviewagree .feegrid{margin:0}.reviewagree .tldr{margin:0}
.field small{color:var(--muted);font-size:12px;margin-bottom:4px}.rrrows{display:flex;flex-direction:column;gap:8px}.rrcard .tablewrap{margin-top:10px}
.starpick{display:inline-flex;flex-direction:row-reverse;justify-content:flex-end;gap:6px;margin-top:4px}.starpick input{position:absolute;opacity:0;width:1px;height:1px}
.starpick label{font-size:32px;line-height:1;color:var(--line);cursor:pointer}.starpick input:checked~label,.starpick label:hover,.starpick label:hover~label{color:var(--star)}
.starpick input:focus-visible+label{outline:2px solid var(--focus);outline-offset:2px;border-radius:4px}""")
# review requests: invite card on the vendor dashboard, and "Past client" labels wherever reviews show

sub('<span class="rating"><b>${"\u2605".repeat(r.rating)}</b><span class="small">${"\u2605".repeat(5-r.rating)}</span></span></div>',
    '<span class="rating"><b>${"\u2605".repeat(r.rating)}</b><span class="small">${"\u2605".repeat(5-r.rating)}</span></span>${revSource(r)}</div>')
sub('${esc(r.agent||"Agent")} · ${esc(p?p.address:"")} · ${ago(r.createdAt)}', '${esc(revWho(r))}${p?" · "+esc(p.address):""} · ${ago(r.createdAt)}')
sub('${esc(r.comment||"")}<div class="small">${esc(r.agent||"Agent")}, ${ago(r.createdAt)}</div></blockquote>',
    '${esc(r.comment||"")}<div class="small">${esc(revWho(r))}, ${ago(r.createdAt)}${revSource(r)}</div></blockquote>')
sub('A.push({id:"newrev-"+r.id,cls:"k-bid",label:"New review",', 'A.push({id:"newrev-"+r.id,cls:"k-bid",label:r.source==="past_client"?"Past client review":"New review",')
# only Orbyt can create introductions in the database, so automatic matching runs from Ashleigh's side
sub("if(auto)for(const c of cats)", "if(auto&&kind()===\"orbyt\")for(const c of cats)")
sub("if(auto)for(const c of add)", "if(auto&&kind()===\"orbyt\")for(const c of add)")
# remove Wix export and sample data buttons
sub("""${S.downloads?`<button class="btn ghost" data-act="form" data-key="wixexport">Export for Wix</button>`:""}""", "")
sub("""${noData?`<button class="btn ghost" data-act="loadsamples">Load example data</button>`:""}""", "")
sub("""${noData?" Want to see it working first? Load example vendors, listings and tasks, and clear them whenever you like.":""}""", "")
# vendor without a profile row
sub("""<h2>Pick a vendor</h2><p>Choose a vendor in "Viewing as" to see their requests.</p>""",
    """<h2>Your profile is almost ready</h2><p>Ashleigh is finishing your vendor profile. Email ashleigh@orbytconnect.com if this doesn't clear up within a day.</p>""")

for bad in ["makeMockDb", "mockAssets", "seedPrototype", "DEMO_AGENT_EMAILS", "orbyt-portal-proto"]:
    if bad in out:
        sys.exit("leftover prototype code: " + bad)

d = HERE.parent / "site"; d.mkdir(exist_ok=True)
(d / "index.html").write_text(out)
import subprocess; subprocess.run([sys.executable, str(HERE / "build_terms.py")], check=True)
print("wrote", len(out), "bytes")
