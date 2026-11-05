#!/usr/bin/env python3
"""Jeder Knopf ohne Text braucht einen Mouse-over-Hinweis (.help).
Findet Buttons/Menüs, die nur ein Symbol zeigen, und Werkzeugleisten-Knöpfe ohne .help – bricht dann ab."""
import glob, re, sys

missing = []
for f in sorted(glob.glob("App/Sources/**/*.swift", recursive=True)):
    lines = open(f, encoding="utf-8").read().split("\n")
    in_toolbar, depth = False, 0
    for i, l in enumerate(lines):
        win = " ".join(lines[max(0, i - 3):i + 4])
        icon_only = (re.search(r"label:\s*\{\s*Image\(systemName:", l)
                     or re.search(r"Button\(action:[^)]*\)\s*\{\s*Image\(systemName", l)
                     or "labelStyle(.iconOnly)" in l)
        if ".toolbar {" in l:
            in_toolbar, depth = True, 0
        toolbar_btn = False
        if in_toolbar:
            depth += l.count("{") - l.count("}")
            toolbar_btn = bool(re.search(r"label:\s*\{\s*Label\(", l))
            if depth <= 0 and ".toolbar {" not in l:
                in_toolbar = False
        if (icon_only or toolbar_btn) and ".help(" not in win:
            missing.append(f"{f}:{i + 1}: {l.strip()[:110]}")

if missing:
    print("✗ Knöpfe ohne Mouse-over-Hinweis (.help):")
    print("\n".join(missing))
    sys.exit(1)
print("✓ Alle Symbol-Knöpfe haben einen Mouse-over-Hinweis")
