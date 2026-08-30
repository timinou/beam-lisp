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
    for (const i of path) el = elementChildren(el)[i];
    return el;
  }

  // element children only (skip text nodes, so indices match the tree)
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
  function render(node) {
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
    const el = document.createElement(String(tag).replace(/[#.].*$/, "") || "div");
    // shorthand id/classes on the tag (e.g. "li.task")
    applyShorthand(el, String(tag));
    for (const k in attrs) {
      setAttr(el, k, attrs[k]);
    }
    for (const child of rest) {
      // a nested array of children (a spliced seq) flattens
      if (Array.isArray(child) && typeof child[0] !== "string") {
        for (const c of child) el.appendChild(render(c));
      } else {
        el.appendChild(render(child));
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
      const el = elementChildren(parent)[idx];
      parent.replaceChild(render(op[2]), el);
    } else if (kind === "remove") {
      const parent = at(root, path);
      const el = childByKey(parent, op[2]);
      if (el) parent.removeChild(el);
    } else if (kind === "insert") {
      const parent = at(root, path);
      const idx = op[3];
      const node = render(op[4]);
      const ref = elementChildren(parent)[idx] || null;
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
        const remaining = elementChildren(parent);
        const ref = remaining[idx] || null;
        parent.insertBefore(el, ref);
      }
    }
  }

  // ── the socket ────────────────────────────────────────────────────────
  function connect(opts) {
    const root = opts.root || document.getElementById("live-root");
    const ws = new WebSocket(opts.url);

    ws.onmessage = function (msg) {
      const [kind, a, b] = JSON.parse(msg.data);
      if (kind === "mount") {
        root.innerHTML = a;
      } else if (kind === "patch") {
        for (const op of a) applyOp(root, op);
      } else if (kind === "denied") {
        if (opts.onDenied) opts.onDenied(a);
      }
    };

    // event delegation. A [data-ev-EVENT] node carries its intent as a JSON
    // attribute; on fire we relay that term plus the value of the nearest
    // input (so a Send button and an Enter key both carry the field text).
    root.addEventListener("click", function (e) {
      fireFrom(e.target, "click", ws, formData(e.target));
    });
    root.addEventListener("input", function (e) {
      fireFrom(e.target, "input", ws, { value: e.target.value });
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

  // relay the JSON term stored in attribute `attr` of `el` to the server
  function relay(el, attr, ws, data) {
    var raw = el.getAttribute(attr);
    var term = null;
    try { term = raw ? JSON.parse(raw) : null; } catch (e) { term = null; }
    ws.send(JSON.stringify(["event", term, data || {}]));
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

  window.Live = { connect: connect, applyOp: applyOp, render: render };
})();
