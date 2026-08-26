#!/usr/bin/env python3
"""Generate a GitHub release body, in English, from lib/models/changelog.dart.

The app ships its own changelog so the "what's new" screen can be shown at the
right moment and in the user's language (see lib/models/changelog.dart). The
pre-install dialog cannot use it — a build cannot carry the notes of a version
that did not exist when it shipped — so it shows the GitHub release body
instead.

Rather than have someone hand-write that body in whatever language they were
thinking in, it is generated from the same table, translated through
lib/l10n/strings_en.dart. One source of truth, and the release notes are always
English rather than sometimes-Spanish.

Usage:
    scripts/changelog_notes.py 2.10.0      # markdown for that version
    scripts/changelog_notes.py --check 2.10.0   # exit 1 if it has no entry
"""

import argparse
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHANGELOG = os.path.join(ROOT, 'lib', 'models', 'changelog.dart')
STRINGS_EN = os.path.join(ROOT, 'lib', 'l10n', 'strings_en.dart')

KIND_HEADINGS = {
    'added': 'Added',
    'improved': 'Improved',
    'fixed': 'Fixed',
}


def _dart_string(literal):
    """Decode a Dart single-quoted literal (raw or escaped)."""
    if literal.startswith("r'"):
        return literal[2:-1]
    return literal[1:-1].replace("\\'", "'").replace('\\\\', '\\')


def load_translations():
    """Spanish source text -> English, from the app's own table."""
    line = re.compile(r"^  (r?'(?:[^'\\]|\\.)*'): (r?'(?:[^'\\]|\\.)*'),$")
    out = {}
    with open(STRINGS_EN, encoding='utf-8') as fh:
        for raw in fh:
            m = line.match(raw.rstrip('\n'))
            if m:
                out[_dart_string(m.group(1))] = _dart_string(m.group(2))
    return out


def load_changelog():
    """[(version, date, [(kind, spanish_text), ...]), ...] newest first."""
    src = open(CHANGELOG, encoding='utf-8').read()
    # Only the const table, so the doc comments above it can't be mistaken for
    # entries.
    start = src.index('const List<ReleaseNote> kChangelog = [')
    table = src[start:]

    releases = []
    note_re = re.compile(
        r"ReleaseNote\(\s*version:\s*'([^']+)',\s*date:\s*'([^']+)',\s*"
        r"changes:\s*\[(.*?)\],\s*\),",
        re.S,
    )
    entry_re = re.compile(
        r"ChangeEntry\(ChangeKind\.(\w+),\s*('(?:[^'\\]|\\.)*')\s*\)", re.S)

    for m in note_re.finditer(table):
        changes = [(e.group(1), _dart_string(e.group(2)))
                   for e in entry_re.finditer(m.group(3))]
        releases.append((m.group(1), m.group(2), changes))
    return releases


def render(version, releases, translations):
    for ver, date, changes in releases:
        if ver != version:
            continue
        lines = []
        for kind, heading in KIND_HEADINGS.items():
            picked = [text for k, text in changes if k == kind]
            if not picked:
                continue
            lines.append('## %s' % heading)
            for text in picked:
                english = translations.get(text)
                if english is None:
                    print('warning: no English translation for %r' % text,
                          file=sys.stderr)
                    english = text
                lines.append('- %s' % english)
            lines.append('')
        lines.append('_Released %s._' % date)
        return '\n'.join(lines).strip() + '\n'
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('version')
    ap.add_argument('--check', action='store_true',
                    help='only verify the version has an entry')
    args = ap.parse_args()

    releases = load_changelog()
    body = render(args.version, releases, load_translations())

    if body is None:
        print('error: lib/models/changelog.dart has no entry for %s.\n'
              'Add one (newest first) before releasing — it is what the app\'s\n'
              'NOVEDADES screen and the GitHub release body are both built from.'
              % args.version, file=sys.stderr)
        return 1

    if not args.check:
        sys.stdout.write(body)
    return 0


if __name__ == '__main__':
    sys.exit(main())
