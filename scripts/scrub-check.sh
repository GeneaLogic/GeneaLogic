#!/usr/bin/env bash
#
# Check that no name on a private denylist appears anywhere in the tracked tree
# (slice 74). The list is the real family data the repo was scrubbed of; it is kept
# outside the repo on purpose, because a list of real names in the repo would be the
# leak, and a hashed one falls to a dictionary of surnames.
#
# Usage:
#   scripts/scrub-check.sh <denylist>
#   SCRUB_DENYLIST=<denylist> scripts/scrub-check.sh
#
# The denylist has one entry per line; blank lines and lines starting with `#` are
# ignored. Entries and text go through the same tokenizer: split on anything that is
# not a letter or digit, between letters and digits, and at camelCase humps (any
# script), then case- and diacritic-folded. So `hanner` is found in `hannerAndHanaur`,
# in a Swift `"\tHanner"`, and as `Hanners`; and `Hanner-Feldberg` matches as a phrase.
#   - An entry of several tokens (an address) matches those tokens in a row, across
#     line breaks, so a hard-wrapped doc can't split it out of sight.
#   - The last token also matches with a plural `s` or `es`.
#   - `!<path>:<phrase>` allows a phrase in that one tracked file. That is how a name
#     used deliberately (the maintainer's, in TRADEMARKS.md) stays without the list
#     giving up its surname, while the same name anywhere else is still a hit.
#
# Checks every tracked file's path and, for text files, its contents; a file that
# isn't UTF-8 is listed as unchecked. Exits 1 on any hit. Run it before a snapshot
# leaves this repo (slice 76); CI can't, since it has no list.

set -euo pipefail

LIST="${1:-${SCRUB_DENYLIST:-}}"
if [[ -z "$LIST" || ! -f "$LIST" ]]; then
    echo "usage: scripts/scrub-check.sh <denylist>  (or set SCRUB_DENYLIST)" >&2
    exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

git ls-files -z | python3 -I -c '
import re, sys, unicodedata

def fold(s):
    s = unicodedata.normalize("NFKD", s)
    s = "".join(c for c in s if not unicodedata.combining(c))
    return s.replace("ł", "l").replace("Ł", "L").casefold()

RUN = re.compile(r"[^\W_]+")

def split_run(run):
    """Split at letter/digit boundaries and camelCase humps, in any script."""
    parts, start = [], 0
    for i in range(1, len(run)):
        a, b = run[i - 1], run[i]
        nxt = run[i + 1] if i + 1 < len(run) else ""
        if (a.isdigit() != b.isdigit()
                or (a.islower() and b.isupper())
                or (a.isupper() and b.isupper() and nxt.islower())):
            parts.append(run[start:i]); start = i
    parts.append(run[start:])
    return parts

def tokens(text):
    """(folded token, original token, line number) for every token in text."""
    out, line, pos = [], 1, 0
    for m in RUN.finditer(text):
        line += text.count("\n", pos, m.start()); pos = m.start()
        for part in split_run(m.group()):
            out.append((fold(part), part, line))
    return out

entries, allowed = {}, {}
for raw in open(sys.argv[1], encoding="utf-8"):
    raw = raw.strip()
    if not raw or raw.startswith("#"):
        continue
    if raw.startswith("!"):
        path, _, phrase = raw[1:].partition(":")
        allowed.setdefault(path.strip(), []).append([t for t, _, _ in tokens(phrase)])
        continue
    seq = [t for t, _, _ in tokens(raw)]
    if seq:
        entries.setdefault(seq[0], []).append(seq)

def same(tok, want, last):
    return tok == want or (last and not want.isdigit() and tok in (want + "s", want + "es"))

def at(toks, i, seq):
    return i + len(seq) <= len(toks) and all(
        same(toks[i + k][0], w, k == len(seq) - 1) for k, w in enumerate(seq))

def hits(text, path):
    toks = tokens(text)
    skip = set()
    for seq in allowed.get(path, []):
        for i in range(len(toks)):
            if at(toks, i, seq):
                skip.update(range(i, i + len(seq)))
    found = []
    for i, (t, orig, line) in enumerate(toks):
        if i in skip:
            continue
        for key in (t, t[:-1], t[:-2]):
            for seq in entries.get(key, []):
                if at(toks, i, seq) and not skip.intersection(range(i, i + len(seq))):
                    found.append((line, " ".join(o for _, o, _ in toks[i:i + len(seq)])))
    return found

bad = unchecked = 0
for path in sys.stdin.read().split("\0"):
    if not path:
        continue
    for _, h in hits(path, None):
        print(f"{path}: path contains {h!r}"); bad += 1
    try:
        text = open(path, encoding="utf-8").read()
    except (UnicodeDecodeError, IsADirectoryError, FileNotFoundError):
        print(f"{path}: not checked (not a UTF-8 text file)"); unchecked += 1
        continue
    for line, h in hits(text, path):
        print(f"{path}:{line}: {h!r}"); bad += 1

print(f"scrub-check: {bad} hit(s), {unchecked} file(s) unchecked", file=sys.stderr)
sys.exit(1 if bad else 0)
' "$LIST"
