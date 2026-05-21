#!/usr/bin/env python3
"""
Regression guard: fail if customer-facing architecture docs contain ASCII art
box-drawing characters. Architecture diagrams must be rendered PNGs (see
scripts/render_diagrams.py).

Files that are allowed to contain box-drawing characters (for file-tree
listings) are not in this list — only customer-facing architecture docs are
checked.

Run:
    python3 scripts/check_no_ascii_diagrams.py

Exit code 0 = clean, 1 = ASCII art found (CI should fail).
"""
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# Files we require to use rendered PNG diagrams instead of ASCII art.
GUARDED_FILES = [
    "docs/WHATSAPP.md",
    "docs/TEAMS.md",
    "templates/whatsapp-webhook/option-a-apex/README.md",
    "templates/whatsapp-webhook/option-b-node/README.md",
    "templates/teams-webhook/option-a-apex/README.md",
    "templates/teams-webhook/option-b-node/README.md",
]

# Characters that indicate an ASCII flow / architecture diagram.
# We deliberately do NOT include `─` alone or `│` alone in file-tree listings
# because guarded files don't contain file trees. If they ever do, narrow this.
DIAGRAM_CHARS = set("┌┐└┘├┤┬┴┼─│▼▶◀▲↓↑→←")


def check_file(path: Path) -> list[tuple[int, str]]:
    """Return list of (line_number, line) where diagram chars appear."""
    if not path.exists():
        return []
    issues = []
    for i, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if any(c in DIAGRAM_CHARS for c in line):
            issues.append((i, line))
    return issues


def main() -> int:
    failed = False
    for rel in GUARDED_FILES:
        path = REPO_ROOT / rel
        issues = check_file(path)
        if issues:
            failed = True
            print(f"\n❌ {rel} — contains ASCII diagram characters:")
            for line_num, line in issues[:5]:
                print(f"   line {line_num}: {line.rstrip()}")
            if len(issues) > 5:
                print(f"   ... and {len(issues) - 5} more lines")

    if failed:
        print(
            "\nGuarded docs must use rendered PNG diagrams, not ASCII art.\n"
            "To regenerate the PNGs after editing the source script, run:\n"
            "    python3 scripts/render_diagrams.py\n"
        )
        return 1

    print("✓ No ASCII diagrams in guarded docs.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
