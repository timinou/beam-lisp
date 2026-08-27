//! Axis 4 — PreM (Pushing Extrema into Recursion), native form.
//!
//! Zaniolo's optimisation: instead of computing a full relation and then taking
//! a min/max in an outer stratum, push the extremum INTO the recursive rule so
//! only the current best survives each round. For shortest-path this means the
//! `path` relation keeps one cost per node (the smallest so far), which both
//! shrinks the fixpoint and makes it converge on cyclic graphs.
//!
//! # Scope note (honesty)
//!
//! This native form is retained only as part of the measured spike. The
//! *reconciled* design implements PreM as a beam-lisp rule-rewrite over rule
//! DATA (one representation, composes with the whole engine) — see
//! `priv/datom/query/prem.bl`. This module exists so the spike can, if the
//! head-to-head number ever justifies a native kernel, show the extremum-keyed
//! relation maintenance in Rust. It operates on an already-grouped relation:
//! given tuples `[key, cost]`, keep the min cost per key.

use crate::ir::Relation;
use std::collections::HashMap;

/// Reduce a 2-column relation `[key, value]` to the minimum value per key.
/// Returns a fresh relation with one row per distinct key.
pub fn min_by_key(rel: &Relation) -> Relation {
    debug_assert!(rel.arity == 2);
    let mut best: HashMap<i64, i64> = HashMap::new();
    for row in rel.rows() {
        let (k, v) = (row[0], row[1]);
        best.entry(k).and_modify(|b| {
            if v < *b {
                *b = v;
            }
        }).or_insert(v);
    }
    let mut out = Relation::new(2);
    for (k, v) in best {
        out.insert(&[k, v]);
    }
    out
}

/// Symmetric max variant.
pub fn max_by_key(rel: &Relation) -> Relation {
    debug_assert!(rel.arity == 2);
    let mut best: HashMap<i64, i64> = HashMap::new();
    for row in rel.rows() {
        let (k, v) = (row[0], row[1]);
        best.entry(k).and_modify(|b| {
            if v > *b {
                *b = v;
            }
        }).or_insert(v);
    }
    let mut out = Relation::new(2);
    for (k, v) in best {
        out.insert(&[k, v]);
    }
    out
}
