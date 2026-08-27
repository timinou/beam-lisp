//! `datom_datalog` — a native Datalog engine for the beam-lisp datom store.
//!
//! # Why this crate exists
//!
//! beam-lisp already has a Datalog query engine, and it now has recursive
//! rules evaluated semi-naively (see `priv/datom/query/rules.bl`). But that
//! evaluator runs *in the interpreter*: every tuple is a boxed BEAM term,
//! every join a nested loop over bl sets, every round a bl `reduce`. Profiling
//! showed the fixpoint of a length-60 transitive-closure chain takes ~800ms
//! and a *bound* query (reachable-from-one-node) computes the whole 1770-tuple
//! closure to answer a 59-tuple question.
//!
//! This crate is the substrate that fixes the constant factor AND hosts the
//! algorithmic improvements. The Datalog program is still written in beam-lisp;
//! bl interns its symbols to integers and hands the crate a compact IR plus
//! integer-encoded base relations. The fixpoint then runs entirely in Rust,
//! over `i64` tuples in hash-indexed relations, and returns the answer
//! relation as integers bl decodes back. **Native speed for a program authored
//! in Datalog** — the architecture the user asked for.
//!
//! # The five axes, all on this substrate
//!
//! The point is not one evaluator but a *bench* of them, so their costs can be
//! compared on identical inputs:
//!
//!   * **Axis 5 (substrate)** — `eval_seminaive`: the delta-restricted fixpoint,
//!     in native code. The baseline everything else is measured against.
//!   * **Axis 2 (join)** — `eval_seminaive` already builds a HASH INDEX on the
//!     join key each round (`join_indexed`), versus `eval_nested` which is the
//!     naive nested-loop. The pair measures what indexing buys.
//!   * **Axis 1 (demand)** — `eval_magic`: apply a magic-sets rewrite so a
//!     bound query only derives query-relevant facts, then evaluate that.
//!   * **Axis 4 (aggregates in recursion)** — `eval_prem`: a monotone min/max
//!     pushed INTO the recursive rule (PreM), so shortest-path / connected-
//!     components converge without a full closure then an outer min.
//!   * **Axis 3 (incremental)** — `eval_delta`: given an already-materialised
//!     relation and a set of NEW base facts, maintain the fixpoint by
//!     propagating only the delta, instead of recomputing from scratch.
//!
//! # IR, in one paragraph
//!
//! A predicate is a small integer id. A term is a variable (a slot index in
//! the rule) or a constant (`i64`). An atom is a predicate id + a vector of
//! terms. A rule is a head atom + body atoms, where a body atom whose
//! predicate is an IDB predicate is a recursive reference. Everything the
//! engine needs is integers; strings never cross the boundary.

mod ir;
mod eval;
mod magic;
#[allow(dead_code)]
mod prem;
mod nif;

pub use ir::*;

/// Wrap a message as a BEAM-raisable error term.
pub(crate) fn err(msg: impl std::fmt::Display) -> rustler::Error {
    rustler::Error::Term(Box::new(format!("{}", msg)))
}

rustler::init!("Elixir.BeamLisp.Native.Datom.Datalog");
