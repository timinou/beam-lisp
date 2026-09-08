// live/client.js — the browser half: apply patch ops to the DOM.
//
// This is a direct port of the reference semantics in priv/live/diff.bl
// (`apply-ops`). The server computes the ops by diffing hiccup TREES; the
// client applies the SAME ops to the real DOM. Because the op set is small
// and keyed, this is ~120 lines with no virtual DOM and no heuristics.
//
// Wire protocol (JSON over a WebSocket):
//   server → client:  ["mount", html]            first paint (full HTML)
//                     ["patch", ops]              a list of patch ops
//                     ["denied", why]             an intent was refused
//   client → server:  ["event", term, data]      a fired event + its data
//
// Op set (mirrors diff.bl):
//   ["set-attr",    path, k, v]
//   ["remove-attr", path, k]
//   ["text",        path, s]
//   ["replace",     path, subtree]       subtree is hiccup-as-array
//   ["insert",      path, key, idx, subtree]
//   ["remove",      path, key]
//   ["move",        path, key, idx]
//
// `path` is a vector of child indices from the mount root. A keyed op names
// its child by the element's `key` attribute (the server strips `:key` from
// HTML but re-emits it as `data-key` on rendered elements — see render()).

(function () {
  "use strict";

  // ── durable offline outbox (opt-in via connect({outbox:true})) ────────
  //
  // The floor tablet drops wifi mid-gesture. A durable gesture (an element
  // marked data-live-durable) is minted a client idempotency id, injected into
  // the event data as "ev/id", PERSISTED to localStorage, then sent. It clears
  // only when the server sends ["ack", id]; on reconnect every un-acked frame
  // is replayed. The server dedups by the unique :ev/id, so replay is
  // exactly-once. Off by default — an app that never sets {outbox:true} keeps
  // the old volatile behaviour byte-for-byte.
  function makeOutbox(key) {
    function load() {
      try { return JSON.parse(window.localStorage.getItem(key) || "[]"); }
      catch (_e) { return []; }
    }
    function save(q) {
      try { window.localStorage.setItem(key, JSON.stringify(q)); } catch (_e) {}
    }
    return {
      add: function (id, frame) {
        var q = load(), i;
        for (i = 0; i < q.length; i++) if (q[i].id === id) return;
        q.push({ id: id, frame: frame });
        save(q);
      },
      ack: function (id) {
        var q = load(), out = [], i;
        for (i = 0; i < q.length; i++) if (q[i].id !== id) out.push(q[i]);
        save(out);
      },
      replay: function (sendFrame) {
        var q = load(), i;
        for (i = 0; i < q.length; i++) sendFrame(q[i].frame);
      },
      count: function () { return load().length; },
    };
  }

  // a monotonic-ish client id for a device: a stable per-tab prefix + counter,
  // so two tablets on the same PIN never collide and a crash-restart continues.
  var __seq = 0;
  function mintId(op) {
    var pfx;
    try {
      pfx = window.localStorage.getItem("live:client-id");
      if (!pfx) { pfx = "c" + Date.now().toString(36) + Math.random().toString(36).slice(2, 6);
                  window.localStorage.setItem("live:client-id", pfx); }
    } catch (_e) { pfx = "c" + Date.now().toString(36); }
    __seq++;
    return "ev-" + op + "-" + pfx + "-" + Date.now().toString(36) + "-" + __seq;
  }

  // ── resolve a path (array of child indices) to a DOM element ──────────
  //
  // The diff paths are relative to the VIEW's root element (the single
  // element the view returns, e.g. the `<ul>`), which the mount renders as
  // the first element child of the mount container. So a path of [] is that
  // element, [0] its first child, etc. `rootEl` normalises the container to
  // its mounted view element.
  function rootEl(container) {
    // if the container IS the view root already (has a tag other than the
    // mount wrapper), use it; otherwise descend to its first element child.
    const kids = elementChildren(container);
    return kids.length === 1 && container.id === "live-root" ? kids[0] : container;
  }

  function at(container, path) {
    let el = rootEl(container);
    // Walk ALL child nodes (text + element), NOT element-only: the server
    // differ (diff.bl `children-of`) indexes a node's children as the flat
    // text+element list, and `hiccup->html` joins siblings with "" so the
    // rendered DOM's childNodes mirror that list exactly. Walking
    // elementChildren here skips text siblings, so a path segment under a node
    // that interleaves text and elements (e.g. `[:button (icon) "Label"]`)
    // resolves to the WRONG node — or past the end — and the op is silently
    // dropped. That is the live-nav "URL changes but the page doesn't" bug.
    for (const i of path) el = domChildren(el)[i];
    return el;
  }

  // the child nodes a diff PATH indexes: text + element, in document order,
  // mirroring the server differ's `children-of` (which keeps strings and
  // elements, drops nils, splices seqs). Comment/other node types are
  // excluded (hiccup never emits them). This is the indexing the whole op
  // set is computed against; `elementChildren` below is only for the two
  // element-only concerns (root normalization + keyed lookup).
  function domChildren(el) {
    return Array.prototype.filter.call(el.childNodes, function (n) {
      return n.nodeType === 1 || n.nodeType === 3;
    });
  }

  // element children only (skip text nodes) — used for the #live-root → view
  // root normalization and for keyed lookups (a `:key` is always on an
  // element, and a keyed child list is all-element by construction).
  function elementChildren(el) {
    return Array.prototype.filter.call(el.childNodes, function (n) {
      return n.nodeType === 1;
    });
  }

  function childByKey(parent, key) {
    return elementChildren(parent).find(function (c) {
      return c.getAttribute("data-key") === String(key);
    });
  }

  // ── render a hiccup-as-array subtree to a DOM node ────────────────────
  // ["tag", {attrs}, ...children]  |  "text"  |  number
  //
  // SVG AWARENESS: an element inside an <svg> must be created with
  // createElementNS — a plain createElement builds an HTML-namespace element
  // the browser renders as an unknown inline tag ("blank" posters, text
  // spilled as loose strings). The context enters at <svg> and inherits to
  // every descendant; `svg` is false at the roots applyOp renders.
  const SVG_NS = "http://www.w3.org/2000/svg";
  const HTML_NS = "http://www.w3.org/1999/xhtml";
  const SVG_TAGS = {
    svg: 1, defs: 1, g: 1, rect: 1, circle: 1, ellipse: 1, line: 1,
    path: 1, polygon: 1, polyline: 1, text: 1, tspan: 1, stop: 1,
    linearGradient: 1, radialGradient: 1, pattern: 1, clipPath: 1, mask: 1,
    use: 1, symbol: 1, marker: 1, filter: 1, image: 1
  };
  function render(node, svg) {
    if (node === null || node === undefined) return document.createTextNode("");
    if (typeof node === "string" || typeof node === "number") {
      return document.createTextNode(String(node));
    }
    // element: [tag, attrs?, ...children]
    const tag = node[0];
    let attrs = {};
    let rest = node.slice(1);
    if (rest.length && isPlainObject(rest[0])) {
      attrs = rest[0];
      rest = rest.slice(1);
    }
    const bare = String(tag).replace(/[#.].*$/, "") || "div";
    const inSvg = svg || SVG_TAGS[bare] === 1;
    const el = document.createElementNS(inSvg ? SVG_NS : HTML_NS, bare);
    // shorthand id/classes on the tag (e.g. "li.task")
    applyShorthand(el, String(tag));
    for (const k in attrs) {
      setAttr(el, k, attrs[k]);
    }
    for (const child of rest) {
      // a nested array of children (a spliced seq) flattens
      if (Array.isArray(child) && typeof child[0] !== "string") {
        for (const c of child) el.appendChild(render(c, inSvg));
      } else {
        el.appendChild(render(child, inSvg));
      }
    }
    return el;
  }

  function applyShorthand(el, tag) {
    const hashI = tag.indexOf("#");
    const dotI = tag.indexOf(".");
    let cut = tag.length;
    if (hashI >= 0 && dotI >= 0) cut = Math.min(hashI, dotI);
    else if (hashI >= 0) cut = hashI;
    else if (dotI >= 0) cut = dotI;
    const rest = tag.slice(cut).replace(/#/g, ".#").split(".").filter(Boolean);
    for (const seg of rest) {
      if (seg[0] === "#") el.id = seg.slice(1);
      else el.classList.add(seg);
    }
  }

  function isPlainObject(x) {
    return x && typeof x === "object" && !Array.isArray(x);
  }

  // Set one attribute, translating the reserved keys the same way the server
  // renderer (live/hiccup render-attr) does — this is what keeps a rendered
  // subtree and a patched attribute in the SAME namespace:
  //   :key       -> data-key
  //   :on-EVENT  -> data-ev-EVENT, VALUE is the JSON event term (so the fire
  //                handler relays exactly what the view now declares; this is
  //                what makes a changed intent — e.g. a new room — take effect)
  // For `render` the value `v` is the raw hiccup value (an array term); for a
  // patch (`set-attr`) it arrives already JSON-encoded as a string. `evJson`
  // normalizes both to the JSON string the attribute must hold.
  function setAttr(el, k, v) {
    if (k === "key") {
      el.setAttribute("data-key", String(v));
      return;
    }
    if (k.indexOf("on-") === 0) {
      el.setAttribute("data-ev-" + k.slice(3), evJson(v));
      return;
    }
    if (v === true) el.setAttribute(k, "");
    else if (v === false || v === null || v === undefined) el.removeAttribute(k);
    else el.setAttribute(k, String(v));
  }

  // the JSON string an event attribute holds: a string is already encoded
  // (a patch value), anything else is a live term to stringify (a render value)
  function evJson(v) {
    return typeof v === "string" ? v : JSON.stringify(v);
  }

  // ── apply one op ──────────────────────────────────────────────────────
  // ── apply one patch (a list of ops) ───────────────────────────────────
  // The server's reference (diff.bl apply-ops) applies ALL structural ops
  // first — grouped by parent path, deepest parents first — and only then
  // the deep ops, whose paths index the REBUILT tree. Applying in raw wire
  // order patches pre-move nodes: a keyed list whose reconcile moves a child
  // would set attributes/text on whatever sat at that index BEFORE the move.
  // Grouping here is the exact mirror: within a parent, wire order already
  // is removes → placements (anchor-fill); across parents, deepest first.
  const STRUCTURAL = { remove: 1, "remove-at": 1, insert: 1, move: 1 };
  function applyPatch(root, ops) {
    const structural = [];
    const deep = [];
    for (const op of ops) (STRUCTURAL[op[0]] ? structural : deep).push(op);
    const byPath = new Map();
    for (const op of structural) {
      const k = JSON.stringify(op[1]);
      if (!byPath.has(k)) byPath.set(k, []);
      byPath.get(k).push(op);
    }
    const paths = Array.from(byPath.keys()).sort(
      (a, b) => JSON.parse(b).length - JSON.parse(a).length);
    for (const p of paths) for (const op of byPath.get(p)) applyOp(root, op);
    for (const op of deep) applyOp(root, op);
  }

  function applyOp(root, op) {
    const kind = op[0];
    const path = op[1];
    if (kind === "set-attr") {
      // route through setAttr so on-EVENT/key are translated to data-ev-*/
      // data-key exactly as render does — a raw setAttribute here would write
      // a dead `on-keydown.enter` attr the fire handler never reads.
      setAttr(at(root, path), op[2], op[3]);
    } else if (kind === "remove-attr") {
      var el = at(root, path);
      var k = op[2];
      if (k === "key") el.removeAttribute("data-key");
      else if (k.indexOf("on-") === 0) el.removeAttribute("data-ev-" + k.slice(3));
      else el.removeAttribute(k);
    } else if (kind === "text") {
      // a text op's path ends at a child slot that is a TEXT node. Walk the
      // parent's ALL child nodes (text + element) to the slot and set its
      // data, so a text change beside sibling elements does not clobber them.
      const parent = at(root, path.slice(0, -1));
      const slot = path[path.length - 1];
      const node = parent.childNodes[slot];
      if (node && node.nodeType === 3) {
        node.data = String(op[2]);
      } else if (node) {
        parent.replaceChild(document.createTextNode(String(op[2])), node);
      } else {
        parent.appendChild(document.createTextNode(String(op[2])));
      }
    } else if (kind === "replace") {
      const parent = at(root, path.slice(0, -1));
      const idx = path[path.length - 1];
      // children-of index (text+element), matching the server differ
      const el = domChildren(parent)[idx];
      parent.replaceChild(render(op[2]), el);
    } else if (kind === "remove") {
      const parent = at(root, path);
      const el = childByKey(parent, op[2]);
      if (el) parent.removeChild(el);
    } else if (kind === "remove-at") {
      // positional remove (unkeyed list): drop the child at a children-of
      // index (text+element), matching the server differ. The differ emits
      // these high-index-first, so sequential application keeps the remaining
      // indices valid.
      const parent = at(root, path);
      const el = domChildren(parent)[op[2]];
      if (el) parent.removeChild(el);
    } else if (kind === "insert") {
      const parent = at(root, path);
      const idx = op[3];
      const node = render(op[4]);
      // insert before the child now at the children-of index (text+element),
      // matching the server differ; null → append
      const ref = domChildren(parent)[idx] || null;
      parent.insertBefore(node, ref);
    } else if (kind === "move") {
      const parent = at(root, path);
      const el = childByKey(parent, op[2]);
      const idx = op[3];
      if (el) {
        // absolute-index placement, matching diff.bl's apply-ops: remove the
        // node, then insert it before the element now at `idx` among the
        // REMAINING children (null → append). This is the anchor-fill
        // reconciliation the differ assumes.
        parent.removeChild(el);
        const remaining = domChildren(parent);
        const ref = remaining[idx] || null;
        parent.insertBefore(el, ref);
      }
    }
  }

  // ── the socket ────────────────────────────────────────────────────────
  function connect(opts) {
    const root = opts.root || document.getElementById("live-root");

    // The outbox is opt-in: {outbox:true} turns on a durable localStorage queue
    // + auto-reconnect + replay. Without it, the socket keeps its old volatile
    // behaviour (buffer while CONNECTING, drop when CLOSED, no reconnect).
    var outbox = opts.outbox ? makeOutbox("live:outbox") : null;

    // `ws` is now MUTABLE — a reconnect swaps in a fresh socket while the event
    // delegation (bound to `root` once, below) keeps firing. `pending` buffers
    // sends made while the CURRENT socket is still CONNECTING.
    var ws = null;
    var pending = [];
    var reconnectMs = 500;

    // send a raw JSON frame string: straight through when OPEN, buffered while
    // CONNECTING, dropped when there is no socket (the outbox holds the durable
    // ones and replays them on reconnect). relay() calls ws.__send; that is a
    // thin shim over this so existing call sites are unchanged.
    function sendFrame(payload) {
      if (ws && ws.readyState === WebSocket.OPEN) ws.send(payload);
      else if (ws && ws.readyState === WebSocket.CONNECTING) pending.push(payload);
      // no socket / CLOSED: drop — a durable frame is in the outbox already
    }

    function dispatchLive(up) {
      try {
        document.documentElement.setAttribute("data-live", up ? "1" : "0");
        document.dispatchEvent(new CustomEvent("live:state", { detail: { up: up } }));
      } catch (_e) { /* non-DOM host (tests) — ignore */ }
      if (opts.onLive) opts.onLive(up);
    }
    function setLive(up) {
      dispatchLive(up);
      // publish the pending-count so a view/pill can show « N en attente ».
      if (outbox) {
        try {
          document.documentElement.setAttribute("data-live-pending", String(outbox.count()));
          document.dispatchEvent(new CustomEvent("live:pending",
            { detail: { count: outbox.count() } }));
        } catch (_e) {}
      }
    }

    function announce(name, detail) {
      try { document.dispatchEvent(new CustomEvent(name, { detail: detail })); }
      catch (_e) { /* non-DOM host */ }
    }

    // open (or re-open) the socket and wire its handlers.
    function openSocket() {
      ws = new WebSocket(opts.url);
      ws.__send = sendFrame;   // relay() and __navigate use this

      ws.onopen = function () {
        reconnectMs = 500;                         // reset backoff
        for (var i = 0; i < pending.length; i++) ws.send(pending[i]);
        pending = [];
        if (outbox) outbox.replay(sendFrame);      // resend every un-acked frame
        setLive(true);
      };
      ws.onclose = function () {
        setLive(false);
        if (outbox) {                              // auto-reconnect with backoff
          setTimeout(openSocket, reconnectMs);
          reconnectMs = Math.min(reconnectMs * 2, 10000);
        }
      };
      ws.onerror = function () { setLive(false); };
      ws.onmessage = function (msg) {
        const [kind, a, b] = JSON.parse(msg.data);
        if (kind === "mount") {
          root.innerHTML = a;
          announce("live:mount", { root: root });
        } else if (kind === "patch") {
          applyPatch(root, a);
          announce("live:patch", { root: root, ops: a });
        } else if (kind === "tap") {
          announce("live:tap", { t: a, basis: b });
        } else if (kind === "denied") {
          if (opts.onDenied) opts.onDenied(a);
        } else if (kind === "ack") {
          if (outbox) { outbox.ack(a); setLive(true); }   // the gesture landed — drop it
        }
      };
      Live.ws = ws;
    }
    openSocket();
    Live.root = root;

    // relay() delegates to this to mark+persist a durable gesture before send.
    // A node marked data-live-durable mints an idempotency id, injects it into
    // the event data as "ev/id", and stores the full frame so a reconnect can
    // replay it. Returns the (possibly augmented) data object.
    Live.__durable = function (el, term, data) {
      if (!outbox || !el || !el.closest || !el.closest("[data-live-durable]")) return data;
      var op = (Array.isArray(term) && term[0] === "intent") ? String(term[1]) : "ev";
      var d = Object.assign({}, data || {});
      d["ev/id"] = mintId(op);
      outbox.add(d["ev/id"], JSON.stringify(["event", term, d]));
      setLive(!!(ws && ws.readyState === WebSocket.OPEN));
      return d;
    };

    // event delegation. A [data-ev-EVENT] node carries its intent as a JSON
    // attribute; on fire we relay that term plus the value of the nearest
    // input (so a Send button and an Enter key both carry the field text).
    root.addEventListener("click", function (e) {
      // A plain in-app <a href="/…"> becomes LIVE navigation automatically:
      // intercept the click, push the URL, and fire a navigate event so the
      // dispatcher re-projects with a keyed patch (no reload). Falls back to a
      // real page load when JS is off, when it's a modified click (new tab),
      // or when the link is external/hash — so links stay honest and
      // bookmarkable. This is what makes EVERY screen-to-screen move live
      // without wiring a single link by hand.
      var a = e.target.closest && e.target.closest("a[href]");
      if (a && !e.defaultPrevented && !e.metaKey && !e.ctrlKey &&
          !e.shiftKey && !e.altKey && (a.getAttribute("target") || "") === "") {
        var href = a.getAttribute("href") || "";
        if (href.indexOf("/") === 0 && href.indexOf("//") !== 0 &&
            href.indexOf("#") !== 0) {
          e.preventDefault();
          if (ws.__navigate) ws.__navigate(href);
          return;
        }
      }
      fireFrom(e.target, "click", ws, formData(e.target));
    });
    root.addEventListener("input", function (e) {
      fireFrom(e.target, "input", ws, { value: e.target.value });
    });
    // a <select> / checkbox / radio commits on `change`, not `input`: a
    // form-for select carries `on-change` and must reach the server too
    root.addEventListener("change", function (e) {
      var t = e.target;
      var data = (t.type === "checkbox" || t.type === "radio")
        ? { value: t.value, checked: t.checked }
        : { value: t.value };
      fireFrom(t, "change", ws, data);
    });
    // Enter in an input fires its `on-keydown.enter` intent (if any), and
    // clears the field — the chat-composer gesture. The `.enter` modifier is
    // part of the attribute name (data-ev-keydown.enter), so match by prefix.
    root.addEventListener("keydown", function (e) {
      if (e.key !== "Enter" || e.shiftKey) return;
      var el = closestAttrPrefix(e.target, "data-ev-keydown");
      if (!el) return;
      e.preventDefault();
      var attr = el.__evAttr;
      // honour a `.enter` modifier if present; a bare keydown fires on any key
      if (attr.indexOf(".enter") >= 0 || attr === "data-ev-keydown") {
        relay(el, attr, ws, { value: e.target.value });
        if (el.tagName === "INPUT") el.value = "";
      }
    });

    // Back/Forward: the browser restored a previous URL, so tell the server to
    // re-route to it (a plain navigate event → the dispatcher re-projects).
    // No pushState here — the history entry already moved; we only sync state.
    window.addEventListener("popstate", function () {
      var path = location.pathname + location.search;
      (ws.__send || ws.send.bind(ws))(
        JSON.stringify(["event", ["navigate", path], {}]));
    });

    // programmatic navigation: push the URL and tell the server. Lets app code
    // (or a film driver) move routes without a synthetic click.
    ws.__navigate = function (path) {
      try { history.pushState({ live: path }, "", path); } catch (_e) {}
      (ws.__send || ws.send.bind(ws))(
        JSON.stringify(["event", ["navigate", path], {}]));
    };

    return ws;
  }

  // the value of the input nearest `el` (itself, or one in its container),
  // so a button click carries the message the user typed
  function formData(el) {
    if (el.tagName === "INPUT") return { value: el.value };
    var box = el.closest("div,footer,form,section") || el.parentElement;
    var input = box && box.querySelector("input");
    var data = input ? { value: input.value } : {};
    if (input) input.__clear = true;
    return data;
  }

  // walk up from `node` to the first element carrying an attribute whose name
  // starts with `prefix` (so `data-ev-keydown` matches `data-ev-keydown.enter`).
  // Stashes the matched attribute name on the element as `__evAttr`.
  function closestAttrPrefix(node, prefix) {
    var el = node;
    while (el && el.nodeType === 1) {
      if (el.attributes) {
        for (var i = 0; i < el.attributes.length; i++) {
          var name = el.attributes[i].name;
          if (name.indexOf(prefix) === 0) { el.__evAttr = name; return el; }
        }
      }
      el = el.parentElement;
    }
    return null;
  }

  // A `:navigate` event term carries the app-route to move to. live.app turns
  // it into a keyed PATCH (no reload), but the URL bar must follow so links
  // stay real and shareable, and Back/Forward work. `navTarget` finds the
  // navigate path in a term — a single ["navigate", "/x"] or the second slot
  // of a [["assign",…],["navigate","/x"]] batch — or null when there is none.
  function navTarget(term) {
    if (!Array.isArray(term) || term.length === 0) return null;
    if (term[0] === "navigate") return term[1];
    // a vector of terms: scan for a navigate among them
    if (Array.isArray(term[0])) {
      for (var i = 0; i < term.length; i++) {
        if (Array.isArray(term[i]) && term[i][0] === "navigate") return term[i][1];
      }
    }
    return null;
  }

  // relay the JSON term stored in attribute `attr` of `el` to the server
  function relay(el, attr, ws, data) {
    var raw = el.getAttribute(attr);
    var term = null;
    try { term = raw ? JSON.parse(raw) : null; } catch (e) { term = null; }
    // a navigate term also moves the URL bar (pushState), so the address
    // reflects the live route — a bookmarkable SPA over one socket. The
    // server still gets the SAME event and re-routes; this only syncs the URL.
    var nav = navTarget(term);
    if (nav) { try { history.pushState({ live: nav }, "", nav); } catch (_e) {} }
    // A durable gesture (inside a [data-live-durable] node) is minted an
    // idempotency id, persisted to the outbox, and augmented into `data` as
    // "ev/id" BEFORE the send — so a drop-then-reconnect replays it exactly
    // once. A non-durable gesture (or an app without {outbox:true}) is a no-op
    // pass-through, unchanged.
    var d = (Live.__durable ? Live.__durable(el, term, data || {}) : (data || {}));
    // __send guards readyState (buffer while CONNECTING, drop when CLOSED) so a
    // fire before the handshake or after a drop never throws.
    (ws.__send || ws.send.bind(ws))(JSON.stringify(["event", term, d]));
    return true;
  }

  function fireFrom(target, evName, ws, data) {
    var el = closestAttrPrefix(target, "data-ev-" + evName);
    if (!el) return false;
    // the event TERM travels as a JSON attribute (data-ev-EVENT='<json>').
    // Send it back verbatim so the server performs exactly what the view
    // declared — the client never invents an intent, it only relays one.
    relay(el, el.__evAttr, ws, data);
    // clear a composer input after a click-send
    if (evName === "click") {
      var box = target.closest("div,footer,form,section");
      var input = box && box.querySelector("input");
      if (input && input.__clear) { input.value = ""; input.__clear = false; }
    }
    return true;
  }

  // the path of `el` under `root`, in the differ's coordinates (indices into
  // the text+element child list) — the inverse of `at`. Lets a tool point at
  // an element and ask the server about it.
  function pathOf(root, el) {
    var path = [];
    var top = rootEl(root);
    while (el && el !== top) {
      var parent = el.parentNode;
      if (!parent) return null;
      path.unshift(domChildren(parent).indexOf(el));
      el = parent;
    }
    return el === top ? path : null;
  }

  window.Live = { connect: connect, applyOp: applyOp, render: render,
                  at: at, pathOf: pathOf, ws: null, root: null };
  var Live = window.Live;
})();
