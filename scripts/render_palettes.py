#!/usr/bin/env python3
"""Headless render check for mermaid in both Material palettes (ISI-6929).

Proves the acceptance criterion "mermaid renders in both default and slate
palettes". Serves the built `site/` over HTTP, then for each palette:

  * seeds localStorage("__palette") with that palette's scheme,
  * loads the home page in headless Chromium (so the mermaid2 runtime executes),
  * waits for mermaid to replace the `.mermaid` container with an <svg>,
  * asserts the diagram's computed theme matches the palette (dark vs light),
    by checking the rendered node fill is dark-on-light vs light-on-dark.

Requires: playwright (`pip install playwright && playwright install chromium`).
Usage: python scripts/render_palettes.py [site_dir] [port]
"""
from __future__ import annotations

import functools
import http.server
import socketserver
import sys
import threading
from pathlib import Path

try:
    from playwright.sync_api import sync_playwright
except ImportError:  # pragma: no cover
    print("playwright not installed; skipping render check", file=sys.stderr)
    raise SystemExit(2)

SITE = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("site")
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8123

PALETTES = [
    {"name": "default (light)", "scheme": "default", "expect": "light"},
    {"name": "slate (dark)", "scheme": "slate", "expect": "dark"},
]


def serve(directory: Path, port: int) -> socketserver.TCPServer:
    handler = functools.partial(
        http.server.SimpleHTTPRequestHandler, directory=str(directory)
    )
    httpd = socketserver.TCPServer(("127.0.0.1", port), handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd


def luminance(rgb: str) -> float:
    # rgb string like "rgb(12, 34, 56)" -> perceived luminance 0..255
    nums = [int(x) for x in rgb.replace("rgb(", "").replace(")", "").split(",")[:3]]
    return 0.299 * nums[0] + 0.587 * nums[1] + 0.114 * nums[2]


def check_palette(page, base_url: str, palette: dict) -> str | None:
    # Seed Material's persisted palette, then load so mermaid2 reads it back.
    page.goto(base_url, wait_until="domcontentloaded")
    page.evaluate(
        """(scheme) => localStorage.setItem('__palette',
            JSON.stringify({index: scheme === 'slate' ? 1 : 0,
                            color: {scheme: scheme}}))""",
        palette["scheme"],
    )
    page.goto(base_url, wait_until="networkidle")
    try:
        page.wait_for_selector(".mermaid svg", timeout=20000)
    except Exception:
        return f"{palette['name']}: mermaid never produced an <svg> (render failed)"

    svgs = page.query_selector_all(".mermaid svg")
    if not svgs:
        return f"{palette['name']}: no rendered <svg> found"

    # Sanity: the diagram's node text color should contrast with the palette.
    # dark theme -> light text (high luminance); light theme -> dark text.
    color = page.evaluate(
        """() => {
            const t = document.querySelector('.mermaid svg text, .mermaid svg .nodeLabel');
            if (!t) return null;
            return getComputedStyle(t).fill || getComputedStyle(t).color;
        }"""
    )
    if color and color.startswith("rgb"):
        lum = luminance(color)
        if palette["expect"] == "dark" and lum < 128:
            return (
                f"{palette['name']}: expected light text in dark theme, "
                f"got {color} (lum={lum:.0f})"
            )
        if palette["expect"] == "light" and lum > 128:
            return (
                f"{palette['name']}: expected dark text in light theme, "
                f"got {color} (lum={lum:.0f})"
            )
    return None


def main() -> int:
    if not (SITE / "index.html").exists():
        print(f"FAIL: {SITE}/index.html missing; run mkdocs build first", file=sys.stderr)
        return 1

    httpd = serve(SITE, PORT)
    base_url = f"http://127.0.0.1:{PORT}/"
    errors: list[str] = []
    try:
        with sync_playwright() as p:
            browser = p.chromium.launch()
            page = browser.new_page()
            for palette in PALETTES:
                err = check_palette(page, base_url, palette)
                if err:
                    errors.append(err)
                else:
                    print(f"  - {palette['name']}: mermaid rendered an <svg> ✓")
            browser.close()
    finally:
        httpd.shutdown()

    if errors:
        print("Palette render check FAILED:", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        return 1
    print("Palette render check passed: mermaid renders in both palettes.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
