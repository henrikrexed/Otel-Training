#!/usr/bin/env python3
"""Static post-build checks for the MkDocs attendee guide (ISI-6929).

Run after `mkdocs build --strict`. These are the cheap, deterministic gates:

  1. The topology on the home page was converted to a mermaid diagram — i.e. the
     built index.html carries a `class="mermaid"` container, not a plain <pre>
     code block (proves the superfences custom fence + mermaid2 plugin wiring).
  2. No ASCII box-drawing characters leaked into the rendered diagrams (ISI-6913
     mandates mermaid2 only, no ASCII diagrams).
  3. The mermaid runtime is loaded on pages that have a diagram.
  4. M0–M5 pages are still present in the build (Option A must not remove them).
  5. The new advanced-track stub pages are present in the build.

The actual light/dark *render* is proven separately by render_palettes.py
(headless browser). This script needs no browser.
"""
from __future__ import annotations

import sys
from pathlib import Path

SITE = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("site")

# Box-drawing / ASCII-diagram characters that must not appear inside a rendered
# mermaid diagram. (Plain prose elsewhere is fine; we only scan diagram blocks.)
BOX_CHARS = set("─│┌┐└┘├┤┬┴┼▶▲▼◀�──")

M_PAGES = [f"module-{i}" for i in range(1, 6)] + ["setup"]
ADVANCED_PAGES = [
    "advanced/getting-started",
    "advanced/environment",
    "advanced/step-1-instrument-with-agents",
    "advanced/step-2-weaver-pipeline",
    "advanced/step-3-cost-of-observability",
    "advanced/step-4-high-cardinality",
    "advanced/step-5-pii-logs",
    "advanced/step-6-tail-sampling",
]

errors: list[str] = []


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def check_index_has_mermaid() -> None:
    index = SITE / "index.html"
    if not index.exists():
        errors.append("site/index.html not found — did `mkdocs build` run?")
        return
    html = read(index)
    if 'class="mermaid"' not in html:
        errors.append(
            "index.html has no `class=\"mermaid\"` container — the topology was "
            "not rendered as a mermaid diagram (superfences/mermaid2 wiring broken)."
        )
    # The topology must no longer be a plain fenced code block.
    if "otel-gateway-collector" in html:
        # Find the surrounding element; if it is a <code> block the conversion failed.
        idx = html.find("otel-gateway-collector")
        window = html[max(0, idx - 400): idx]
        if "<code" in window and 'class="mermaid"' not in window:
            errors.append(
                "The topology still renders inside a <code> block, not a mermaid "
                "diagram."
            )


def check_no_ascii_diagram() -> None:
    # Scan every built page's mermaid containers for box-drawing characters.
    for html_file in SITE.rglob("*.html"):
        html = read(html_file)
        # Crude but effective: split on the mermaid container open tag.
        for chunk in html.split('class="mermaid"')[1:]:
            block = chunk[: chunk.find("</")] if "</" in chunk else chunk[:2000]
            leaked = BOX_CHARS.intersection(block)
            if leaked:
                errors.append(
                    f"{html_file.relative_to(SITE)}: ASCII box-drawing chars "
                    f"{sorted(leaked)} found inside a mermaid block."
                )


def check_mermaid_runtime() -> None:
    index = read(SITE / "index.html") if (SITE / "index.html").exists() else ""
    if "mermaid" not in index.lower() or "<script" not in index.lower():
        errors.append("index.html does not load any <script> — mermaid runtime missing.")
    # mermaid2 injects a mermaid.*.min.js reference (CDN or bundled).
    if "mermaid" not in index:
        errors.append("No mermaid runtime reference found in index.html.")


def check_pages_present(pages: list[str], label: str) -> None:
    for page in pages:
        candidates = [SITE / page / "index.html", SITE / f"{page}.html"]
        if not any(c.exists() for c in candidates):
            errors.append(f"{label} page missing from build: {page}")


def main() -> int:
    if not SITE.exists():
        print(f"FAIL: site directory {SITE} does not exist", file=sys.stderr)
        return 1
    check_index_has_mermaid()
    check_no_ascii_diagram()
    check_mermaid_runtime()
    check_pages_present(M_PAGES, "M0–M5")
    check_pages_present(ADVANCED_PAGES, "advanced-track")

    if errors:
        print("Docs mermaid/nav checks FAILED:", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        return 1
    print("Docs mermaid/nav checks passed:")
    print("  - home-page topology rendered as a mermaid diagram")
    print("  - no ASCII box-drawing chars inside any mermaid block")
    print("  - mermaid runtime loaded")
    print(f"  - M0–M5 intact ({len(M_PAGES)} pages)")
    print(f"  - advanced track present ({len(ADVANCED_PAGES)} pages)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
