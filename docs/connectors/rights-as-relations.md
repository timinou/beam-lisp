# Rights as relations: one source of truth for who may read what

Status: design of record, 2026-10-04. **§2, §3 (`:~ident/member-of`, `:~acl/source-reads`), §5 (the check) and §6 (feeds + keep) are BUILT** in `connector.acl`, `connector.keep`, `connector.microsoft.graph`, `connector.google.gdrive` and both fakes; `:~acl/may-read`, identity linking (§4) and the policy modes are NOT (product side). Build notes are in §9. Builds on
[entities-and-projections.md](entities-and-projections.md) (identity
`[provider namespace id]`, `:conn/seen-via` proposed),
[mirror-and-reconcile.md](mirror-and-reconcile.md) (the keep, M1–M5), and the
`auth` package (Biscuit capabilities, `auth.rls`). Consumer: knowledger
docs/21 §5–§6 (upper-bound check, teams, walls).

## 0. The question, and why it is upstream

A product that mirrors a document system (Drive, SharePoint) ends up with TWO
answers to "may Amina read this file?":

1. the **source's** answer — Microsoft/Google ACLs, inherited down folders,
   granted to users, groups, links;
2. the **product's** answer — its own grants (knowledger: `:grant/*`, minted
   into a Biscuit, evaluated by `auth/authorize-op`).

Two answers is the bug: they drift, and every read path has to pick one. The
fix is not to pick one, it is to make both **facts in one store, one rule
set, one relation** — and to make every read go through that relation.

Nothing here is knowledger-specific: identity mapping, ACL mirroring, group
expansion and the effective-access relation are the same for every connector
and every product. So they live here, next to `connector.keep` and
`files.bl`, and products only add their own grants as more facts.

## 1. What the sources actually expose (verified 2026-10-04)

### Microsoft Graph (SharePoint / OneDrive)

