#!/usr/bin/env python3
"""Build the static Kah site and a self-contained Cloudflare Worker module."""
import hashlib
import html
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'build' / 'kah-site'


def inline(text):
    text = html.escape(text)
    text = re.sub(r'`([^`]+)`', r'<code>\1</code>', text)
    text = re.sub(r'\*\*([^*]+)\*\*', r'<strong>\1</strong>', text)
    return re.sub(r'\[([^\]]+)\]\(([^)]+)\)', r'<a href="\2">\1</a>', text)


def render_guide(source):
    # The guide is trusted repository Markdown with headings, lists, tables,
    # paragraphs, and fenced code. No user input or external HTML is accepted.
    out, paragraph, in_code, code, in_list, table = [], [], False, [], False, []

    def flush():
        nonlocal paragraph, in_list, table
        if paragraph:
            out.append('<p>' + inline(' '.join(paragraph)) + '</p>'); paragraph = []
        if in_list:
            out.append('</ul>'); in_list = False
        if table:
            head, *rows = table
            out.append('<div class="table-wrap"><table><thead><tr>' + ''.join('<th>' + inline(x) + '</th>' for x in head) + '</tr></thead><tbody>')
            for row in rows:
                out.append('<tr>' + ''.join('<td>' + inline(x) + '</td>' for x in row) + '</tr>')
            out.append('</tbody></table></div>'); table = []

    for line in source.splitlines():
        if line.startswith('```'):
            if in_code: out.append('<pre><code>' + html.escape('\n'.join(code)) + '</code></pre>'); code = []
            else: flush()
            in_code = not in_code; continue
        if in_code: code.append(line); continue
        if not line.strip(): flush(); continue
        if line.startswith('|'):
            if not re.match(r'^\|[ :|\-]+\|$', line): table.append([part.strip() for part in line.strip('|').split('|')])
            continue
        if line.startswith('#'):
            flush(); heading = line.split(' ', 1); level = len(heading[0]); title = heading[1]
            anchor = re.sub(r'[^a-z0-9]+', '-', title.lower()).strip('-')
            out.append(f'<h{level} id="{anchor}">{inline(title)}</h{level}>'); continue
        if line.startswith('- '):
            if paragraph: flush()
            if not in_list: out.append('<ul>'); in_list = True
            out.append('<li>' + inline(line[2:]) + '</li>'); continue
        if in_list:
            # Wrapped Markdown list text belongs to the previous list item.
            out[-1] = out[-1][:-5] + ' ' + inline(line.strip()) + '</li>'
        else: paragraph.append(line)
    flush()
    return '\n'.join(out)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    generated = OUT / 'hello.lua'
    subprocess.run([str(ROOT / 'bin' / 'kah'), str(ROOT / 'examples/kah/hello.rb'), '-o', str(generated)], check=True)
    page = (ROOT / 'site/index.html').read_text()
    lua_lines = generated.read_text().splitlines()[-22:]
    excerpt = ['-- Actual Kah output; shared runtime above.'] + lua_lines
    code = '\n'.join(f'<span class="ln" aria-hidden="true">{i:02}</span>' + html.escape(line) for i, line in enumerate(excerpt, 1))
    marker = '<!-- KAH_LUA_EXCERPT -->'
    if marker not in page:
        raise SystemExit('Missing generated Lua excerpt marker in site/index.html')
    page = page.replace(marker, code)
    (OUT / 'index.html').write_text(page)
    style = re.search(r'<style>(.*?)</style>', page, re.S)[1]
    favicon = re.search(r'<link rel="icon"[^>]*>', page)[0]
    guide_style = '\n.guide{max-width:850px;margin:0 auto;padding:80px 24px 100px}.guide h1{font-size:clamp(54px,10vw,96px);margin:0 0 32px}.guide h2{font-size:36px;margin:60px 0 20px}.guide p,.guide li,.guide td{line-height:1.8;color:var(--muted,#c9b9be)}.guide ul{padding-left:22px}.guide li{margin:10px 0}.guide pre{padding:24px;background:#211b24;overflow:auto;border:1px solid #4b3540;border-radius:12px;font-size:13px}.guide :not(pre)>code{color:#f4b7bf;font-size:.9em}.guide .table-wrap{overflow:auto}.guide table{border-collapse:collapse;width:100%;font-size:14px}.guide th,.guide td{text-align:left;padding:12px;border-bottom:1px solid #4b3540}.guide a{color:#f1a5af;text-decoration:underline;text-underline-offset:4px}.guide nav{display:flex;gap:24px;margin-bottom:52px;flex-wrap:wrap}.guide h2{scroll-margin-top:30px}@media(max-width:600px){.guide{padding-top:40px}.guide pre{padding:16px}.guide h2{font-size:30px}}'
    md = (ROOT / 'docs/kah.md').read_text()
    guide = '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="theme-color" content="#171319"><title>Kah — compiler guide</title>' + favicon + '<link rel="canonical" href="https://spacegho.st/kah/docs"><style>' + style + guide_style + '</style></head><body><main class="guide"><nav aria-label="Guide navigation"><a href="/kah/">← Kah</a><a href="#compile-and-run">Compile and run</a><a href="#current-limits">Current limits</a><a href="/kah/guide.md">Markdown guide</a></nav>' + render_guide(md) + '</main></body></html>'
    (OUT / 'docs.html').write_text(guide)
    sources = {
        '/kah/': (page, 'text/html; charset=utf-8'),
        '/kah/docs': (guide, 'text/html; charset=utf-8'),
        '/kah/guide.md': (md, 'text/markdown; charset=utf-8'),
        '/kah/examples/hello.rb': ((ROOT / 'examples/kah/hello.rb').read_text(), 'text/plain; charset=utf-8'),
        '/kah/examples/hello.lua': (generated.read_text(), 'text/plain; charset=utf-8'),
        '/kah/examples/interop.rb': ((ROOT / 'examples/kah/interop.rb').read_text(), 'text/plain; charset=utf-8'),
    }
    assets = {path: {'body': body, 'contentType': kind, 'etag': '"' + hashlib.sha256(body.encode()).hexdigest() + '"'} for path, (body, kind) in sources.items()}
    worker = 'const ASSETS = ' + json.dumps(assets, ensure_ascii=False) + ';\n' + (ROOT / 'site/worker.mjs').read_text() + '\nexport default createWorker(ASSETS);\n'
    (OUT / 'worker.mjs').write_text(worker)
    metadata = {'main_module': 'worker.mjs', 'compatibility_date': '2026-11-17', 'bindings': [], 'observability': {'enabled': True, 'logs': {'enabled': True, 'invocation_logs': True, 'head_sampling_rate': 1}, 'traces': {'enabled': True, 'head_sampling_rate': 0.01}}}
    (OUT / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
    print(f'Built Kah site: {len(assets)} routes, {len(worker.encode())} Worker bytes')


if __name__ == '__main__':
    main()
