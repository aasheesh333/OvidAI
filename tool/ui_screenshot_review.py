#!/usr/bin/env python3
"""Objective metrics for UI screenshots when no vision model can view them.

This tool never asserts visual/aesthetic quality. It measures only mechanical
properties of each PNG (dimensions, non-blank coverage, dominant colors, edge
density) and applies deliberately conservative blank/edge heuristics that can
flag a screen for a human/vision reviewer but cannot approve it. An HTML gallery
and a Markdown report are emitted so the images and their numbers can be handed
to a reviewer side by side.

Pillow is used when importable; otherwise a minimal stdlib PNG header parser
still yields dimensions and a blank/entropy estimate so the run degrades
gracefully instead of failing.
"""
import argparse
import html
import json
import struct
import zlib
from pathlib import Path

try:
    from PIL import Image, ImageChops, ImageFilter, ImageStat
    HAVE_PIL = True
except ImportError:  # pragma: no cover - exercised only without Pillow
    HAVE_PIL = False

BG_TOLERANCE = 24
EDGE_TOLERANCE = 32
BLANK_RATIO = 0.005
SPARSE_RATIO = 0.02
EDGE_MARGIN_PX = 2
TOP_COLORS = 5


def _hex(rgb):
    return '#%02x%02x%02x' % tuple(int(c) for c in rgb[:3])


def _png_dimensions(path):
    """Parse IHDR from a PNG without Pillow. Raises ValueError if not a PNG."""
    with open(path, 'rb') as fh:
        if fh.read(8) != b'\x89PNG\r\n\x1a\n':
            raise ValueError('not a PNG')
        length = struct.unpack('>I', fh.read(4))[0]
        if fh.read(4) != b'IHDR' or length < 13:
            raise ValueError('missing IHDR')
        width, height = struct.unpack('>II', fh.read(8))
    return width, height


def _fallback_metrics(path):
    width, height = _png_dimensions(path)
    return {
        'width': width,
        'height': height,
        'pixels': width * height,
        'non_blank_ratio': None,
        'edge_density': None,
        'dominant_colors': [],
        'content_bbox': None,
        'edge_touch': None,
        'blank_heuristic': None,
        'overflow_heuristic': 'undetermined (Pillow unavailable)',
        'notes': ['Pillow unavailable: only PNG header dimensions were read.'],
    }


