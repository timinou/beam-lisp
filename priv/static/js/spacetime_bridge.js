// priv/static/js/spacetime_bridge.js — the seam's client half.
//
// Ported from verse's elixir/spacetime_lv/assets/js/app.js, which proved this
// transport in a browser. Two changes, both because this app has no bundler:
//
//   1. no imports — `Phoenix` and `phoenix_live_view` are loaded as plain
//      scripts by the root layout, so `Socket`/`LiveSocket` are read off the
//      globals they attach;
//   2. nothing else from that file (topbar, colocated hooks, presence) comes
//      along: this is the bridge, not an app shell.
//
// What the hook does, in both directions:
//
//   server → page   `st-set` diffs are routed by (module, assign) into the
//                   setters the compiled `@data subscribe` registered. The
//                   bridge never writes arbitrary keys into page state; it
//                   selects a setter the page itself declared.
//   page → server   `window.__stLiveBridge.pushEvent(...)` is what the compiled
//                   `@data signal … send emit` calls. Without it, every signal
//                   rejects with "live bridge unavailable — the host LiveView
//                   must mount the SpacetimeBridge hook", which is exactly the
//                   state this file ends.
//   pushes          `push_event` effects are dispatched to the stream consumers
//                   the page registered for its `@data stream`.

(function () {
  // The prebuilt client bundles in deps/ are IIFEs that bind ONE global each:
  // `phoenix.js` → `window.Phoenix` (with `.Socket`), and
  // `phoenix_live_view.js` → `window.LiveView` (with `.LiveSocket`).
  // Verified by reading the shipped files rather than assumed: an earlier
  // version of this file looked for `window.LiveSocket`, found nothing, and
  // returned early — which presents in the browser as a page that hydrates and
  // then answers no signal, the exact symptom this whole change removes.
  const Socket = window.Phoenix && window.Phoenix.Socket;
  const LiveSocket = window.LiveView && window.LiveView.LiveSocket;

  if (!Socket || !LiveSocket) {
    console.error(
      "[ST] client JS not loaded before the bridge — " +
        "Phoenix.Socket: " + typeof Socket + ", LiveView.LiveSocket: " + typeof LiveSocket
    );
    return;
  }

  const SpacetimeBridge = {
    mounted() {
      const module = this.el.dataset.module;
      const subscriptions = () => window.__stLiveSubscriptions;

      const settersFor = (hostModule, assign) => {
        const registry = subscriptions();
        if (!registry || !hostModule) return [];
        const moduleEntries =
          registry instanceof Map ? registry.get(hostModule) : registry[hostModule];
        const entry =
          moduleEntries instanceof Map ? moduleEntries.get(assign) : moduleEntries?.[assign];
        return Array.isArray(entry) ? entry : entry ? [entry] : [];
      };

      const apply = (payload) => {
        const hostModule = payload?.module;
        const assigns = payload?.assigns;
        if (!hostModule || !assigns || typeof assigns !== "object") return true;
        // A push belongs to the hook's own LiveView. Reject a mismatched module
        // rather than letting another page's host consume this diff.
        if (module && hostModule !== module) return true;

        const registry = subscriptions();
        if (!registry) return false;
        const moduleEntries =
          registry instanceof Map ? registry.get(hostModule) : registry[hostModule];
        // The primitive prelude creates the registry before its per-module
        // setter; retain this early seed until that declaration registered.
        if (!moduleEntries) return false;

        let ready = true;
        for (const [assign, value] of Object.entries(assigns)) {
          for (const set of settersFor(hostModule, assign)) {
            if (typeof set !== "function") continue;
            try {
              set(value);
            } catch (_error) {
              // The bundle may still be booting; retain the whole diff.
              ready = false;
            }
          }
        }
        return ready;
      };

      // Diffs can beat the bundle's subscription registration — the connected
      // mount's seed usually does. Keep them until the registry exists.
      this._pending = [];
      const flush = () => {
        if (!this._pending.length) return;
        this._pending = this._pending.filter((payload) => !apply(payload));
      };
      const scheduleFlush = () => {
        if (this._stSetTimer) return;
        let tries = 0;
        this._stSetTimer = setInterval(() => {
          flush();
          if (!this._pending.length || ++tries > 50) {
            clearInterval(this._stSetTimer);
            this._stSetTimer = null;
          }
        }, 50);
      };
      this._stSetRef = this.handleEvent("st-set", (payload) => {
        if (!apply(payload)) {
          this._pending.push(payload);
          scheduleFlush();
        }
      });

      // Transient pushes: attach handlers only for declared stream names, and
      // never queue payloads — a token that arrives before a consumer exists is
      // dropped, because replaying it later would re-narrate a finished answer.
      this._stStreamRefs = new Map();
      const streamConsumers = (hostModule, event) => {
        const registry = window.__stLiveStreams;
        const entries =
          registry instanceof Map ? registry.get(hostModule) : registry?.[hostModule];
        const listeners = entries instanceof Map ? entries.get(event) : entries?.[event];
        return Array.isArray(listeners) ? listeners : listeners ? [listeners] : [];
      };
      const dispatchStream = (event, payload) => {
        const listeners = streamConsumers(module, event);
        if (!listeners.length) {
          console.debug(`[ST] dropped transient push ${module || "unknown"}:${event}; no consumer`);
          return;
        }
        for (const listener of listeners) {
          if (typeof listener !== "function") continue;
          try {
            listener(payload, event);
          } catch (error) {
            console.debug(`[ST] transient push ${module}:${event} consumer failed`, error);
          }
        }
      };
      const attachStreamHandlers = () => {
        const registry = window.__stLiveStreams;
        const entries = registry instanceof Map ? registry.get(module) : registry?.[module];
        if (!entries) return false;
        const events =
          entries instanceof Map ? Array.from(entries.keys()) : Object.keys(entries);
        for (const event of events) {
          if (this._stStreamRefs.has(event)) continue;
          this._stStreamRefs.set(
            event,
            this.handleEvent(event, (payload) => dispatchStream(event, payload))
          );
        }
        return events.length > 0;
      };
      // The compiled page may register after this hook mounts. Polling only
      // ATTACHES handlers; it retains no payload and therefore cannot replay.
      let streamTries = 0;
      this._stStreamTimer = setInterval(() => {
        const ready = attachStreamHandlers();
        if (ready || ++streamTries > 50) {
          clearInterval(this._stStreamTimer);
          this._stStreamTimer = null;
        }
      }, 50);
      attachStreamHandlers();

      // ── page → server ────────────────────────────────────────────────────
      const bridges = window.__stLiveBridges || (window.__stLiveBridges = new Map());
      if (module) bridges.set(module, this);

      // Ephemeral updates are intentionally lossy: presence-like state only
      // needs the latest value, so at most one outbound push per frame.
      this._stEphemeral = null;
      this._stEphemeralFrame = null;
      this._stEphemeralDestroyed = false;
      this.pushEphemeral = (event, payload) => {
        if (this._stEphemeralDestroyed || !event) return;
        this._stEphemeral = { event, payload: payload || {} };
        if (this._stEphemeralFrame !== null) return;
        this._stEphemeralFrame = requestAnimationFrame(() => {
          this._stEphemeralFrame = null;
          if (this._stEphemeralDestroyed || !this._stEphemeral) return;
          const { event: queuedEvent, payload: queuedPayload } = this._stEphemeral;
          this._stEphemeral = null;
          this.pushEvent(queuedEvent, queuedPayload);
        });
      };

      window.__stLiveBridge = {
        pushEvent: (event, payload, onReply, selection) => {
          const selectedModule = typeof selection === "string" ? selection : selection?.module;
          const target = selectedModule ? bridges.get(selectedModule) : bridges.get(module) || this;
          if (!target) return;
          target.pushEvent(event, payload === undefined || payload === null ? {} : payload,
            (reply, _ref) => onReply(reply));
        },
        pushEphemeral: (event, payload, selection) => {
          const selectedModule = typeof selection === "string" ? selection : selection?.module;
          const target = selectedModule ? bridges.get(selectedModule) : bridges.get(module) || this;
          target?.pushEphemeral(event, payload);
        },
      };
    },

    destroyed() {
      this._stEphemeralDestroyed = true;
      if (this._stEphemeralFrame !== null) cancelAnimationFrame(this._stEphemeralFrame);
      this._stEphemeralFrame = null;
      this._stEphemeral = null;
      if (this._stSetTimer) clearInterval(this._stSetTimer);
      if (this._stSetRef) this.removeHandleEvent(this._stSetRef);
      if (this._stStreamTimer) clearInterval(this._stStreamTimer);
      if (this._stStreamRefs) {
        for (const ref of this._stStreamRefs.values()) this.removeHandleEvent(ref);
        this._stStreamRefs.clear();
      }

      const module = this.el.dataset.module;
      const bridges = window.__stLiveBridges;
      if (module && bridges?.get(module) === this) bridges.delete(module);
      if (!bridges?.size) {
        delete window.__stLiveBridges;
        delete window.__stLiveBridge;
      }
    },
  };

  const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content");
  const liveSocket = new LiveSocket("/live", Socket, {
    longPollFallbackMs: 2500,
    params: { _csrf_token: csrfToken },
    hooks: { SpacetimeBridge },
  });
  liveSocket.connect();
  window.liveSocket = liveSocket;
})();
