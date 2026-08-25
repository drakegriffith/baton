#!/usr/bin/env python3
"""complexity.py -- the stated enumerator behind HARDEN.md's complexity table.

There is no off-the-shelf McCabe counter for bash on this machine (the
mutation-tests skill's changed_functions.py does Python and JS/TS only and
classifies every .sh file in this diff as `non_code`), so the rule is
spelled out here and applied mechanically rather than eyeballed.

RULE. Cyclomatic complexity of a shell function =
    1
  + one per `if` and `elif`
  + one per `while` / `until` / `for`
  + one per `case` pattern arm, counting `a|b)` as 2 and NOT counting a
    bare `*)` catch-all (it is the fall-through, not a decision)
  + one per `&&` and `||` operator
Comments and here-doc/quoted text are excluded. For parse_reset_epoch the
embedded python program is counted too (separately), with the same rule
plus `except`, `and`, `or`, and inline-if.

Usage: python3 .ab/complexity.py
"""

import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if len(sys.argv) > 1 and not sys.argv[1].startswith("-"):
    # Read a snapshot instead of the live checkout -- the numbers must not be
    # taken while a mutation run has a mutant applied to the working tree.
    REPO = sys.argv[1]

# file -> list of (function name, first line, last line) resolved by scanning
FUNC_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{")


def strip_comment(line):
    """Drop a trailing/whole-line # comment. Quote-aware enough for this repo:
    tracks single/double quotes so a `#` inside a regex or message is kept."""
    out = []
    q = None
    i = 0
    while i < len(line):
        c = line[i]
        if q:
            if c == q:
                q = None
            out.append(c)
        else:
            if c in "'\"":
                q = c
                out.append(c)
            elif c == "#" and (not out or out[-1].isspace()):
                break
            else:
                out.append(c)
        i += 1
    return "".join(out)


def sh_functions(path):
    """Yield (name, body_lines). Body ends at a line that is exactly `}`."""
    lines = open(path).read().splitlines()
    i = 0
    while i < len(lines):
        m = FUNC_RE.match(lines[i])
        if m:
            name = m.group(1)
            # one-liner: `f() { ...; }`
            if lines[i].rstrip().endswith("}"):
                yield name, [lines[i]]
                i += 1
                continue
            j = i + 1
            body = []
            while j < len(lines) and lines[j] != "}":
                body.append(lines[j])
                j += 1
            yield name, body
            i = j + 1
        else:
            i += 1


def sh_cc(body_lines):
    cc = 1
    detail = {}

    def add(key, n=1):
        nonlocal cc
        cc += n
        detail[key] = detail.get(key, 0) + n

    in_case = 0
    in_embedded_py = False
    for raw in body_lines:
        # The embedded python program inside parse_reset_epoch is a quoted
        # argument, not shell control flow -- count it separately (py_cc).
        if "python3 -c '" in raw:
            in_embedded_py = True
            continue
        if in_embedded_py:
            if raw.startswith("' "):
                in_embedded_py = False
                line = strip_comment(raw[1:])
                s = line.strip()
                stripped_sq = re.sub(r"'[^']*'", "", line)
                n = stripped_sq.count("&&") + stripped_sq.count("||")
                if n:
                    add("&&/||", n)
            continue
        line = strip_comment(raw)
        s = line.strip()
        if not s:
            continue
        if re.search(r"\bcase\b.*\bin\b", s):
            in_case += 1
        if re.match(r"^esac\b", s):
            in_case = max(0, in_case - 1)
        if re.match(r"^(if|elif)\b", s) or re.search(r";\s*(then)\b", s) and re.match(r"^(if|elif)\b", s):
            add("if/elif")
        elif re.match(r"^(while|until|for)\b", s):
            add("loop")
        # A whole `case ... in <pats>) ... ;; esac` on ONE line (the shape the
        # is_uint / is_unum predicates use): count the patterns between `in`
        # and each `)` here, since the multi-line arm scan below only ever
        # sees arms that start their own line.
        if re.search(r"\bcase\b.*\bin\b", s) and re.search(r"\besac\b", s):
            inner = s.split(" in ", 1)[1]
            for pat in re.findall(r"([^;()]*)\)", inner):
                arms = [p.strip() for p in pat.split("|") if p.strip()]
                n = sum(1 for p in arms if p != "*")
                if n:
                    add("case-arm", n)
            in_case = 0
        elif in_case:
            m = re.match(r"^([^()|&;]*(\|[^()|&;]*)*)\)\s", s + " ")
            if m and not s.startswith("case") and not s.startswith(";;"):
                pat = m.group(1).strip()
                if pat and not pat.startswith("("):
                    arms = [p.strip() for p in pat.split("|")]
                    n = sum(1 for p in arms if p != "*")
                    if n:
                        add("case-arm", n)
        # boolean operators (&& / ||), excluding those inside single quotes
        stripped_sq = re.sub(r"'[^']*'", "", line)
        add_n = stripped_sq.count("&&") + stripped_sq.count("||")
        if add_n:
            add("&&/||", add_n)
    return cc, detail


PY_TOKENS = [
    (r"^\s*(if|elif)\b", "if/elif"),
    (r"^\s*(for|while)\b", "loop"),
    (r"^\s*except\b", "except"),
    (r"\band\b", "and"),
    (r"\bor\b", "or"),
]


def py_cc(lines):
    cc = 1
    detail = {}
    for raw in lines:
        line = raw.split("#")[0]
        for pat, key in PY_TOKENS:
            n = len(re.findall(pat, line))
            if n:
                cc += n
                detail[key] = detail.get(key, 0) + n
    return cc, detail


def crap(cc, kill_ratio):
    return cc * cc * (1 - kill_ratio) ** 3 + cc


def main():
    files = ["baton", "lib/detect.sh", "lib/accounts.sh", "lib/watch.sh"]
    print("%-24s %-18s %s" % ("function", "file", "cc  (decision points)"))
    for rel in files:
        path = os.path.join(REPO, rel)
        for name, body in sh_functions(path):
            cc, detail = sh_cc(body)
            print("%-24s %-18s %-3d %s" % (name, rel, cc, detail))
            if name == "parse_reset_epoch":
                src = "\n".join(body)
                inner = src.split("python3 -c '")[1].split("' 2>/dev/null")[0]
                # Split the embedded program into its own functions, same as
                # any other unit: resolve_tz is a function, not a statement.
                lines = inner.splitlines()
                helper, main_lines = [], []
                cur = main_lines
                helper_name = None
                for ln in lines:
                    m2 = re.match(r"^def ([A-Za-z_][A-Za-z0-9_]*)\(", ln)
                    if m2:
                        helper_name = m2.group(1)
                        cur = helper
                        continue
                    if cur is helper and ln and not ln.startswith((" ", "\t")):
                        cur = main_lines
                    (cur if cur is not None else main_lines).append(ln)
                if helper_name:
                    pcc, pdetail = py_cc(helper)
                    print("%-24s %-18s %-3d %s"
                          % ("  py: " + helper_name, rel, pcc, pdetail))
                pcc, pdetail = py_cc(main_lines)
                print("%-24s %-18s %-3d %s"
                      % ("  py: (main program)", rel, pcc, pdetail))
    # baton's top-level dispatch: everything from `case "${1:-}" in` to esac
    src = open(os.path.join(REPO, "baton")).read().splitlines()
    start = next(i for i, l in enumerate(src) if l.startswith('case "${1:-}" in'))
    cc, detail = sh_cc(src[start:])
    print("%-24s %-18s %-3d %s" % ("(top-level dispatch)", "baton", cc, detail))
    return 0


if __name__ == "__main__":
    sys.exit(main())
