//! Axis 1 — Magic Sets: demand-driven rewriting.
//!
//! # The problem it solves
//!
//! Bottom-up evaluation computes the WHOLE least fixpoint, ignoring the query.
//! Ask "who is reachable from node 1" over a chain and it still derives every
//! reachable pair — the measured 1770-tuples-to-answer-59 waste. Magic sets is
//! a source-to-source rewrite that makes bottom-up evaluation *goal-directed*:
//! it only derives facts relevant to the query's bound arguments.
//!
//! # How it works (the classic transformation)
//!
//! For a query `reachable(1, ?b)` — argument 1 bound, argument 2 free, an
//! adornment `bf` — we introduce a `magic_reachable_bf` relation seeded with
//! the bound value `{1}`. Each rule gets:
//!   * a MAGIC version of each recursive body atom, so a subgoal is only
//!     pursued when it is demanded;
//!   * a guard: the head is derived only for demanded bindings.
//!
//! For linear transitive closure the rewrite is:
//! ```text
//!   magic(1).                                   % seed from the query's bound arg
//!   magic(X)   :- magic(A), edge(A, X_).        % demand propagates along edges
//!   reachable(A,B) :- magic(A), edge(A,B).      % base, guarded by demand
//!   reachable(A,B) :- magic(A), edge(A,X), reachable(X,B).
//! ```
//! Evaluated bottom-up (semi-naive), this derives only the reachable set of the
//! seed — exactly the top-down work, without top-down's non-termination.
//!
//! # Scope of this prototype
//!
//! A full magic-sets compiler handles arbitrary adornments and rule shapes.
//! This prototype implements the transformation for the common and measurable
//! case: a single recursive predicate with a bound FIRST argument (the
//! reachability / same-source shape), which is exactly the workload the
//! profiling targets. It returns a rewritten `Program` plus the seed facts,
//! which the ordinary semi-naive driver then evaluates — so the demand
//! optimisation composes with the native substrate rather than replacing it.

use crate::ir::*;

/// The magic-predicate id for `p` is derived deterministically so bl and the
/// engine agree without another interning round: we reserve a high offset.
pub const MAGIC_OFFSET: u32 = 1 << 20;

pub fn magic_pred(p: u32) -> u32 {
    p + MAGIC_OFFSET
}

/// Rewrite `prog` for a query on `query_pred` whose FIRST argument is bound to
/// `seed` (adornment `b...f`). Returns the rewritten program and the seed EDB
/// (the `magic` relation with one tuple, the bound value).
///
/// The transformation, for each rule defining `query_pred`:
///   * prepend a `magic_p(A)` guard atom (A = the head's first arg variable);
///   * for each recursive body atom `p(X, _)`, emit a demand rule
///     `magic_p(X) :- magic_p(A), <preceding non-recursive body atoms>`.
pub fn transform(prog: &Program, query_pred: u32, seed: i64) -> (Program, Db) {
    let mp = magic_pred(query_pred);
    let mut rules: Vec<Rule> = Vec::new();

    for rule in prog.rules_for(query_pred) {
        // the head's first argument must be a variable to guard on
        let head_first = rule.head.terms.first().cloned();
        let guard_var = match head_first {
            Some(Term::Var(v)) => v,
            _ => {
                // head's first arg is constant — no demand to propagate; keep as-is
                rules.push(rule.clone());
                continue;
            }
        };

        // guarded version of the original rule: magic_p(A), <body...>
        let mut guarded_body = vec![Atom {
            pred: mp,
            terms: vec![Term::Var(guard_var)],
        }];
        guarded_body.extend(rule.body.iter().cloned());
        rules.push(Rule {
            head: rule.head.clone(),
            body: guarded_body,
            nvars: rule.nvars,
        });

        // demand rules: for each recursive body atom, propagate magic to its
        // first argument, guarded by magic on the head var and any preceding
        // non-recursive atoms (sideways information passing).
        for (i, atom) in rule.body.iter().enumerate() {
            if atom.pred != query_pred {
                continue;
            }
            let rec_first = match atom.terms.first() {
                Some(Term::Var(v)) => *v,
                _ => continue,
            };
            // body = magic_p(A) + preceding non-recursive atoms
            let mut dbody = vec![Atom {
                pred: mp,
                terms: vec![Term::Var(guard_var)],
            }];
            for prev in rule.body.iter().take(i) {
                if prev.pred != query_pred {
                    dbody.push(prev.clone());
                }
            }
            rules.push(Rule {
                head: Atom {
                    pred: mp,
                    terms: vec![Term::Var(rec_first)],
                },
                body: dbody,
                nvars: rule.nvars,
            });
        }
    }

    // keep any rules for other predicates unchanged
    for rule in &prog.rules {
        if rule.head.pred != query_pred {
            rules.push(rule.clone());
        }
    }

    let mut idb = prog.idb.clone();
    if !idb.contains(&mp) {
        idb.push(mp);
    }

    // Seed the demand as a FACT RULE `magic_p(seed).` — a rule with a constant
    // head and empty body. The magic predicate is IDB (computed), so a seed
    // placed in the EDB would be ignored; a fact rule derives it in the first
    // round, from which demand propagates. `nvars` 0 because the head is ground.
    rules.push(Rule {
        head: Atom {
            pred: mp,
            terms: vec![Term::Const(seed)],
        },
        body: vec![],
        nvars: 0,
    });

    (Program { rules, idb }, Db::default())
}
