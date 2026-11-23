/*
 * Mermaid diagram zoom / lightbox (ISI-7632, addresses #59).
 *
 * Makes every rendered Mermaid diagram clickable-to-enlarge, site-wide, with
 * no dependency and — crucially — WITHOUT an `extra_javascript:` entry in
 * mkdocs.yml. mkdocs-mermaid2 1.2.x scans the whole `extra_javascript` list and
 * treats any basename containing "mermaid" as the library override, which makes
 * it skip loading the real runtime (diagrams silently fail). This file is wired
 * in via a `theme.custom_dir` template override (overrides/main.html) instead,
 * so the mermaid2 plugin never sees it.
 *
 * mermaid2 renders asynchronously (startOnLoad=false under the superfences
 * custom loader), so we watch the DOM with a MutationObserver and attach the
 * zoom affordance to each diagram's <svg> as soon as it appears, regardless of
 * when the mermaid runtime finishes.
 */
(function () {
  "use strict";

  var PROCESSED = "data-mermaidZoomReady";
  var overlay, stage, closeBtn, lastTrigger;
  var scale = 1, tx = 0, ty = 0;        // current zoom/pan transform
  var dragging = false, startX = 0, startY = 0;

  function buildOverlay() {
    if (overlay) return;
    overlay = document.createElement("div");
    overlay.className = "mermaid-zoom";
    overlay.setAttribute("role", "dialog");
    overlay.setAttribute("aria-modal", "true");
    overlay.setAttribute("aria-label", "Enlarged diagram");
    overlay.hidden = true;

    closeBtn = document.createElement("button");
    closeBtn.type = "button";
    closeBtn.className = "mermaid-zoom__close";
    closeBtn.setAttribute("aria-label", "Close enlarged diagram");
    closeBtn.innerHTML = "&times;";

    stage = document.createElement("div");
    stage.className = "mermaid-zoom__stage";

    overlay.appendChild(closeBtn);
    overlay.appendChild(stage);
    document.body.appendChild(overlay);

    closeBtn.addEventListener("click", close);
    overlay.addEventListener("click", function (e) {
      // Click on the backdrop (not the SVG itself) closes.
      if (e.target === overlay || e.target === stage) close();
    });
    overlay.addEventListener("wheel", onWheel, { passive: false });
    overlay.addEventListener("mousedown", onDown);
    window.addEventListener("mouseup", onUp);
    window.addEventListener("mousemove", onMove);
    document.addEventListener("keydown", function (e) {
      if (!overlay.hidden && e.key === "Escape") close();
    });
  }

  function applyTransform() {
    var svg = stage.firstChild;
    if (svg) svg.style.transform = "translate(" + tx + "px," + ty + "px) scale(" + scale + ")";
  }

  function open(svg) {
    buildOverlay();
    lastTrigger = svg;
    scale = 1; tx = 0; ty = 0;
    stage.innerHTML = "";
    var clone = svg.cloneNode(true);
    clone.removeAttribute(PROCESSED);
    // Let CSS size it to fit the viewport; drop mermaid's inline max-width cap.
    clone.style.maxWidth = "none";
    clone.style.maxHeight = "none";
    stage.appendChild(clone);
    applyTransform();
    overlay.hidden = false;
    document.body.classList.add("mermaid-zoom-open");
    closeBtn.focus();
  }

  function close() {
    if (!overlay) return;
    overlay.hidden = true;
    stage.innerHTML = "";
    document.body.classList.remove("mermaid-zoom-open");
    // Return focus to the diagram that opened the lightbox (a11y).
    if (lastTrigger) {
      lastTrigger.focus();
      lastTrigger = null;
    }
  }

  function onWheel(e) {
    e.preventDefault();
    var factor = e.deltaY < 0 ? 1.12 : 1 / 1.12;
    scale = Math.min(8, Math.max(0.4, scale * factor));
    applyTransform();
  }

  function onDown(e) {
    if (e.target === closeBtn) return;
    dragging = true;
    startX = e.clientX - tx;
    startY = e.clientY - ty;
    overlay.classList.add("is-dragging");
    e.preventDefault();
  }

  function onMove(e) {
    if (!dragging) return;
    tx = e.clientX - startX;
    ty = e.clientY - startY;
    applyTransform();
  }

  function onUp() {
    dragging = false;
    if (overlay) overlay.classList.remove("is-dragging");
  }

  function enhance(svg) {
    if (svg.getAttribute(PROCESSED)) return;
    svg.setAttribute(PROCESSED, "1");
    svg.classList.add("mermaid-zoomable");
    svg.setAttribute("role", "button");
    svg.setAttribute("tabindex", "0");
    svg.setAttribute("aria-label", "Enlarge diagram");
    svg.addEventListener("click", function () { open(svg); });
    svg.addEventListener("keydown", function (e) {
      if (e.key === "Enter" || e.key === " ") {
        e.preventDefault();
        open(svg);
      }
    });
  }

  function scan() {
    // Covers both markings mermaid2 can emit: pre.mermaid (custom loader) and
    // div.mermaid (standard). Only <svg> that mermaid has already rendered.
    var nodes = document.querySelectorAll(
      "pre.mermaid > svg, div.mermaid > svg, .mermaid > svg"
    );
    for (var i = 0; i < nodes.length; i++) enhance(nodes[i]);
  }

  function start() {
    scan();
    var mo = new MutationObserver(function () { scan(); });
    mo.observe(document.body, { childList: true, subtree: true });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start);
  } else {
    start();
  }
})();
