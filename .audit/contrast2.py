#!/usr/bin/env python3
"""WCAG contrast audit for Ovid's REAL 'Aether' palette (lib/core/theme.dart)."""


def lum(h):
    h = h.lstrip('#')
    c = [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    c = [x / 12.92 if x <= 0.03928 else ((x + 0.055) / 1.055) ** 2.4 for x in c]
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]


def ratio(a, b):
    la, lb = lum(a), lum(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


DARK = {
    'bg': '151517', 'surface': '232324', 'surfaceAlt': '2C2C2E',
    'surfaceRaised': '353638', 'codeBg': '1B1B1C',
    'text': 'F9FAFB', 'textMuted': 'ADB2B8', 'textFaint': '81858C',
    'accent': '679EFE', 'success': '22C55E', 'warn': 'F59E0B', 'danger': 'F25A5A',
}
LIGHT = {
    'bg': 'FAFAFA', 'surface': 'FFFFFF', 'surfaceAlt': 'F2F2F5',
    'surfaceRaised': 'E9E9EE', 'codeBg': 'F5F5F5',
    'text': '0F1115', 'textMuted': '545557', 'textFaint': '5B5F66',
    'accent': '679EFE', 'accentC': '2563EB', 'success': '22C55E',
    'warn': 'F59E0B', 'danger': 'F25A5A',
}

FGS = ['text', 'textMuted', 'textFaint', 'accent', 'success', 'warn', 'danger']
BGS = ['bg', 'surface', 'surfaceAlt', 'surfaceRaised', 'codeBg']

for name, pal in (('DARK', DARK), ('LIGHT', LIGHT)):
    print(f'===== {name} =====')
    print(f'{"fg":12} {"on":15} {"ratio":>7}  {"AA4.5":>7} {"AA3.0":>7}')
    fails = []
    for fg in FGS:
        if fg not in pal:
            continue
        for bg in BGS:
            r = ratio(pal[fg], pal[bg])
            aa = 'PASS' if r >= 4.5 else 'FAIL'
            lg = 'PASS' if r >= 3.0 else 'FAIL'
            if aa == 'FAIL':
                fails.append((fg, bg, round(r, 2)))
            print(f'{fg:12} {bg:15} {r:7.2f}  {aa:>7} {lg:>7}')
    print(f'--> FAILING pairs: {len(fails)}')
    for f in fails:
        print(f'      {f[0]:12} on {f[1]:15} {f[2]}')
    print()

# Light-mode accent/success/danger overrides
print('===== LIGHT overrides (accentC/successC/dangerC on surface) =====')
for fg, hx in (('accentC', '2563EB'), ('successC', '1FA05F'), ('dangerC', 'D23B33'),
               ('successLight', '15803D'), ('warnLight', 'B45309')):
    for bg in ('bg', 'surface', 'surfaceAlt'):
        r = ratio(hx, LIGHT[bg])
        print(f'{fg:13} on {bg:12} {r:6.2f}  {"PASS" if r >= 4.5 else "FAIL"}')

print()
print('===== HAIRLINE visibility (dark) =====')
print('surface == hairline ?', DARK['surface'] == '232324', '(hairlineD = 232324 = surfaceD)')
print('ratio(surface, hairline) =', round(ratio(DARK['surface'], '232324'), 3),
      '-> 1.00 means INVISIBLE border on a surface card')
print('ratio(surfaceAlt, hairlineStrong) =',
      round(ratio(DARK['surfaceAlt'], '313134'), 3))
