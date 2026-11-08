#!/usr/bin/env python3
"""Stop personal information from going public.

Runs before every commit (git hook), before every push, and on every release (./build.sh release),
over the files going into git and over the built app and DMG.

    tools/privacy-check.py --staged          files staged for commit
    tools/privacy-check.py --all             every tracked file
    tools/privacy-check.py --binary PATH...  built apps / DMGs (their strings), recursively

What counts as personal:
  - built in: home-folder paths (/Users/<name>), email addresses, private and Tailscale IP addresses,
    access tokens and API keys;
  - yours: one pattern per line in ~/.config/bugos/private-patterns (your name, usernames, emails, ids…).
    That file lives outside the repo on purpose, so the list itself never gets published.
Allowed: the project's own GitHub address (github.com/<owner>/BugOS), which the updater needs.

Exit 0 = clean, 1 = something personal was found (each hit is printed, without the matching value).
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PRIVATE = os.path.expanduser("~/.config/bugos/private-patterns")

BUILT_IN = [
    ("home folder path", r"/Users/(?!x/|Shared/|\$)[A-Za-z0-9._-]{2,}"),
    ("email address", r"[A-Za-z0-9._%+-]+@(?!users\.noreply\.github\.com)(?!anthropic\.com)[A-Za-z0-9.-]+\.[A-Za-z]{2,}"),
    ("Tailscale IP", r"\b100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.\d{1,3}\.\d{1,3}\b"),
    ("private IP", r"\b(192\.168|10\.\d{1,3}|172\.(1[6-9]|2\d|3[01]))\.\d{1,3}\.\d{1,3}\b"),
    ("GitHub token", r"\bgh[pousr]_[A-Za-z0-9]{20,}"),
    ("API key", r"\b(sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,})"),
    ("private key", r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
]
# The repo's own address is fine (the updater checks it for new versions).
ALLOWED = [r"github\.com/[A-Za-z0-9-]+/BugOS", r"api\.github\.com/repos/[A-Za-z0-9-]+/BugOS", r"[A-Za-z0-9-]+/BugOS\b"]
SKIP_FILES = {"tools/privacy-check.py"}   # this file describes the patterns


def patterns():
    pats = [(name, re.compile(p)) for name, p in BUILT_IN]
    if os.path.exists(PRIVATE):
        for line in open(PRIVATE, encoding="utf-8"):
            line = line.strip()
            if line and not line.startswith("#"):
                pats.append(("one of your private patterns", re.compile(re.escape(line), re.IGNORECASE)))
    else:
        print(f"note: no {PRIVATE}; only the built-in checks ran", file=sys.stderr)
    return pats


def clean(text):
    for a in ALLOWED:
        text = re.sub(a, "", text, flags=re.IGNORECASE)
    return text


def scan_text(label, text, pats, hits):
    text = clean(text)
    for n, line in enumerate(text.splitlines(), 1):
        for name, p in pats:
            if p.search(line):
                hits.append(f"{label}:{n}: {name}")


def git(*args):
    return subprocess.run(["git", "-C", ROOT, *args], capture_output=True, text=True).stdout


def scan_git(staged, pats, hits):
    files = git("diff", "--cached", "--name-only", "--diff-filter=ACMR") if staged else git("ls-files")
    for f in filter(None, files.splitlines()):
        if f in SKIP_FILES:
            continue
        # Staged: what's in the index, not the working copy.
        data = subprocess.run(["git", "-C", ROOT, "show", f":{f}"], capture_output=True).stdout if staged \
            else open(os.path.join(ROOT, f), "rb").read()
        scan_text(f, data.decode("utf-8", "replace"), pats, hits)
        scan_text(f + " (file name)", f, pats, hits)
    # The commit's author shows publicly too.
    # Use GitHub's private noreply address for commits; it names the account, which is public anyway.
    for who in ("user.name", "user.email"):
        v = git("config", who).strip()
        if v and not (who == "user.email" and v.endswith("@users.noreply.github.com")):
            scan_text(f"git {who}", v, pats, hits)


def scan_binaries(paths, pats, hits):
    for top in paths:
        if top.endswith(".dmg"):
            mnt = subprocess.run(["hdiutil", "attach", "-nobrowse", "-readonly", "-noautoopen", top],
                                 capture_output=True, text=True).stdout.strip().split("\t")[-1]
            try:
                scan_binaries([mnt], pats, hits)
            finally:
                subprocess.run(["hdiutil", "detach", mnt, "-quiet"])
            continue
        walk = [(top, [], [os.path.basename(top)])] if os.path.isfile(top) else os.walk(top)
        for d, _, files in walk:
            for name in files:
                p = os.path.join(d, name) if os.path.isdir(top) else top
                if os.path.islink(p):
                    continue
                out = subprocess.run(["strings", "-a", "-n", "5", p], capture_output=True, text=True, errors="replace").stdout
                rel = os.path.relpath(p, os.path.dirname(top))
                scan_text(rel, out, pats, hits)
                scan_text(rel + " (file name)", rel, pats, hits)


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 2
    pats, hits = patterns(), []
    if args[0] == "--staged":
        scan_git(True, pats, hits)
    elif args[0] == "--all":
        scan_git(False, pats, hits)
    elif args[0] == "--binary":
        scan_binaries(args[1:], pats, hits)
    else:
        print(__doc__)
        return 2
    if hits:
        print("Privacy check FAILED: personal information would go public.")
        for h in sorted(set(hits)):
            print("  " + h)
        print("Remove it (or, if it's really fine, adjust ~/.config/bugos/private-patterns) and try again.")
        return 1
    print("Privacy check passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
