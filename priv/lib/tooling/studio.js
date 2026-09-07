// tooling/studio.js — the browser half of the studio.
//
// It never touches the app's DOM. It listens to the seam live/client.js
// announces (live:mount / live:patch / live:tap) and draws in its OWN
// overlay layer; it talks to the server over the pulse feed the chip already
// holds. Each instrument is a small object with enable()/disable(); the chip
// toggles them and persists the choice in localStorage.
//
//   Studio.paint    flash the exact elements each patch op touched
//
(function () {
  if (window.Studio) return;
  var Studio = (window.Studio = { instruments: {} });

  // ── shared: overlay layer + geometry ──────────────────────────────
  var layer = null;
  function overlay() {
    if (layer) return layer;
    layer = document.createElement("div");
    layer.id = "studio-overlay";
    layer.style.cssText =
      "position:fixed;inset:0;pointer-events:none;z-index:2147482000;font:11px/1.3 ui-monospace,Menlo,monospace";
    document.body.appendChild(layer);
    return layer;
  }
  function rectOf(node) {
    if (!node) return null;
    if (node.nodeType === 3) {
      var r = document.createRange();
      r.selectNodeContents(node);
      var b = r.getBoundingClientRect();
      return b.width || b.height ? b : (node.parentElement && node.parentElement.getBoundingClientRect());
    }
    if (node.getBoundingClientRect) return node.getBoundingClientRect();
    return null;
  }
  // the element a differ path lands on AFTER the patch applied (so an insert
  // or move resolves to the node now at that slot).
  function targetOf(root, op) {
    var kind = op[0], path = op[1];
    try {
      if (kind === "insert" || kind === "move") {
        var parent = window.Live.at(root, path);
        var idx = kind === "insert" ? op[3] : op[3];
        var kids = childrenOf(parent);
        return kids[idx] || parent;
      }
      if (kind === "remove" || kind === "remove-at") return window.Live.at(root, path);
      return window.Live.at(root, path);
    } catch (_e) { return null; }
  }
  function childrenOf(el) {
    var out = [];
    for (var n = el.firstChild; n; n = n.nextSibling)
      if (n.nodeType === 1 || n.nodeType === 3) out.push(n);
    return out;
  }
  // who owns this node: nearest traced/component root (data-tr), else the
  // nearest keyed row (data-key) — both are ownership signals the render
  // already emits, so no extra instrumentation is needed.
  function ownerOf(node) {
    var el = node && node.nodeType === 3 ? node.parentElement : node;
    while (el && el.nodeType === 1) {
      if (el.hasAttribute("data-tr")) return { kind: "component", name: el.getAttribute("data-tr") };
      if (el.hasAttribute("data-key")) return { kind: "row", name: el.getAttribute("data-key") };
      el = el.parentElement;
    }
    return { kind: "screen", name: "root" };
  }
  Studio.ownerOf = ownerOf;
  Studio.targetOf = targetOf;

  var COLORS = {
    text: "#4cc2ff", "set-attr": "#ffd166", "remove-attr": "#ffd166",
    insert: "#46d18f", remove: "#ff5c8a", "remove-at": "#ff5c8a",
    move: "#c084fc", replace: "#ff8c42"
  };
  Studio.colors = COLORS;

  // ── Paint: flash what each op touched ─────────────────────────────
  var paint = (Studio.instruments.paint = {
    on: false,
    boxes: [],
    enable: function () { paint.on = true; },
    disable: function () { paint.on = false; paint.clear(); },
    clear: function () {
      paint.boxes.forEach(function (b) { b.remove(); });
      paint.boxes = [];
    },
    // draw one flash for an op; keeps the box for `hold` ms then fades
    flash: function (root, op, t, hold) {
      var node = targetOf(root, op);
      var r = rectOf(node);
      if (!r) return;
      var kind = op[0];
      var color = COLORS[kind] || "#e6edf3";
      var own = ownerOf(node);
      var box = document.createElement("div");
      box.className = "studio-flash";
      box.style.cssText =
        "position:absolute;left:" + (r.left - 3) + "px;top:" + (r.top - 3) + "px;width:" +
        (r.width + 6) + "px;height:" + (r.height + 6) + "px;border:2px solid " + color +
        ";border-radius:6px;box-shadow:0 0 0 4px " + color + "33,0 0 18px " + color +
        "88;transition:opacity .9s ease;pointer-events:auto;background:" + color + "14";
      var tag = document.createElement("div");
      tag.style.cssText =
        "position:absolute;left:-2px;top:-20px;background:" + color +
        ";color:#0a0e14;padding:1px 6px;border-radius:4px;font-weight:700;white-space:nowrap";
      tag.textContent = kind + (t ? " · t" + t : "") + " · " + own.kind + ":" + own.name;
      box.appendChild(tag);
      box.title = kind + " @ [" + op[1].join(" ") + "]  owner " + own.kind + ":" + own.name +
        (kind === "text" ? '  → "' + op[2] + '"' : kind === "set-attr" ? "  " + op[2] + "=" + op[3] : "");
      overlay().appendChild(box);
      paint.boxes.push(box);
      var life = hold || 3000;
      setTimeout(function () { box.style.opacity = "0"; }, life);
      setTimeout(function () {
        box.remove();
        paint.boxes = paint.boxes.filter(function (b) { return b !== box; });
      }, life + 950);
    },
    // paint a whole patch (list of ops) — the entry the seam calls
    patch: function (root, ops, t) {
      if (!paint.on) return;
      ops.forEach(function (op) { paint.flash(root, op, t, 3000); });
    }
  });

  // correlate: the tap :t arrives right after the patch it stamps, so we
  // hold the last ops and paint them once t is known (else paint without t).
  var pendingOps = null, pendingRoot = null;
  document.addEventListener("live:patch", function (e) {
    pendingOps = e.detail.ops; pendingRoot = e.detail.root;
    setTimeout(function () {
      if (pendingOps) { paint.patch(pendingRoot, pendingOps, null); pendingOps = null; }
    }, 30);
  });
  document.addEventListener("live:tap", function (e) {
    if (pendingOps) { paint.patch(pendingRoot, pendingOps, e.detail.t); pendingOps = null; }
    Studio.lastT = e.detail.t;
  });

  // ── persistence + chip toggles ────────────────────────────────────
  Studio.toggle = function (name, on) {
    var inst = Studio.instruments[name];
    if (!inst) return;
    if (on === undefined) on = !inst.on;
    on ? inst.enable() : inst.disable();
    try { localStorage.setItem("studio." + name, on ? "1" : "0"); } catch (_e) {}
    document.dispatchEvent(new CustomEvent("studio:toggle", { detail: { name: name, on: on } }));
    return on;
  };
  Studio.restore = function () {
    Object.keys(Studio.instruments).forEach(function (n) {
      var v = null;
      try { v = localStorage.getItem("studio." + n); } catch (_e) {}
      if (v === "1") Studio.toggle(n, true);
    });
  };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", Studio.restore);
  else Studio.restore();
})();
