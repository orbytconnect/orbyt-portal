"""Turns src/terms/*.md into the public terms pages at site/terms/*.html."""
import pathlib, subprocess, html
HERE = pathlib.Path(__file__).resolve().parent
OUT = HERE.parent / "site" / "terms"; OUT.mkdir(parents=True, exist_ok=True)
PAGES = {"vendor-terms.md": ("vendor.html", "Orbyt Vendor Terms of Use"), "agent-terms.md": ("agent.html", "Orbyt Agent Terms of Use"), "privacy.md": ("../privacy.html", "Orbyt Privacy Policy")}
TPL = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{title}</title>
<style>
:root{{--bg:#F6F4EA;--surface:#FFFFFF;--ink:#18314F;--muted:#5E6E83;--line:#E3DFD0;--teal:#1F6F6B}}
*{{box-sizing:border-box}}
body{{margin:0;background:var(--bg);color:var(--ink);font:16px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}}
.bar{{max-width:820px;margin:0 auto;padding:18px 16px 0;display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap}}
.bar a{{color:var(--teal)}} .brand{{font-weight:600;letter-spacing:.02em;text-decoration:none;color:var(--ink)!important}}
main{{max-width:820px;margin:14px auto 48px;padding:8px 28px 28px;background:var(--surface);border:1px solid var(--line);border-radius:12px}}
h1{{font-size:26px;font-weight:600;margin:22px 0 4px}} h2{{font-size:19px;font-weight:600;margin:30px 0 8px}}
p{{margin:0 0 12px}} blockquote{{margin:0 0 12px;padding:0 0 0 18px;border-left:3px solid var(--line)}}
table{{border-collapse:collapse;width:100%;margin:8px 0 14px}} th,td{{border:1px solid var(--line);padding:6px 10px;text-align:left}}
button{{font:inherit;color:var(--teal);background:none;border:0;padding:0;text-decoration:underline;cursor:pointer}}
@media (max-width:600px){{main{{padding:4px 16px 20px;border-radius:0;border-left:0;border-right:0}}}}
@media print{{.bar{{display:none}}body{{background:#fff}}main{{border:0;margin:0;max-width:none}}}}
</style></head>
<body><div class="bar"><a class="brand" href="https://www.orbytconnect.com">Orbyt</a><span><button type="button" onclick="print()">Print or save as PDF</button></span></div>
<main>
{body}
</main></body></html>
"""
for src, (out, title) in PAGES.items():
    body = subprocess.run(["pandoc", str(HERE / "terms" / src), "-f", "markdown", "-t", "html5"], check=True, capture_output=True, text=True).stdout
    dest = (OUT / out).resolve(); dest.write_text(TPL.format(title=html.escape(title), body=body))
    print("wrote", dest.relative_to(HERE.parent / "site"), len(body), "bytes")
