# Microsoft Graph (SharePoint / OneDrive) connector

Status 2026-10-04 (PLAN-051). Same shape as the Drive connector; one keep per drive.

## Surface (`connector.microsoft.graph`)

Credential: an Entra app, OAuth2 client credentials, scope
`https://graph.microsoft.com/.default`. `credential/mint-app!` mints; a renewal
is minting again (`refresh!` on a grant with `:grant-type :client-credentials`).
The client secret lives in the connection's `:client`, never in the stored grant.
`connector/renew!` forces a renewal on a server-side 401 (used by `get!`).

| fn | role |
|---|---|
| `spec`, `endpoints cfg` | base URLs are data (`:graph-base`, `:login-base`) |
| `connect! c cfg [post!]` | mint + store the app grant |
| `item-map drive item` | driveItem → `{:key :id :name :mime :folder? :modified :size :md5 :parents :trashed :removed :rev}` (`:rev` = cTag, else eTag) |
| `feed drive base` | `:start-token :changes :enumerate :children :item :parent-key` over `/drives/{d}/root/delta`; cursor = the full deltaLink URL |
| `site-by-path`, `sites`, `drives`, `browse`, `probe-delta` | browse from CONFIGURED sites (`/sites?search=*` is not allowed under Sites.Selected) |
| `content-request`, `content! c base item max` | `/content` 302 read without redirects, blob fetched with no bearer |
| `get-via c` | the keep's `get`; 429 comes back with `:retry-after` (never slept on here) |

Identity: `[:graph drive-id item-id]` (see entities-and-projections.md §2).
410 → M5 (mirror-and-reconcile.md §2): the 410's `Location` (a fresh full delta
enumeration) is carried as `:location` and is where the re-seed starts.

**Enumeration.** Docs: children paging is not guaranteed complete under
concurrent writes; delta is. The feed's `:enumerate` walks a tokenless
`root/delta` to its `deltaLink`; the keep seeds from it (filtered to the root
closure) and commits that deltaLink as the cursor, so there is no
`delta?token=latest` + children-listing window. `content!` shares the
renew-on-401 path with `get!` (`connector/authed!`). The fake's request log
redacts `authorization`/`cookie`/`x-api-key` values (presence stays visible).

## Permissions surface (rights-as-relations.md)

`(g/feed drive base {:tenant t :client-id app :site-id s})` adds two feed fns:
`:acl` = `GET /drives/{d}/items/{i}/permissions` (paged) mapped by
`permission-grants` — user → person (Entra id), group → Entra group,
siteGroup/sharePointGroup → a site-group identity marked unexpandable,
application → application, link `organization`/`anonymous` → audience, link
`users` → its persons, `existingAccess` → nothing; and `:members` =
`GET /groups/{id}/transitiveMembers` (persons only; site groups → `:complete? false`).
`:complete?` is INFERRED: true only when the list holds a grant that is not our
own application (the owner view). With a site role of `read` the app sees only
its own permission, so every item is `:acl-incomplete`; seeing other people's
access needs the site grant `fullcontrol` (setup step 4). Unverified on a real
tenant (rights doc §7 Q1).

## The fake (`connector.microsoft.fake-graph`)

A `veritas.model` served with `vm/serve`: HTTP endpoints are commands with
`:request`/`:response`; world changes and faults are non-HTTP commands
(`:add-file :add-folder :edit :rename :move :delete :expire-cursors :throttle
:rotate-secret :grant-site :revoke-site :expire-token`), driven by `:inject!`
(`fg/do!`) or by `vm/check` histories. `fg/start!` seeds the docs/22 §1.2 tree.

serve gained three generic capabilities for it: form bodies decode to a
string-keyed map, `:response` may return `{:raw bytes :content-type s}`, and a
final `*name` path segment captures the rest of the path.

| behaviour | fake |
|---|---|
| token | client_credentials, TTL 3600 s, bad secret 401 `invalid_client` AADSTS7000215 |
| auth | every Graph call needs a fake-issued Bearer of a consented app else 401; ungranted site → 403 |
| ids / cTag | stable across rename/move; cTag = content hash, absent on folders |
| delta | root only, 2 items/page, FULL-URL nextLink/deltaLink, `deleted` facet, folder moved in = folder only |
| stale cursor | `:expire-cursors` → 410 + Location + `resyncChangesApplyDifferences` |
| download | `/content` 302 → `/_fake/blob/<token>` (60 s, no auth) |
| throttle | `:throttle n` → next n authorised calls 429 `Retry-After: 1` |

Fake permissions: per-item effective lists with inheritance computed in the
fake (unique permissions on first share/break-inheritance), Entra groups with
nested members, site groups, the owner-view rule keyed on the site role
(`:grant-site [site-id role]`, default `:read`), commands `:share`, `:unshare`,
`:break-inheritance`, `:add-member`, `:remove-member`; permission changes do
not enter the delta log.

## Verified vs assumed

Verified (docs, 2026-10-04): the AADSTS codes mapped in `oauth/ENTRA-REASONS`
(Entra error-code reference); client-credentials form. Verified only against the
FAKE: everything in the table above — it proves the connector against our
reading of Graph, not against Microsoft.

Assumed / open (settled only by the real tenant, docs/22 §2.6):
1. **Delta under `Sites.Selected`**: whether `root/delta` is allowed for a
   site-granted app. `probe-delta` names the outcome (403 → surfaced at connect).
2. **Item permissions under `Sites.Selected`**: whether per-item permission
   reads (the upper-bound panel) are allowed.
Also assumed: a folder moved into scope reports no descendants (the keep seeds
its subtree either way); deleting a folder may report only the folder (the fake
reports the folder and its descendants; the keep is correct for both because
resync/M5 and the removal rule cover the difference).
