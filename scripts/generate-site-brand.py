"""Render the site's social card and favicon. Requires Pillow and rsvg-convert."""
from pathlib import Path
import re
import subprocess
import tempfile
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
PUBLIC = ROOT / 'site/public'
component = (ROOT / 'site/src/components/BrandLogo.astro').read_text()
mark = re.search(r'<svg\b.*?</svg>', component, re.S).group()
mark = mark.replace('width="32"', 'x="849" y="62" width="244.8"').replace('height="56"', 'height="432"')
mark = mark.replace('currentColor', '#F2F2F0').replace('var(--c-bg)', '#000000').replace('var(--c-accent)', '#F0A202')
wordmark = (ROOT / 'site/src/components/brand-wordmark.svg').read_text()
wordmark = wordmark.replace('<svg ', '<svg x="78" y="91" width="520" height="127" ', 1).replace('currentColor', '#F2F2F0')
card = f'''<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="630" viewBox="0 0 1200 630">
<title>DynoCap — Local Linux sandboxes for coding agents</title>
<rect width="1200" height="630" fill="#000000"/>
{wordmark}
<g font-family="Arial, sans-serif" fill="#F2F2F0" font-size="48" letter-spacing="-1.8">
<text x="80" y="314">Local Linux sandboxes</text>
<text x="80" y="374">for coding agents.</text>
</g>
<text x="82" y="435" font-family="Arial, sans-serif" font-size="24" fill="#A3A39C">On your Mac. Isolated by design.</text>
{mark}
<path d="M80 522H1120" stroke="#2A2A28"/>
<g font-family="Arial, sans-serif" font-size="20" fill="#A3A39C">
<text x="80" y="567">macOS · Apple Silicon</text>
<text x="1120" y="567" text-anchor="end">github.com/baires/dynocap</text>
</g>
</svg>\n'''
(PUBLIC / 'og.svg').write_text(card)
subprocess.run(['rsvg-convert', '-o', str(PUBLIC / 'og.png'), str(PUBLIC / 'og.svg')], check=True)

# Enlarge the simplified mark optically, preserving ample clearance at 16px.
favicon = '''<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64">
<title>DynoCap</title><rect width="64" height="64" rx="12" fill="#000000"/>
<g transform="translate(-6.4 -6.4) scale(1.2)" fill="none" stroke="#F2F2F0" stroke-width="3.5" stroke-linecap="round" stroke-linejoin="round">
<path d="M19 22v-2a13 13 0 0 1 26 0v2H19ZM19 42h26v2a13 13 0 0 1-26 0Z"/>
<path d="m26 28 6 5-6 5" stroke="#F0A202"/><path d="M35 37h4"/>
</g></svg>\n'''
(PUBLIC / 'favicon.svg').write_text(favicon)
with tempfile.TemporaryDirectory(prefix='dynocap-brand-') as directory:
    png = Path(directory) / 'favicon.png'
    subprocess.run(['rsvg-convert', '-w', '256', '-h', '256', '-o', str(png), str(PUBLIC / 'favicon.svg')], check=True)
    with Image.open(png) as source:
        source.save(PUBLIC / 'favicon.ico', sizes=[(16, 16), (32, 32), (48, 48)])