def analyze(path):
    if not HAVE_PIL:
        return _fallback_metrics(path)
    with Image.open(path) as img:
        img.load()
        width, height = img.size
        rgb = img.convert('RGB')
        total = width * height

        small = rgb.resize((min(width, 240), min(height, 240)))
        palette = small.getcolors(small.width * small.height)
        palette = sorted(palette, reverse=True)
        background = palette[0][1] if palette else (0, 0, 0)

        diff = ImageChops.difference(rgb, Image.new('RGB', rgb.size, background))
        gray = diff.convert('L')
        mask = gray.point(lambda v: 255 if v > BG_TOLERANCE else 0)
        histogram = mask.histogram()
        non_blank_px = histogram[255] if len(histogram) > 255 else 0
        non_blank_ratio = non_blank_px / total

        bbox = mask.getbbox()
        edge_touch = None
        margins = None
        if bbox:
            margins = {
                'left': bbox[0],
                'top': bbox[1],
                'right': width - bbox[2],
                'bottom': height - bbox[3],
            }
            edge_touch = {
                side: px <= EDGE_MARGIN_PX for side, px in margins.items()
            }

        edges = rgb.convert('L').filter(ImageFilter.FIND_EDGES)
        edge_hist = edges.point(lambda v: 255 if v > EDGE_TOLERANCE else 0).histogram()
        edge_density = (edge_hist[255] if len(edge_hist) > 255 else 0) / total

        dominant = []
        seen = set()
        for count, color in palette:
            key = tuple(int(c) // 8 for c in color)
            if key in seen:
                continue
            seen.add(key)
            dominant.append({'hex': _hex(color), 'ratio': round(count / total, 4)})
            if len(dominant) >= TOP_COLORS:
                break

        notes = []
        blank = None
        if non_blank_ratio < BLANK_RATIO:
            blank = True
            notes.append('Non-blank coverage below %.3f: screen is effectively '
                         'a single flat color.' % BLANK_RATIO)
        else:
            blank = False
            if non_blank_ratio < SPARSE_RATIO:
                notes.append('Sparse non-blank coverage (<%.2f): verify the '
                             'screen actually rendered content.' % SPARSE_RATIO)

        overflow = 'none detected'
        if edge_touch and all(edge_touch.values()):
            overflow = 'content spans all four edges (possible clipping/overflow)'
        elif edge_touch and (edge_touch['bottom'] or edge_touch['right']):
            sides = [s for s in ('right', 'bottom') if edge_touch[s]]
            overflow = 'content touches %s edge (possible clipping/overflow)' % '/'.join(sides)

        return {
            'width': width,
            'height': height,
            'pixels': total,
            'non_blank_ratio': round(non_blank_ratio, 4),
            'edge_density': round(edge_density, 4),
            'dominant_colors': dominant,
            'content_bbox': list(bbox) if bbox else None,
            'margins': margins,
            'edge_touch': edge_touch,
            'blank_heuristic': blank,
            'overflow_heuristic': overflow,
            'notes': notes,
        }


def collect(input_dir, pattern):
    files = sorted(Path(input_dir).glob(pattern))
    return [p for p in files if p.suffix.lower() == '.png']


def render_html(entries, out_path):
    rows = []
    for name, metrics, rel_src in entries:
        colors = ' '.join(
            '<span class="sw" style="background:%s" title="%s %.1f%%"></span>'
            % (html.escape(c['hex']), html.escape(c['hex']), c['ratio'] * 100)
            for c in metrics['dominant_colors']
        ) or '<span class="muted">n/a</span>'
        ratio = metrics['non_blank_ratio']
        density = metrics['edge_density']
        rows.append(
            '<tr>'
            '<td><a href="%s"><img loading="lazy" src="%s" alt="%s"></a>'
            '<div class="fn">%s</div></td>'
            '<td>%d&times;%d</td>'
            '<td>%s</td>'
            '<td>%s</td>'
            '<td>%s</td>'
            '<td>%s</td>'
            '<td>%s</td>'
            '</tr>'
            % (
                html.escape(rel_src), html.escape(rel_src), html.escape(name),
                html.escape(name), metrics['width'], metrics['height'],
                'n/a' if ratio is None else '%.2f%%' % (ratio * 100),
                'n/a' if density is None else '%.2f%%' % (density * 100),
                colors,
                'yes' if metrics['blank_heuristic'] else ('no' if metrics['blank_heuristic'] is False else 'n/a'),
                html.escape(metrics['overflow_heuristic']),
            )
        )
    doc = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<title>UI screenshot objective review</title>
<style>
body{font-family:system-ui,sans-serif;margin:24px;background:#111;color:#eee}
h1{font-size:1.3rem}
.warn{background:#4a2b00;border:1px solid #a06000;padding:10px 14px;border-radius:6px;max-width:70ch}
table{border-collapse:collapse;width:100%%;margin-top:18px}
th,td{border:1px solid #333;padding:8px;vertical-align:top;text-align:left;font-size:.85rem}
th{background:#1c1c1c;position:sticky;top:0}
img{width:220px;border:1px solid #444;background:#000;display:block}
.fn{font-family:monospace;font-size:.75rem;margin-top:4px}
.sw{display:inline-block;width:18px;height:18px;border:1px solid #555;margin:1px}
.muted{color:#888}
</style></head><body>
<h1>UI screenshot objective review</h1>
<p class="warn"><strong>Metrics only.</strong> These numbers describe dimensions,
coverage, color, and edges. They do <strong>not</strong> establish aesthetic
quality, correct layout, or absence of visual defects. A human or vision model
must still review every image. A passing heuristic is not an approval.</p>
<table>
<thead><tr><th>Image</th><th>Dimensions</th><th>Non-blank</th><th>Edge density</th>
<th>Dominant colors</th><th>Blank?</th><th>Edge/overflow heuristic</th></tr></thead>
<tbody>
%s
</tbody></table>
</body></html>
""" % '\n'.join(rows)
    out_path.write_text(doc, encoding='utf-8')


def render_report(entries, out_path, input_dir):
    lines = [
        '# UI screenshot objective review',
        '',
        'Generated by `tool/ui_screenshot_review.py`.',
        '',
        '> **Scope limit:** this report contains objective pixel metrics only. It '
        'does **not** and cannot certify visual or aesthetic quality. Every '
        'screenshot still requires review by a human or a vision-capable model.',
        '> A heuristic "no" is the absence of an automated red flag, not a pass.',
        '',
        'Input directory: `%s`' % input_dir,
        'Screenshots analyzed: %d' % len(entries),
        '',
    ]
    for name, m, _ in entries:
        lines.append('## %s' % name)
        lines.append('')
        lines.append('- Dimensions: %d x %d (%d px)' % (m['width'], m['height'], m['pixels']))
        if m['non_blank_ratio'] is None:
            lines.append('- Non-blank ratio: n/a (Pillow unavailable)')
            lines.append('- Edge density: n/a')
        else:
            lines.append('- Non-blank ratio: %.2f%%' % (m['non_blank_ratio'] * 100))
            lines.append('- Edge density: %.2f%%' % (m['edge_density'] * 100))
        if m['dominant_colors']:
            colors = ', '.join('%s (%.1f%%)' % (c['hex'], c['ratio'] * 100)
                               for c in m['dominant_colors'])
            lines.append('- Dominant colors: %s' % colors)
        else:
            lines.append('- Dominant colors: n/a')
        if m['content_bbox'] is not None:
            lines.append('- Content bbox (l,t,r,b): %s' % (m['content_bbox'],))
        if m.get('margins'):
            lines.append('- Content margins (px): %s' % m['margins'])
        blank = m['blank_heuristic']
        lines.append('- Blank heuristic: %s' % ('blank' if blank else ('content present' if blank is False else 'undetermined')))
        lines.append('- Edge/overflow heuristic: %s' % m['overflow_heuristic'])
        for note in m['notes']:
            lines.append('- Note: %s' % note)
        lines.append('')
    lines.append('## Reviewer handoff')
    lines.append('')
    lines.append('Open `/tmp/opencode/ui-review/index.html` (images linked with '
                 'metrics) and confirm layout, spacing, contrast, alignment, and '
                 'text rendering by eye. Nothing in this report substitutes for '
                 'that step.')
    lines.append('')
    out_path.write_text('\n'.join(lines), encoding='utf-8')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input-dir', default='/tmp/opencode')
    parser.add_argument('--pattern', default='ui-finish-*.png')
    parser.add_argument('--out-dir', default='/tmp/opencode/ui-review')
    parser.add_argument('--report', default='/tmp/opencode/finish-screenshot-review.md')
    parser.add_argument('--json', default=None, help='optional path for raw metrics JSON')
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    report_path = Path(args.report)
    report_path.parent.mkdir(parents=True, exist_ok=True)

    files = collect(args.input_dir, args.pattern)
    if not files:
        raise SystemExit('no PNG files matched %s in %s' % (args.pattern, args.input_dir))

    entries = []
    for path in files:
        metrics = analyze(path)
        rel_src = '../' + path.name
        entries.append((path.name, metrics, rel_src))
        print('%-18s %4dx%-4d non-blank=%s edge=%s blank=%s' % (
            path.name, metrics['width'], metrics['height'],
            'n/a' if metrics['non_blank_ratio'] is None else '%.2f%%' % (metrics['non_blank_ratio'] * 100),
            'n/a' if metrics['edge_density'] is None else '%.2f%%' % (metrics['edge_density'] * 100),
            metrics['blank_heuristic'],
        ))

    render_html(entries, out_dir / 'index.html')
    render_report(entries, report_path, args.input_dir)
    if args.json:
        Path(args.json).write_text(json.dumps(
            [{'name': n, **m} for n, m, _ in entries], indent=2), encoding='utf-8')

    print('gallery: %s' % (out_dir / 'index.html'))
    print('report:  %s' % report_path)


if __name__ == '__main__':
    main()
