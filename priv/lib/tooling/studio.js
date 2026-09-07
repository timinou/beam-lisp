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

  // ── Timeline: scrub back through every frame ──────────────────────
  //
  // The server kept every frame's TREE as a value, so "the screen at t" is
  // just hiccup->html of that value — no replay, no re-running events. The
  // past is shown in a COVER laid exactly over the live root; the live root
  // keeps receiving patches underneath, untouched. Release → cover gone,
  // and you are back on the present with nothing to reconcile.
  function cover() {
    var c = document.getElementById("studio-cover");
    if (c) return c;
    c = document.createElement("div");
    c.id = "studio-cover";
    document.body.appendChild(c);
    return c;
  }
  function placeCover() {
    var c = cover(), root = window.Live.root, r = root.getBoundingClientRect();
    c.style.cssText = "position:absolute;left:" + (r.left + scrollX) + "px;top:" + (r.top + scrollY) +
      "px;width:" + r.width + "px;min-height:" + r.height + "px;z-index:2147481000;background:inherit;" +
      "outline:2px dashed #39d0d8;outline-offset:-2px";
    c.className = root.className;
    return c;
  }
  var timeline = (Studio.instruments.timeline = {
    on: false, frames: [], cur: null, frozen: false,
    enable: function () {
      timeline.on = true;
      var box = document.getElementById("pc-timeline");
      if (box) box.hidden = false;
      timeline.request();
    },
    disable: function () {
      timeline.on = false;
      timeline.release();
      var box = document.getElementById("pc-timeline");
      if (box) box.hidden = true;
    },
    request: function () { if (window.__pulseSend) window.__pulseSend(["timeline"]); },
    index: function (frames) {
      timeline.frames = frames;
      var sc = document.getElementById("pc-scrub");
      if (!sc || !frames.length) return;
      sc.min = frames[0].t; sc.max = frames[frames.length - 1].t;
      if (!timeline.frozen) { sc.value = sc.max; timeline.describe(frames[frames.length - 1], true); }
      var ticks = document.getElementById("pc-tl-ticks");
      if (ticks) {
        var maxOps = Math.max.apply(null, frames.map(function (f) { return f.ops; }).concat([1]));
        ticks.innerHTML = "";
        frames.forEach(function (f) {
          var d = document.createElement("div");
          d.className = "tlt" + (f.kind === "mount" ? " mount" : "") + (timeline.cur === f.t ? " cur" : "");
          d.style.height = Math.max(3, Math.round(18 * f.ops / maxOps)) + "px";
          d.title = "t" + f.t + " · " + f.kind + " · " + f.ops + " op · " + (+f.ms).toFixed(1) + "ms" + (f.event !== "nil" ? " · " + f.event : "");
          d.onclick = function () { sc.value = f.t; timeline.seek(f.t); };
          ticks.appendChild(d);
        });
      }
      if (!sc.__wired) {
        sc.__wired = true;
        sc.addEventListener("input", function () { timeline.seek(+sc.value); });
      }
    },
    describe: function (f, live) {
      var info = document.getElementById("pc-tl-info");
      if (!info || !f) return;
      info.innerHTML = (live ? "<b>live</b> · " : "<b>t" + f.t + "</b> · ") + f.kind + " · " + f.ops +
        " op · " + (+f.ms).toFixed(1) + "ms" + (f.event && f.event !== "nil" ? " · " + f.event : "") +
        (live ? "" : "  <i style='color:#7d8590'>(drag to the end → live)</i>");
    },
    seek: function (t) {
      var last = timeline.frames.length ? timeline.frames[timeline.frames.length - 1].t : null;
      if (t === last) return timeline.release();
      timeline.frozen = true; timeline.cur = t;
      if (window.__pulseSend) window.__pulseSend(["time", t]);
    },
    // the frame at t arrived — show it in the cover, paint the ops that made it
    show: function (f) {
      if (!timeline.frozen || f.missing) return;
      var c = placeCover();
      c.innerHTML = f.html;
      var row = timeline.frames.find(function (x) { return x.t === f.t; });
      timeline.describe(row || { t: f.t, kind: f.kind, ops: (f.ops || []).length, ms: f.ms, event: f.event }, false);
      Array.prototype.forEach.call(document.querySelectorAll(".tlt"), function (d, i) {
        d.classList.toggle("cur", timeline.frames[i] && timeline.frames[i].t === f.t);
      });
      paint.clear();
      // differ paths are relative to the VIEW root (the single element under
      // #live-root — see client.js rootEl); mirror that for the cover.
      var viewRoot = c.children.length === 1 ? c.firstElementChild : c;
      (f.ops || []).forEach(function (op) { paint.flash(viewRoot, op, f.t, 60000); });
    },
    release: function () {
      if (!timeline.frozen) return;
      timeline.frozen = false; timeline.cur = null;
      var c = document.getElementById("studio-cover"); if (c) c.remove();
      paint.clear();
      var f = timeline.frames[timeline.frames.length - 1];
      var sc = document.getElementById("pc-scrub"); if (sc && f) sc.value = f.t;
      timeline.describe(f, true);
      Array.prototype.forEach.call(document.querySelectorAll(".tlt"), function (d) { d.classList.remove("cur"); });
    }
  });
  // ── Inspect + Drive: point at anything, ask, and act ──────────────
  //
  // Alt-click an element → its differ path (Live.pathOf, the inverse of the
  // walk the patcher does) → the server answers from the tap's latest TREE:
  // the hiccup node, its :on-* event terms (data, so they can be shown and
  // FIRED from here through the app's own socket), its owner, and every
  // retained frame whose ops touched it. A tracked cell with a writer can
  // be set from the cells list (✎) — and Paint shows what that changed.
  var inspect = (Studio.instruments.inspect = {
    on: false, picked: null,
    enable: function () {
      inspect.on = true;
      var box = document.getElementById("pc-inspect"); if (box) box.hidden = false;
      document.addEventListener("click", inspect.onClick, true);
    },
    disable: function () {
      inspect.on = false;
      document.removeEventListener("click", inspect.onClick, true);
      inspect.unpick();
      var box = document.getElementById("pc-inspect"); if (box) box.hidden = true;
    },
    unpick: function () {
      if (inspect.picked) inspect.picked.classList.remove("studio-pick");
      inspect.picked = null;
    },
    onClick: function (e) {
      if (!e.altKey) return;
      var root = window.Live.root;
      if (!root.contains(e.target)) return;
      e.preventDefault(); e.stopPropagation();
      inspect.pick(e.target);
    },
    pick: function (el) {
      var path = window.Live.pathOf(window.Live.root, el);
      if (!path) return;
      inspect.unpick();
      inspect.picked = el; el.classList.add("studio-pick");
      if (window.__pulseSend) window.__pulseSend(["inspect", path]);
    },
    show: function (m) {
      var head = document.getElementById("pc-in-head"), body = document.getElementById("pc-in-body");
      if (!head || !body) return;
      var own = inspect.picked ? ownerOf(inspect.picked) : { kind: "?", name: "?" };
      head.textContent = "<" + (m.tag || "#text") + "> [" + m.path.join(" ") + "] · " + own.kind + ":" + own.name;
      var rows = [];
      if (m.text) rows.push("<div class=row><span class=k>text</span>" + esc(m.text) + "</div>");
      if (m.attrs && m.attrs !== "{}") rows.push("<div class=row><span class=k>attrs</span>" + esc(m.attrs) + "</div>");
      Object.keys(m.events || {}).forEach(function (k) {
        rows.push("<div class=row><span class=k>" + k + "</span><span class=ev>" + esc(m.events[k]) +
          "</span><button data-fire='" + esc(m.events[k]) + "'>fire</button></div>");
      });
      if (m.touched && m.touched.length) {
        rows.push("<div class=row><span class=k>touched by</span>" + m.touched.map(function (h) {
          return "<button data-seek='" + h.t + "' title='" + esc(h.event) + " · " + h.ops.map(function (o) { return o[0]; }).join(",") + "'>t" + h.t + "</button>";
        }).join("") + "</div>");
      } else rows.push("<div class=row><span class=k>touched by</span>nothing yet</div>");
      body.innerHTML = rows.join("");
      body.querySelectorAll("[data-fire]").forEach(function (b) {
        b.onclick = function () { inspect.fire(b.getAttribute("data-fire")); };
      });
      body.querySelectorAll("[data-seek]").forEach(function (b) {
        b.onclick = function () {
          if (!timeline.on) Studio.toggle("timeline", true);
          var t = +b.getAttribute("data-seek"), sc = document.getElementById("pc-scrub");
          if (sc) sc.value = t;
          timeline.seek(t);
        };
      });
    },
    // fire an event term exactly as a click on the element would — through
    // the APP's socket, so auth/intents/commit all run for real
    fire: function (edn) {
      var term = ednTerm(edn);
      if (!term || !window.Live.ws) return;
      (window.Live.ws.__send || window.Live.ws.send.bind(window.Live.ws))(JSON.stringify(["event", term, {}]));
    }
  });
  // a tiny reader for the event-term subset the socket accepts:
  // [:intent :op {:k "v" :n 1}] · [:assign :key value] · [:navigate "/x"]
  function ednTerm(src) {
    var i = 0;
    function ws() { while (i < src.length && /[\s,]/.test(src[i])) i++; }
    function read() {
      ws();
      var c = src[i];
      if (c === "[") { i++; var v = []; for (;;) { ws(); if (src[i] === "]") { i++; return v; } v.push(read()); } }
      if (c === "{") { i++; var m = {}; for (;;) { ws(); if (src[i] === "}") { i++; return m; } var k = read(); var val = read(); m[typeof k === "string" ? k.replace(/^:/, "") : String(k)] = val; } }
      if (c === '"') { i++; var s = ""; while (src[i] !== '"') { if (src[i] === "\\") i++; s += src[i++]; } i++; return s; }
      var j = i; while (i < src.length && !/[\s,\[\]{}]/.test(src[i])) i++;
      var tok = src.slice(j, i);
      if (tok === "nil") return null; if (tok === "true") return true; if (tok === "false") return false;
      if (/^-?\d+(\.\d+)?$/.test(tok)) return +tok;
      return tok.replace(/^:/, "");
    }
    try { return read(); } catch (_e) { return null; }
  }
  function esc(s) { return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/'/g, "&#39;"); }
  Studio.ednTerm = ednTerm;

  // ── Cost: the server renders the sparklines (SVG hiccup); we only show/hide
  Studio.instruments.cost = {
    on: false,
    enable: function () { this.on = true; var b = document.getElementById("pc-cost"); if (b) b.hidden = false; },
    disable: function () { this.on = false; var b = document.getElementById("pc-cost"); if (b) b.hidden = true; }
  };

  Studio.instruments.graph = {
    on: false,
    enable: function () { this.on = true; var b = document.getElementById("pc-graph"); if (b) b.hidden = false; },
    disable: function () { this.on = false; var b = document.getElementById("pc-graph"); if (b) b.hidden = true; }
  };

  Studio.onMessage = function (m) {
    if (m.msg === "timeline") timeline.index(m.frames);
    else if (m.msg === "time") timeline.show(m);
    else if (m.msg === "inspect") inspect.show(m);
    else if (m.msg === "set" && m.error) alert("studio: " + m.error);
  };
  Studio.onSnapshot = function (m) {
    if (timeline.on && m.frame && (!timeline.frames.length || timeline.frames[timeline.frames.length - 1].t !== m.frame.t)) timeline.request();
  };

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