| Fact | Source | Consequence |
|---|---|---|
| `Sites.Selected` now has finer siblings: `Lists.SelectedOperations.Selected`, `ListItems.SelectedOperations.Selected`, `Files.SelectedOperations.Selected`; all need an explicit per-resource assignment (`POST …/permissions` with role `read`/`write`/`owner`/`fullcontrol`). Assigning below site level **breaks inheritance** on that resource. | [permissions-selected-overview](https://learn.microsoft.com/en-us/graph/permissions-selected-overview) | Granting a FOLDER to the app is possible but MUTATES the customer's SharePoint (unique permissions). Site-level grants do not. ∴ recommend site-level `Sites.Selected`. |
| `GET /drives/{d}/items/{i}/permissions` returns effective permissions (direct + inherited). **Owner callers see all; a non-owner caller sees only the permissions that apply to the caller.** Least privileged *application* permission: `Files.Read.All`. | [driveitem-list-permissions](https://learn.microsoft.com/en-us/graph/api/driveitem-list-permissions) | With a `read` site grant the app is a non-owner → it sees only its OWN permission. Reading other people's access needs the app to hold **`fullcontrol`** (or `owner`) on the site — i.e. step 4 grants `fullcontrol` instead of `read`. *Inference from the documented owner/non-owner rule; to be confirmed on a real tenant (§7 Q1).* |
| SharePoint document libraries **do not return `inheritedFrom`**. | [permission resource](https://learn.microsoft.com/en-us/graph/api/resources/permission) | We cannot tell inherited from direct per item; we store EFFECTIVE grants per item and treat them as such. |
| A grant names a `sharePointIdentitySet`: `user` (Entra object id), `group` (Entra group id), `siteUser`, `siteGroup` (id unique only within the site), `sharePointGroup` (global id), `application`; or a `link` (scope `anonymous`/`organization`/`users`/`existingAccess`). | [sharepointidentityset](https://learn.microsoft.com/en-us/graph/api/resources/sharepointidentityset) | Grantees are heterogeneous; identity must be namespaced. |
| Entra group expansion: `GET /groups/{id}/transitiveMembers`, least privileged application permission **`GroupMember.ReadBasic.All`** (hidden memberships need `Member.Read.Hidden`). | [group-list-transitivemembers](https://learn.microsoft.com/en-us/graph/api/group-list-transitivemembers) | Entra groups CAN be expanded via Graph with a narrow scope. |
| **SharePoint site groups** (Owners/Members/Visitors): Graph `sharePointGroup/members` exists only for **SharePoint Embedded containers** (`FileStorageContainer.Selected`). For classic sites, membership is only on the SharePoint REST API, which for app-only requires **certificate** auth and in practice `Sites.FullControl.All` (vendor docs: Glean; Microsoft Q&A). | [sharepointgroup-list-members](https://learn.microsoft.com/en-us/graph/api/sharepointgroup-list-members), [Glean connector permissions](https://docs.glean.com/connectors/native/sharepoint/security/permissions) | We cannot expand classic SharePoint groups with client-secret Graph. They become **unresolved principals** → verdict `:unknown`, never silently "no one". |
| Delta does not report permission-only changes unless `Prefer: deltashowsharingchanges` / `hierarchicalsharing`, and real-time permission events need `Sites.FullControl.All`. | [scan-guidance](https://learn.microsoft.com/en-us/onedrive/developer/rest-api/concepts/scan-guidance), Glean | Permission freshness is **bounded staleness**: refresh on content change + periodic sweep; record `:acl/as-of` and expose it. |

### Google Drive

| Fact | Source | Consequence |
|---|---|---|
| Every file/folder has `permissions` of `type` user/group/domain/anyone and `role` owner/organizer/fileOrganizer/writer/commenter/reader. Inherited by default; **cannot be reduced on children** (only expanded) unless "limited access". | [manage-sharing](https://developers.google.com/workspace/drive/api/guides/manage-sharing) | Same shape as Graph: effective grants per item, grantee namespaced. |
| `permissionDetails` gives `inherited`/`inheritedFrom` on shared drives. | same | Optional precision; not required by the model. |
| Group expansion needs the Admin SDK Directory API (domain-wide), not Drive. | Admin SDK | Google groups are unresolved unless the firm grants directory read → `:unknown`. |

**Common shape across both:** *(item, grantee, role)* triples, effective, with
grantees in four kinds — **person**, **group**, **audience** (domain /
organisation / anyone / link), **application**. That is the model.

## 2. The model: four relations, all datoms

```
identity      :ident/key   [provider tenant kind remote-id]     unique
              :ident/kind  :person | :group | :audience | :application
              :ident/email (persons, lowercased) · :ident/name

principal ←→ identity
              :ident/principal   ref → the product's principal (0..1)
              written ONLY by an explicit link (§4) — never guessed

membership    :member/of  ref → identity (a group)
              :member/is  ref → identity (person or group)
              :member/as-of  ms   · :member/complete? bool (group fully expanded?)

source ACL    :acl/item    ref → mirrored item (:conn/key)
              :acl/grantee ref → identity
              :acl/role    :read | :write | :owner   (normalised)
              :acl/as-of   ms
              :acl/complete? on the ITEM: did we see the whole ACL? (owner view)
```

Product grants are NOT moved here; they stay where the product keeps them
(knowledger `:grant/*`, one door). The relation joins them in (§3).

Normalised roles: Graph `read`→`:read`, `write`→`:write`, `owner`/`fullcontrol`→`:owner`;
Drive `reader`/`commenter`→`:read`, `writer`/`fileOrganizer`→`:write`,
`owner`/`organizer`→`:owner`. `:write` and `:owner` imply `:read`.

## 3. The relations (registered with `defrelation`, value defs — AOT-safe)

```
:~ident/member-of  [?identity ?group]   transitive over :member/is → :member/of
:~acl/source-reads [?identity ?item]    some :acl on ?item names ?identity,
                                        directly or via :~ident/member-of,
                                        or an :audience that covers ?identity
:~acl/may-read     [?principal ?item]   the ONE answer the product reads:
                                        product-grant(?principal, library of ?item)
                                        ∧ (mode = :mirror ⇒ source-reads(identity-of ?principal, ?item))
```

`:~acl/may-read` is parameterised per scope by a **policy mode** — the single
place the two answers are combined, stated as data on the mount/library:

| mode | meaning | when |
|---|---|---|
| `:product` | product grants alone decide; source ACLs only feed the check (§5) | today's behaviour; default |
| `:mirror` | product grant **AND** source ACL must both allow (intersection) | firms that want "Knowledger never shows more than SharePoint" |
| `:source` | source ACL alone (product grant = membership in the firm) | later; requires complete identity linking |

Intersection, not union: a product grant can only NARROW what the source
allows in `:mirror` — the same monotonicity that makes `auth.rls` safe (an
injected clause can only remove rows). Unknowns resolve to **deny** in
`:mirror` and to **:unknown** in the check — never to allow.

## 4. Identity linking (external → internal)

A principal links to an identity only by an explicit, audited fact:

1. **By verified email** — at sign-in/connect the provider asserts the email
   (Entra `mail`/`userPrincipalName`, Google `email`); the link is proposed
   and an admin confirms in bulk. Never auto-trusted from a free-text email.
2. **By SSO claim** — when the product signs people in with Entra/Google
   (`auth.strategy/claims-strategy`), the claim `oid`/`sub` IS the identity
   key → link is automatic and exact.

Unlinked principals: in `:mirror` mode they read **nothing** from that scope
(fail closed); the people screen shows "not linked to Microsoft 365".

### 4.1 Directory discovery (who exists at the source) — built

Built (2026-10-04): `connector.microsoft.graph/directory-fn` (on every feed with `:tenant`), `connector.google.gdrive/directory-fn` (feed opts `{:domain d}`); fakes: `fake-graph` `GET /v1.0/users` (403 until command `:grant-directory`; seeds a guest and a disabled user), `fake-drive` `/admin/directory/v1/users` (`grant-directory!`, `add-user!`). Opts `{:group gid}` scopes Graph to one group. People come back as `{:id :key :email :name :title :enabled? :guest?}`. Tests: test/bl/connector/directory_test.bl.

The same identities feed member discovery: the firm's directory is just the
set of `:person` identities a provider can enumerate. A feed MAY add

```
:directory (fn [get opts] → {:ok {:people [{:id :email :name :title :enabled?}] :next cursor}}
                           | {:error {:status 403 …}})
```

| provider | call | least permission (verified 2026-10-04) | without it |
|---|---|---|---|
| Microsoft | `GET /users?$select=id,displayName,mail,userPrincipalName,jobTitle,accountEnabled,userType` (paged, 999/page); optional `GET /groups/{id}/transitiveMembers` to limit to one Entra group | **Application `User.Read.All`** ([user-list](https://learn.microsoft.com/en-us/graph/api/user-list)); group-scoped: `GroupMember.ReadBasic.All` | 403 → discovery falls back to people seen in mirrored ACLs (§6) |
| Google | Admin SDK `users.list?domain=…&viewType=domain_public` — any domain user may read public profiles ([manage-users](https://developers.google.com/workspace/admin/directory/v1/guides/manage-users)) | scope `admin.directory.user.readonly` on the existing delegated grant | fallback to ACL-seen people |

Discovery writes `:ident/*` facts only (never principals, never grants):
inviting, linking and granting stay product decisions behind the product's
one door. Guests (`userType = Guest`) and disabled accounts are kept as
facts but flagged so the product never proposes them by default.

## 5. The check falls out for free

docs/21 §5's upper-bound check is one query over the same relations:

```
audience(library) − { p | ∀ item ∈ library: :~acl/source-reads(identity(p), item) }
  → per person: :within | :exceeds [items] | :unknown [reason]
```

`:unknown` reasons are first-class: `:unlinked`, `:group-unresolved`
(SharePoint site group / Google group without directory read),
`:acl-incomplete` (app saw only its own permission — non-owner view),
`:stale` (`:acl/as-of` older than the sweep budget).

## 6. Connector contract additions (provider-neutral)

A feed MAY add:

```
:acl      (fn [get item] → {:ok {:grants [{:grantee {:kind :id :email :name} :role}] :complete? bool}}
                          | {:error …})
:members  (fn [get group-identity] → {:ok {:members [identity…] :complete? bool}} | {:error …})
```

`connector.keep` writes `:acl/*` and `:member/*` facts in the same commit-last
transaction discipline (M3), only for items inside roots (M1). A feed without
`:acl` simply yields `:unknown` everywhere — the system degrades to today's
behaviour, never to a leak.

Graph: `:acl` = `GET /drives/{d}/items/{i}/permissions` (paged), `:complete?`
true only when the response includes grants other than our own application
(owner view); `:members` = `/groups/{id}/transitiveMembers` for Entra groups,
`{:complete? false}` for `siteGroup`/`sharePointGroup`.
Drive: `:acl` = `permissions.list` with `fields=permissions(id,type,role,emailAddress,domain)`;
`:members` = `{:complete? false}` until directory read is configured.

## 7. Open questions only a real tenant answers

- **Q1** With a site grant of role `read` (not `fullcontrol`), does
  `GET …/items/{i}/permissions` list other users' grants? Documented rule
  says no (non-owner sees own only). If no, the setup guide's step 4 offers
  `fullcontrol` *explicitly labelled* "lets Knowledger see who has access;
  Knowledger never writes".
- **Q2** Does `Prefer: deltashowsharingchanges` work under `Sites.Selected`
  + `fullcontrol` site grant, or only with tenant `Sites.FullControl.All`?
- **Q3** In a real team site, what fraction of effective grants name
  `siteGroup` vs Entra `group`? (Team sites created from M365 groups mostly
  grant the M365 group → expandable; classic sites → site groups → unknown.)

## 8. Build order

1. Upstream schema + relations (`connector.acl`, `:~ident/member-of`,
   `:~acl/source-reads`) with a veritas model test: random grants/groups/moves,
   invariant "`source-reads` = brute-force reachability".
2. Graph + Drive `:acl`/`:members` in the fakes (veritas-served: permissions
   endpoints honouring owner vs non-owner view) and the real connectors.
3. keep writes ACL/membership facts (M1/M3 preserved).
4. Product: identity linking + `:~acl/may-read` with the mode, the check, and
   every read path (search, library, MCP, export) through it.

## 9. Built (2026-10-04): what was decided while implementing

**Where.** `connector.acl` (schema, `graph-role`/`drive-role`, `identity-key`,
`grants-tx`, `members-tx`, the two relations, `reads-verdict`, `coverage`);
`connector.keep` (`{:acl? true}`, `refresh-acls!`); feeds `:acl`/`:members` in
`graph.bl` (`(feed drive base {:tenant :client-id :site-id})`) and `gdrive.bl`
(`(feed ns {:acl? true})`). Tests: `test/bl/connector/acl_test.bl`.

**Item-level facts live on the mirrored item** (`:acl.item/complete?`,
`:acl.item/as-of`), group-level on the group identity (`:member/complete?`,
`:member/as-of`): same lifecycle as the thing they describe, one lookup, no
extra key.

**Grants REPLACE.** `grants-tx` / `members-tx` retract rows no longer listed, so
a revoked share disappears on the next sync; `:acl/key = [item-key grantee-key]`
makes a re-sync an upsert. A permission the feed could not map (unknown link
scope, role outside the table, grantee with no key) arrives as a nil-role grant
and forces `:acl.item/complete? false` — never silently dropped.

**Audience semantics** (the docstring of `:~acl/source-reads` is normative):
`:anyone` covers every person; `:organization` covers persons whose tenant (the
2nd element of their identity key) equals the audience's; `:domain d` covers
persons whose KNOWN email has domain `d` (a person we only know by id is
covered by nothing narrower than `:anyone`). Graph `link` scope `users` becomes
direct per-person grants; `existingAccess` links grant nothing and are dropped.
Application grantees are stored but never match a person.

**Verdict order.** no `:acl.item/as-of` → `:no-acl-data`; older than
`:max-age-ms` → `:stale` (before `:yes`: a revoke may have happened since);
a definite grant reaching the identity → `:yes`; list not complete →
`:acl-incomplete`; a grantee group (or one nested inside) never fully expanded
→ `:group-unresolved`; else `:no`. `:yes` therefore survives an incomplete
list or unresolved groups (one definite grant suffices) — only `:no` needs the
whole picture.

**A known ambiguity, not hidden.** An owner view whose effective list is empty
or contains only our own grant is indistinguishable from a non-owner view, so it
is recorded incomplete (`:acl-incomplete`). The tests/model pin this. It errs
toward `:unknown`, never toward allow.

**Commit discipline (M1/M3).** ACL facts are produced by the same helper that
writes the item, in the same transaction, only on branches that already passed
the root-closure judgement; the cursor still rides in the LAST transaction, so
no cursor advance precedes durable ACL facts. Group membership is fetched once
per group per step and rides in the first transaction that references it. A
failing `:acl` fetch writes nothing for that item and is counted in the step
report's `:acl-errors`; its older facts keep their older `as-of` and age out as
`:stale`. Two seed-mode caveats: a seed issues one `:acl` request per item
(N+1; Graph `$batch` would cut it — not done), and the Drive/Graph `:enumerate`
path calls `:acl` for kept items only.

**Sweep.** `(refresh-acls! keep {:older-than-ms n})` re-fetches every live item
under the roots whose ACL is older than the budget (delta does not carry
permission-only changes).

**Not implemented faithfully / open.** (1) Q1–Q3 remain unverified on a real
tenant; the fake implements the documented owner/non-owner rule. (2) Drive
`:complete? true` assumes the keep's caller is the owner; Drive may omit
sharing data for a non-owner viewer — not modelled. (3) `:~acl/may-read`,
identity linking and policy modes (§3–§4) are product work. (4) `:~acl/source-reads`
is recomputed per query (`:maintenance :recompute`), fine for a mirror of
thousands of ACL rows; no incremental maintenance.
