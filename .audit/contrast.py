#!/usr/bin/env python3
"""WCAG contrast audit for the Ovid 'Aether' palette (lib/core/theme.dart)."""


def lum(hexs: str) -> float:
    hexs = hexs.lstrip('#')
    c = [int(hexs[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    c = [x / 12.92 if x <= 0.03928 else ((x + 0.055) / 1.055) ** 2.4 for x in c]
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]


def ratio(a: str, b: str) -> float:
    la, lb = lum(a), lum(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


PAL = {
    'bg': '0A0A0C', 'surface': '111114', 'surfaceAlt': '17171B',
    'surfaceRaised': '1D1D23', 'text': 'EDEDF0', 'textMuted': '9B9BA4',
    'textFaint': '63636C', 'accent': '4D6BFE', 'success': '3ECF8E',
    'warn': 'E8B44C', 'danger': 'E5534B',
}

FGS = ['text', 'textMuted', 'textFaint', 'accent', 'success', 'warn', 'danger']
BGS = ['bg', 'surface', 'surfaceAlt', 'surfaceRaised']

print('fg             on             ratio   AA(4.5)  AA-large(3.0)')
fails = []
for fg in FGS:
    for bg in BGS:
        r = ratio(PAL[fg], PAL[bg])
        aa = 'PASS' if r >= 4.5 else 'FAIL'
        large = 'PASS' if r >= 3.0 else 'FAIL'
        if aa == 'FAIL':
            fails.append((fg, bg, r, aa, large))
        print(f'{fg:14} {bg:14} {r:6.2f}   {aa:7}  {large}')

print()
print(f'TOTAL FAILING PAIRS (below 4.5:1): {len(fails)} / {len(FGS) * len(BGS)}')
print()
print('Worst offenders:')
for fg, bg, r, aa, large in sorted(fails, key=lambda x: x[2])[:8]:
    print(f'  {fg} on {bg}: {r:.2f}:1  (AA {aa}, large-text {large})')
