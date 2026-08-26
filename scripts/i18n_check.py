#!/usr/bin/env python3
"""Check that every tr('…') key in lib/ has an entry in each translation table.

A missing key is not fatal at runtime — tr() falls back to the Spanish source
text — but it means that string stays Spanish in that language.

    python3 scripts/i18n_check.py            # report every language
    python3 scripts/i18n_check.py en         # only strings_en.dart
    python3 scripts/i18n_check.py --stubs    # print Dart lines to paste in

Note on "entradas sin uso": the gesture tables and the command registry call
tr() on a *variable* (`tr(gesture.action)`), so their keys can never be found
by a source scan. They are listed for information — read the note at the top
of strings_en.dart before deleting anything from this list.
"""
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
L10N = os.path.join(ROOT, 'lib', 'l10n')

# tr( followed by one string literal. DOTALL because the literal is often on
# the next line when the call is long — reading line by line missed exactly
# those, and they were the longest strings in the app.
CALL = re.compile(
    r"\btr\(\s*r?(?:'((?:[^'\\]|\\.)*)'|\"((?:[^\"\\]|\\.)*)\")", re.S)
ENTRY = re.compile(r"^\s*r?(?:'((?:[^'\\]|\\.)*)'|\"((?:[^\"\\]|\\.)*)\")\s*:", re.M)
LINE_COMMENT = re.compile(r'^\s*//.*$', re.M)


def literals(pattern, text):
    return {a if a is not None else b for a, b in pattern.findall(text)}


def tables():
    """{'en': (path, {keys}), …} for every strings_<code>.dart that exists."""
    out = {}
    for path in sorted(glob.glob(os.path.join(L10N, 'strings_*.dart'))):
        code = os.path.basename(path)[len('strings_'):-len('.dart')]
        with open(path, encoding='utf-8') as fh:
            out[code] = (path, literals(ENTRY, fh.read()))
    return out


def used_keys():
    used, sites = set(), {}
    for dirpath, _, names in os.walk(os.path.join(ROOT, 'lib')):
        for name in names:
            if not name.endswith('.dart') or name.startswith('strings_'):
                continue
            path = os.path.join(dirpath, name)
            with open(path, encoding='utf-8') as fh:
                text = fh.read()
            # Doc comments show tr() examples; drop whole-line comments only.
            for key in literals(CALL, LINE_COMMENT.sub('', text)):
                used.add(key)
                if key not in sites:
                    offset = text.find(key)
                    line_no = text.count('\n', 0, offset) + 1 if offset >= 0 else 0
                    sites[key] = f'{os.path.relpath(path, ROOT)}:{line_no}'
    return used, sites


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('-')]
    stubs = '--stubs' in sys.argv

    all_tables = tables()
    wanted = args or sorted(all_tables)
    unknown = [c for c in wanted if c not in all_tables]
    if unknown:
        print(f'error: no existe strings_{unknown[0]}.dart', file=sys.stderr)
        return 2

    used, sites = used_keys()
    print(f'{len(used)} claves usadas en lib/')

    failed = False
    for code in wanted:
        path, known = all_tables[code]
        missing = sorted(used - known)
        print(f'\n{code}: {len(known)} traducidas, {len(missing)} sin traducir')
        for key in missing:
            print(f'  {sites[key]}\n    {key}')
        if stubs and missing:
            print(f'\n// pegar en {os.path.relpath(path, ROOT)}:')
            for key in missing:
                print(f"  '{key}': '',")
        failed = failed or bool(missing)

    # Orphans are the same for every table by construction (they all mirror
    # the Spanish key set), so report them once against the first language.
    orphan = sorted(all_tables[wanted[0]][1] - used)
    if orphan:
        print(f'\n{len(orphan)} entradas sin uso — casi todas son las claves '
              'dinámicas (gestos, comandos); ver la nota en strings_en.dart:')
        for key in orphan:
            print(f'  {key}')

    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
