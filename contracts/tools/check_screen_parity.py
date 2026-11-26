"""Check that the website's screens and the app's screens use the same features.

The owner's rule since 2026-10-24: the website is a replica of the app. A feature is, for this
check, a repository method a screen calls: the app reaches repositories through Riverpod
providers (`ref.read(xRepositoryProvider).method(`), the website through its repository
singletons (`xRepository.method(`). Both sides are read, the names are folded where a method
lives in a differently named repository on one side, and what is left on one side only must be a
known platform difference. Anything else is a feature one app has and the other lacks.

A platform difference is either one method (PLATFORM) or a whole repository the website must not
have at all (PLATFORM_REPOSITORIES, an owner decision such as OD-39). Every app call on such a
repository is exempt, and every website call on one is a gap whether or not the app makes it too.

Read:
  Dart  apps/mobile/lib/**/*.dart
  TS    apps/web-customer/src/app/**/*.tsx, apps/web-customer/src/components/**/*.tsx

Usage: python3 contracts/tools/check_screen_parity.py <repo root>   (exit 1 on any gap)
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# The website's name → the app's name, for methods that live in a different repository.
ALIASES = {
    ("providerJob", "getProofs"): ("jobProgress", "getProofs"),
    ("providerJob", "requestStatusChange"): ("jobProgress", "requestStatusChange"),
    ("providerJob", "submitProof"): ("jobProgress", "submitProof"),
    ("providerJob", "recordGoodsReceipt"): ("jobProgress", "recordGoodsReceipt"),
    ("providerJob", "verifyHandoverPin"): ("jobProgress", "verifyHandoverPin"),
    ("providerJob", "publishProviderLocation"): ("tracking", "publishProviderLocation"),
    ("provider", "reportPosition"): ("tracking", "reportPosition"),
}

# One side only, on purpose: the same feature reached the way each platform reaches it.
PLATFORM = {
    ("auth", "signInWithIdToken"): "native Google/Apple sheet; the website redirects (signInWithProvider)",
    ("auth", "signInWithProvider"): "browser OAuth redirect; the app uses the native sheet (signInWithIdToken)",
    ("providerKyc", "watchKycProfile"): "the app streams the profile; the website reads it (getKycProfile)",
    ("providerKyc", "getKycProfile"): "the website reads the profile; the app streams it (watchKycProfile)",
    ("support", "getTickets"): "the website reads tickets; the app streams them (watchTickets)",
    ("support", "watchTickets"): "the app streams tickets; the website reads them (getTickets)",
    ("user", "getProfile"): "the website reads the profile; the app streams it (watchProfile)",
    ("user", "watchProfile"): "the app streams the profile; the website reads it (getProfile)",
}

# Whole repositories that are app-only by an owner decision, not by a screen nobody built yet:
# repository (as _norm leaves it) -> the decision and its reason. Empty until Meet v5 M1, which
# lists the 18+ repositories here under OD-39 (decided 2026-11-26: discovery, chat, statuses,
# games, Cowries and calls are Android-app-only).
PLATFORM_REPOSITORIES: dict[str, str] = {}


def _norm(repo: str) -> str:
    repo = repo[0].lower() + repo[1:]
    return repo.replace("RepositoryProvider", "").replace("Repository", "")


def app_calls(root: Path) -> set[tuple[str, str]]:
    calls: set[tuple[str, str]] = set()
    for path in (root / "apps/mobile/lib").rglob("*.dart"):
        text = path.read_text(encoding="utf-8")
        # ref.read(xRepositoryProvider).method(   — on one line or broken before the dot
        for m in re.finditer(r"(\w+RepositoryProvider)\)?\s*\.\s*(\w+)\s*\(", text):
            calls.add((_norm(m.group(1)), m.group(2)))
        # final repo = ref.read(xRepositoryProvider); … repo.method(   and fields held on State
        for m in re.finditer(r"(\w+)\s*=\s*ref\.(?:read|watch)\((\w+RepositoryProvider)\)", text):
            held = re.escape(m.group(1))
            for c in re.finditer(r"\b" + held + r"\s*[?!]?\s*\.\s*(\w+)\s*\(", text):
                calls.add((_norm(m.group(2)), c.group(1)))
        # The auth page holds the auth repository as `auth`; verification goes through `adapter`.
        for m in re.finditer(r"\b(auth|adapter)\.(\w+)\(", text):
            calls.add(({"auth": "auth", "adapter": "verification"}[m.group(1)], m.group(2)))
    return calls


def website_calls(root: Path) -> set[tuple[str, str]]:
    calls: set[tuple[str, str]] = set()
    web = root / "apps/web-customer/src"
    for path in [*(web / "app").rglob("*.tsx"), *(web / "components").rglob("*.tsx")]:
        text = path.read_text(encoding="utf-8")
        for m in re.finditer(r"\b(\w+Repository)\s*\.\s*(\w+)\s*\(", text):
            key = (_norm(m.group(1)), m.group(2))
            if key[0].startswith(("supabase", "mock")):
                continue
            calls.add(ALIASES.get(key, key))
    return calls


def report(app: set[tuple[str, str]], website: set[tuple[str, str]]) -> tuple[list[str], int]:
    """The lines to print, and how many of them are gaps."""
    lines: list[str] = []
    gaps = 0
    for side, only in (("app only", sorted(app - website)), ("website only", sorted(website - app))):
        for key in only:
            if key[0] in PLATFORM_REPOSITORIES:
                if side == "app only":
                    lines.append(f"  {side}: {'.'.join(key)} ({PLATFORM_REPOSITORIES[key[0]]})")
                continue  # a website call on an app-only repository is reported once, below
            reason = PLATFORM.get(key)
            if reason is None:
                gaps += 1
                lines.append(f"::error::{side}: {'.'.join(key)} — a feature one app has and the other lacks")
            else:
                lines.append(f"  {side}: {'.'.join(key)} ({reason})")
    for key in sorted(k for k in website if k[0] in PLATFORM_REPOSITORIES):
        gaps += 1
        lines.append(f"::error::website: {'.'.join(key)} — {key[0]} is app-only and the website must not "
                     f"call it ({PLATFORM_REPOSITORIES[key[0]]})")
    return lines, gaps


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__)
        return 2
    root = Path(argv[1])
    app, website = app_calls(root), website_calls(root)
    lines, gaps = report(app, website)
    for line in lines:
        print(line)
    print(f"check_screen_parity: app screens call {len(app)} repository methods, "
          f"website screens {len(website)}; {gaps} gap(s)")
    return 1 if gaps else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
