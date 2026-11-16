"""Build DynoCap vector assets. Requires fonttools and the macOS Avenir Next font."""
from pathlib import Path
from fontTools.ttLib import TTCollection
from fontTools.pens.svgPathPen import SVGPathPen

HERE = Path(__file__).resolve().parent
fonts = TTCollection('/System/Library/Fonts/Avenir Next.ttc').fonts
font = next(f for f in fonts if any(n.toUnicode() == 'AvenirNext-Bold' for n in f['name'].names if n.nameID == 6))
glyphs = font.getGlyphSet()
cmap = font.getBestCmap()

def wordmark(ink):
    parts, x = [], 0
    for char in 'DynoCap':
        name = cmap[ord(char)]
        pen = SVGPathPen(glyphs)
        glyphs[name].draw(pen)
        parts.append(f'<path transform="translate({x} 0)" d="{pen.getCommands()}"/>')
        x += font['hmtx'][name][0] - 24
    return f'<g fill="{ink}" transform="translate({400-x*.15/2:.3f} 758) scale(.15 -.15)">' + ''.join(parts) + '</g>'

# One shell, two load-bearing rails, a three-faced guest cube, and a live prompt.
# Explicit fills and split rim paths keep the drawing opaque in every variant.
def mark(ink, accent, surface):
    return f'''<g fill="none" stroke="{ink}" stroke-width="8" stroke-linecap="round" stroke-linejoin="round">
  <path d="M136 172V164a120 120 0 0 1 240 0v8"/>
  <path d="M136 172c0-38 240-38 240 0"/>
  <path d="M136 172c0 12 16 21 35 25m170 0c19-4 35-13 35-25" stroke-width="5"/>
  <path d="M161 198v141m190-141v141" stroke-width="7"/>
  <path d="M136 348c0-12 12-22 25-26m190 0c13 4 25 14 25 26" stroke-width="5"/>
  <path d="M136 348v8a120 120 0 0 0 240 0v-8"/>
  <path d="M136 348c0 38 240 38 240 0"/>
  <path d="m282 104 10-17m10 17 10-17m10 17 10-17" stroke-width="6"/>
  <path d="m256 205 72 36v82l-72 36-72-36v-82Z" fill="{surface}"/>
  <path d="m184 241 72 36 72-36m-72 36v82" stroke-width="6"/>
  <path d="m205 275 18 19-18 1" stroke="{accent}" stroke-width="7"/>
  <path d="m279 310 22-11" stroke-width="7"/>
</g>
<rect x="229" y="404" width="54" height="12" rx="6" fill="{accent}"/>'''

# Prompt sits in the cube's left face; its two arms follow that face's projection.
def art(ink, accent, surface):
    return mark(ink, accent, surface)

def svg(w, h, body, title='DynoCap'):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" role="img" aria-labelledby="title"><title id="title">{title}</title>{body}</svg>\n'''

palettes = {
    'dark': ('#F5F2EB', '#FFB21A', '#0B0C0E'),
    'light': ('#16191D', '#D58A00', '#FAF8F3'),
    'mono': ('#16191D', '#16191D', '#FFFFFF'),
}
for theme, (ink, accent, surface) in palettes.items():
    icon = art(ink, accent, surface)
    # Transparent assets have only the three cube faces filled for proper occlusion.
    (HERE / f'dynocap-mark-{theme}.svg').write_text(svg(512, 512, icon))
    lockup = f'<g transform="translate(80 -5) scale(1.25)">{icon}</g>' + wordmark(ink)
    (HERE / f'dynocap-logo-{theme}.svg').write_text(svg(800, 840, lockup))
    if theme != 'mono':
        (HERE / f'dynocap-preview-{theme}.svg').write_text(svg(800, 840, f'<path fill="{surface}" d="M0 0h800v840H0z"/>' + lockup))

# A deliberately stripped-back small mark avoids the full illustration's fine seams.
ink, accent, surface = palettes['dark']
small = f'''<g fill="none" stroke="{ink}" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M19 22v-2a13 13 0 0 1 26 0v2M19 42v2a13 13 0 0 0 26 0v-2M20 22h24M20 42h24"/><path d="m26 28 6 5-6 5" stroke="{accent}"/><path d="M35 37h4"/></g>'''
(HERE / 'dynocap-mark-small.svg').write_text(svg(64, 64, small))
