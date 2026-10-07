# Who owns a namespace

A namespace name is a claim on a BEAM module name. Two projects in one VM that define the same name would replace each other's code, so every namespace has exactly one **home**, decided in one place (the loader's `namespace-home`).

| home | what it is | module | who may define it |
|---|---|---|---|
| `:tier` | std, lib, boot, compat, build: the platform | `BeamLisp.Ns.<Ns>`, loaded once per VM | the build only |
| `:realm` | a project file no tier owns | `BeamLisp.Ns.R<key>.<Ns>` | that project |
| `:shadow` | a project file that replaces a tier namespace, for this realm only | `BeamLisp.Ns.R<key>.<Ns>` | that project, **if `env.bl` declares it** |
| `:shared` | a project file declared shared with a content hash | `BeamLisp.Ns.S<hash>.<Ns>` | every project declaring that hash |
| `:refuse` | a project file whose name a tier owns, undeclared | none | nobody: a named load error |

## Declaring it

```clojure
{:realm  "pulse"                               ; optional alias for people
 :shadow ["datom.query.plan" "proc.server"]    ; local improvements of library namespaces
 :uses   {"lib.common" {:path "../common"
                        :hash "sha256:…"}}}    ; shared code, by content
```

- **Shadowing is allowed, within the realm.** It exists so a project can carry an improved library until the improvement merges into main; the diff between the shadow and the library *is* the change to merge. Other realms, the gateway and the console keep the library's version, and library namespaces already linked to the original keep calling it.
- **An undeclared shadow is refused**, naming the namespace, the file, the library's owner and the line to add. This keeps a stray file, or a `priv/std` left on `BEAM_LISP_PATH`, from silently replacing platform code (FUP-152).
- **Shared code is declared with its hash.** The hash is of the dependency's source closure. Two projects with the same hash share one module; two with different hashes get two modules and cannot clash. A shared namespace may require only tier or shared namespaces, so it cannot reach into one realm's private code.

## What stays one-per-VM

Isolation covers *code*. A named process, an ETS table or a `persistent_term` key in project code is still one per VM, and so is the OS environment (FUP-151, `:env`). See [`caveats.md`](caveats.md).
