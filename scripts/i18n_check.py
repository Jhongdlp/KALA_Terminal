#!/usr/bin/env python3
"""Check that every tr('…') key in lib/ has an entry in lib/l10n/strings_en.dart.

A missing key is not fatal at runtime — tr() falls back to the Spanish source
text — but it means that string stays Spanish when the app is set to English.

    python3 scripts/i18n_check.py          # report
    python3 scripts/i18n_check.py --stubs  # print Dart lines to paste in
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STRINGS = os.path.join(ROOT, 'lib', 'l10n', 'strings_en.dart')

# tr( followed by one string literal. Handles both quote styles; a key
# containing the same quote it is delimited with is not supported (and none
# exist, by construction).
CALL = re.compile(r"\btr\(\s*r?(?:'((?:[^'\\]|\\.)*)'|\"((?:[^\"\\]|\\.)*)\")")
ENTRY = re.compile(r"^\s*r?(?:'((?:[^'\\]|\\.)*)'|\"((?:[^\"\\]|\\.)*)\")\s*:", re.M)


def literals(pattern, text):
    return {a if a is not None else b for a, b in pattern.findall(text)}


def main():
    known = literals(ENTRY, open(STRINGS, encoding='utf-8').read())

    used, sites = set(), {}
    for dirpath, _, names in os.walk(os.path.join(ROOT, 'lib')):
        for name in names:
            if not name.endswith('.dart'):
                continue
            path = os.path.join(dirpath, name)
            if os.path.samefile(path, STRINGS):
                continue
            for line_no, line in enumerate(open(path, encoding='utf-8'), 1):
                if line.lstrip().startswith('//'):
                    continue  # doc comments show tr() examples
                for key in literals(CALL, line):
                    used.add(key)
                    sites.setdefault(key, f'{os.path.relpath(path, ROOT)}:{line_no}')

    missing = sorted(used - known)
    orphan = sorted(known - used)

    print(f'{len(used)} claves usadas, {len(known)} traducidas')
    if missing:
        print(f'\n{len(missing)} SIN TRADUCIR (se mostrarán en español):')
        for key in missing:
            print(f'  {sites[key]}\n    {key}')
    if orphan:
        print(f'\n{len(orphan)} entradas sin uso (código borrado?):')
        for key in orphan:
            print(f'  {key}')
    if '--stubs' in sys.argv and missing:
        print('\n// pegar en lib/l10n/strings_en.dart:')
        for key in missing:
            print(f"  '{key}': '',")
    return 1 if missing else 0


if __name__ == '__main__':
    sys.exit(main())
