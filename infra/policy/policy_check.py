#!/usr/bin/env python3
"""Project policy checks that generic scanners do not know about.

Each rule comes from a decision already recorded in the repository:

  P1  ADR-0010      rejected client packages never enter a manifest or lockfile
  P2  ADR-0002      user-facing copy never calls held funds "escrow"
  P3  CLAUDE.md     no server secret or service-role credential in client code
  P4  PRD SH-02/25  no READ_CONTACTS / READ_SMS / RECEIVE_SMS Android permissions
                    (Contact Picker and SMS Retriever make them unnecessary; Play policy)

Runs on the whole repository, including Kimi Code's apps and packages: it reports, it never
edits. Prints GitHub annotations and exits 1 on any finding. Standard library only.

Usage: python infra/policy/policy_check.py [repo_root]
"""

from __future__ import annotations

import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path

SKIP_DIRS = {
    ".git", ".dart_tool", "build", "node_modules", ".terraform", ".next", "Pods",
    ".gradle", "ephemeral", ".symlinks", "spikes",
}

BANNED_PACKAGES = {
    "flutterwave_standard": "ADR-0010: use a server-created hosted checkout link",
    "app_device_integrity": "ADR-0010: use a thin platform channel verified by the device-integrity function",
    "background_locator_2": "ADR-0010: use flutter_foreground_task + geolocator (spike S-04)",
    "prembly_identity_kyc": "ADR-0010: Smile ID per ADR-0005",
    "flutter_background_geolocation": "ADR-0010: paid licence; only after spike S-04 and client approval",
}
MANIFEST_NAMES = {"pubspec.yaml", "pubspec.lock", "package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock"}

COPY_SUFFIXES = {".arb"}
COPY_JSON_DIR_HINTS = ("locales", "messages", "i18n", "l10n")
ESCROW = re.compile(r"\bescrow", re.IGNORECASE)

CLIENT_ROOTS = ("apps", "packages")
CLIENT_SUFFIXES = {".dart", ".ts", ".tsx", ".js", ".jsx", ".json", ".yaml", ".yml", ".env", ".xml", ".plist", ".properties", ".gradle", ".kts"}
SECRET_PATTERNS = [
    (re.compile(r"service_role", re.IGNORECASE), "Supabase service role reference"),
    (re.compile(r"sb_secret_[A-Za-z0-9_-]{10,}"), "Supabase secret API key"),
    (re.compile(r"SUPABASE_SECRET_KEYS?"), "Supabase secret key variable"),
    # base64 of '"role":"service_role"' inside a JWT payload
    (re.compile(r"InJvbGUiOiJzZXJ2aWNlX3JvbGUi"), "JWT carrying the service_role claim"),
    (re.compile(r"FLWSECK(_TEST)?-[A-Za-z0-9]{8,}"), "Flutterwave secret key"),
    (re.compile(r"\bsk_(live|test)_[A-Za-z0-9]{16,}"), "Paystack or Stripe secret key"),
    (re.compile(r"whsec_[A-Za-z0-9+/=]{20,}"), "webhook signing secret"),
    (re.compile(r"-----BEGIN (RSA |EC )?PRIVATE KEY-----"), "private key"),
]

FORBIDDEN_ANDROID_PERMISSIONS = {
    "android.permission.READ_CONTACTS": "PRD SH-25: use the Android Contact Picker",
    "android.permission.READ_SMS": "PRD SH-02: use the SMS Retriever API",
    "android.permission.RECEIVE_SMS": "PRD SH-02: use the SMS Retriever API",
}


@dataclass(frozen=True)
class Finding:
    rule: str
    path: str
    line: int
    message: str

    def annotation(self) -> str:
        return f"::error file={self.path},line={self.line},title={self.rule}::{self.message}"


def iter_files(root: Path):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            yield Path(dirpath) / name


def read_lines(path: Path) -> list[str]:
    try:
        return path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return []


def check_banned_packages(root: Path, path: Path) -> list[Finding]:
    if path.name not in MANIFEST_NAMES:
        return []
    findings = []
    for number, line in enumerate(read_lines(path), start=1):
        for package, reason in BANNED_PACKAGES.items():
            if re.search(rf"(^|[\s\"'/]){re.escape(package)}([\"':\s]|$)", line):
                findings.append(Finding("P1-banned-package", rel(root, path), number, f"{package} is not allowed ({reason})"))
    return findings


def is_copy_file(root: Path, path: Path) -> bool:
    relative = path.relative_to(root)
    if not relative.parts or relative.parts[0] not in CLIENT_ROOTS:
        return False
    if path.suffix in COPY_SUFFIXES:
        return True
    return path.suffix == ".json" and any(hint in relative.parts for hint in COPY_JSON_DIR_HINTS)


def check_escrow(root: Path, path: Path) -> list[Finding]:
    if not is_copy_file(root, path):
        return []
    return [
        Finding("P2-escrow-copy", rel(root, path), number,
                'User-facing copy must say funds are "held by Suskii", never "escrow" (ADR-0002)')
        for number, line in enumerate(read_lines(path), start=1)
        if ESCROW.search(line)
    ]


def check_client_secrets(root: Path, path: Path) -> list[Finding]:
    relative = path.relative_to(root)
    if not relative.parts or relative.parts[0] not in CLIENT_ROOTS:
        return []
    if path.suffix not in CLIENT_SUFFIXES and not path.name.startswith(".env"):
        return []
    findings = []
    for number, line in enumerate(read_lines(path), start=1):
        for pattern, label in SECRET_PATTERNS:
            if pattern.search(line):
                findings.append(Finding("P3-client-secret", rel(root, path), number,
                                        f"{label} in client code: clients use only the publishable key"))
    return findings


def check_android_permissions(root: Path, path: Path) -> list[Finding]:
    if path.name != "AndroidManifest.xml":
        return []
    findings = []
    for number, line in enumerate(read_lines(path), start=1):
        for permission, reason in FORBIDDEN_ANDROID_PERMISSIONS.items():
            if permission in line:
                findings.append(Finding("P4-android-permission", rel(root, path), number, f"{permission} is not allowed ({reason})"))
    return findings


def rel(root: Path, path: Path) -> str:
    return path.relative_to(root).as_posix()


CHECKS = (check_banned_packages, check_escrow, check_client_secrets, check_android_permissions)


def run(root: Path) -> list[Finding]:
    findings: list[Finding] = []
    for path in iter_files(root):
        for check in CHECKS:
            findings.extend(check(root, path))
    return sorted(findings, key=lambda f: (f.path, f.line, f.rule))


def main(argv: list[str]) -> int:
    root = Path(argv[1] if len(argv) > 1 else ".").resolve()
    findings = run(root)
    for finding in findings:
        print(finding.annotation())
    print(f"policy_check: {len(findings)} finding(s)")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
