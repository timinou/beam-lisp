//! Evaluation: the join kernel and the fixpoint drivers.
//!
//! This module holds Axis 5 (native semi-naive), Axis 2 (indexed vs nested
//! join), and Axis 3 (incremental delta maintenance). Axes 1 and 4 live in
//! their own modules but call the same join kernel here.

use crate::ir::*;
use std::collections::HashMap;

/// A binding row during rule evaluation: variable slot -> value, or unbound.
type Binding = Vec<Option<i64>>;

/// Try to unify atom `atom` against a concrete `tuple`, extending `binding`.
/// Returns the extended binding, or None on a conflict. This is the same
/// unification the bl engine does, but over integer slots.
fn unify(atom: &Atom, tuple: &[i64], binding: &Binding) -> Option<Binding> {
    if atom.terms.len() != tuple.len() {
        return None;
    }
    let mut b = binding.clone();
    for (i, term) in atom.terms.iter().enumerate() {
        let val = tuple[i];
        match term {
            Term::Const(c) => {
                if *c != val {
                    return None;
                }
            }
            Term::Var(v) => {
                let slot = *v as usize;
                match b[slot] {
                    Some(existing) => {
                        if existing != val {
                            return None;
                        }
                    }
                    None => b[slot] = Some(val),
                }
            }
        }
    }
    Some(b)
}

/// Which columns of `atom` are already bound by `binding` (join keys), paired
/// with their required values. Used to probe a hash index instead of scanning.


/// Evaluate a rule body against a set of relations, returning the head tuples
/// it derives. `indexed` selects the Axis-2 join strategy:
///   * false → NESTED LOOP: for each partial binding, scan the whole relation.
///   * true  → HASH INDEX: probe only the rows whose join key matches.
/// `rel_of` supplies the relation to read for a given body atom — this is what
/// lets the semi-naive driver substitute a DELTA for one recursive predicate.
fn eval_body<'a, F>(rule: &Rule, mut rel_of: F, indexed: bool) -> Vec<Vec<i64>>
where
    F: FnMut(usize) -> &'a Relation,
{
    // start with one empty binding
    let mut partials: Vec<Binding> = vec![vec![None; rule.nvars as usize]];

    for (bi, atom) in rule.body.iter().enumerate() {
        let rel = rel_of(bi);
        let mut next: Vec<Binding> = Vec::new();

        if indexed {
            // Build the hash index ONCE per atom per round, on the columns the
            // atom joins on — the positions that are either a constant or a
            // variable ALREADY bound by an earlier body atom (the same for
            // every partial, since body order is fixed). Then every partial
            // probes in O(1). Building it per-partial (the earlier bug) made
            // "indexed" slower than nested; building once is the actual win.
            let key_cols: Vec<usize> = atom
                .terms
                .iter()
                .enumerate()
                .filter_map(|(i, t)| match t {
                    Term::Const(_) => Some(i),
                    Term::Var(v) => {
                        // bound by a preceding atom iff some partial has it set
                        // (body order is fixed, so this holds for all partials)
                        if partials.first().map_or(false, |b| b[*v as usize].is_some()) {
                            Some(i)
                        } else {
                            None
                        }
                    }
                })
                .collect();

            if key_cols.is_empty() {
                // no join key: this atom is a full scan for every partial
                for b in &partials {
                    for row in rel.rows() {
                        if let Some(nb) = unify(atom, row, b) {
                            next.push(nb);
                        }
                    }
                }
            } else {
                let idx = rel.index_on(&key_cols);
                for b in &partials {
                    // the probe key: constant value at a const col, bound value
                    // at a var col
                    let key: Vec<i64> = key_cols
                        .iter()
                        .map(|&c| match &atom.terms[c] {
                            Term::Const(k) => *k,
                            Term::Var(v) => b[*v as usize].unwrap(),
                        })
                        .collect();
                    if let Some(rows) = idx.get(&key) {
                        for &ri in rows {
                            if let Some(nb) = unify(atom, rel.row(ri), b) {
                                next.push(nb);
                            }
                        }
                    }
                }
            }
        } else {
            // nested loop: every partial × every row
            for b in &partials {
                for row in rel.rows() {
                    if let Some(nb) = unify(atom, row, b) {
                        next.push(nb);
                    }
                }
            }
        }
        partials = next;
        if partials.is_empty() {
            break;
        }
    }

    // project each complete binding through the head
    let mut out = Vec::new();
    for b in &partials {
        let mut tuple = Vec::with_capacity(rule.head.terms.len());
        let mut ok = true;
        for term in &rule.head.terms {
            match term {
                Term::Const(c) => tuple.push(*c),
                Term::Var(v) => match b[*v as usize] {
                    Some(val) => tuple.push(val),
                    None => {
                        ok = false;
                        break;
                    }
                },
            }
        }
        if ok {
            out.push(tuple);
        }
    }
    out
}

/// The arity of a predicate, from the first rule head or body atom that names
/// it, else from an existing relation.
fn arity_of(prog: &Program, edb: &Db, p: u32) -> usize {
    for r in &prog.rules {
        if r.head.pred == p {
            return r.head.terms.len();
        }
        for a in &r.body {
            if a.pred == p {
                return a.terms.len();
            }
        }
    }
    edb.get(p).map(|r| r.arity).unwrap_or(0)
}

/// One application of every rule for the IDB predicates, reading `state`.
/// `delta` (when Some) restricts recursive self-references to the delta — the
/// semi-naive move. Returns freshly-derived tuples per predicate.
fn apply_round(
    prog: &Program,
    edb: &Db,
    state: &Db,
    delta: Option<&Db>,
    indexed: bool,
) -> HashMap<u32, Vec<Vec<i64>>> {
    let mut derived: HashMap<u32, Vec<Vec<i64>>> = HashMap::new();

    for &p in &prog.idb {
        for rule in prog.rules_for(p) {
            // For the semi-naive step we must, for each recursive body atom,
            // run one variant where THAT atom reads the delta and the others
            // read the full state. Summing those variants covers exactly the
            // derivations that use at least one new fact. When delta is None
            // (naive), a single variant reads full state everywhere.
            let recursive_positions: Vec<usize> = rule
                .body
                .iter()
                .enumerate()
                .filter(|(_, a)| prog.idb.contains(&a.pred))
                .map(|(i, _)| i)
                .collect();

            let empty = Db::default();
            let dref = delta.unwrap_or(&empty);

            let variants: Vec<Option<usize>> = if delta.is_none() || recursive_positions.is_empty() {
                vec![None] // naive: one pass, full state
            } else {
                recursive_positions.iter().map(|&i| Some(i)).collect()
            };

            for variant in variants {
                let out = eval_body(
                    rule,
                    |bi| {
                        let atom = &rule.body[bi];
                        // EDB predicate: always the base relation.
                        if !prog.idb.contains(&atom.pred) {
                            return edb.get(atom.pred).unwrap_or_else(|| {
                                empty_rel(edb, atom.pred)
                            });
                        }
                        // IDB predicate: delta for the designated position,
                        // full state elsewhere.
                        match variant {
                            Some(dpos) if dpos == bi => dref
                                .get(atom.pred)
                                .unwrap_or_else(|| empty_rel(dref, atom.pred)),
                            _ => state
                                .get(atom.pred)
                                .unwrap_or_else(|| empty_rel(state, atom.pred)),
                        }
                    },
                    indexed,
                );
                derived.entry(p).or_default().extend(out);
            }
        }
    }
    derived
}

/// A leaked empty relation for a missing predicate (arity 0) — cheap, and only
/// hit on the first round before a relation exists.
fn empty_rel(_db: &Db, _p: u32) -> &'static Relation {
    use std::sync::OnceLock;
    static EMPTY: OnceLock<Relation> = OnceLock::new();
    EMPTY.get_or_init(|| Relation::new(0))
}

/// Fold freshly-derived tuples into `state`, returning the count of genuinely
/// new tuples added (0 ⇒ fixpoint) and the per-predicate NEW tuples (the next
/// delta).
fn integrate(
    prog: &Program,
    edb: &Db,
    state: &mut Db,
    derived: HashMap<u32, Vec<Vec<i64>>>,
) -> (usize, Db) {
    let mut new_count = 0;
    let mut next_delta = Db::default();
    for (p, tuples) in derived {
        let ar = arity_of(prog, edb, p).max(tuples.first().map(|t| t.len()).unwrap_or(0));
        let rel = state.rels.entry(p).or_insert_with(|| Relation::new(ar));
        let drel = next_delta.rels.entry(p).or_insert_with(|| Relation::new(ar));
        for t in tuples {
            if rel.insert(&t) {
                new_count += 1;
                drel.insert(&t);
            }
        }
    }
    (new_count, next_delta)
}

/// NAIVE fixpoint (the reference): recompute from full state each round.
/// Returns (final db, rounds).
pub fn eval_naive(prog: &Program, edb: &Db, indexed: bool) -> (Db, usize) {
    let mut state = Db::default();
    let mut rounds = 0;
    loop {
        let derived = apply_round(prog, edb, &state, None, indexed);
        let (new_count, _) = integrate(prog, edb, &mut state, derived);
        if new_count == 0 {
            return (state, rounds);
        }
        rounds += 1;
    }
}

/// SEMI-NAIVE fixpoint (Axis 5): each round joins only last round's DELTA
/// against the base. `indexed` selects the Axis-2 join. Returns (db, rounds).
pub fn eval_seminaive(prog: &Program, edb: &Db, indexed: bool) -> (Db, usize) {
    let mut state = Db::default();

    // seed: one naive round from empty state derives the base (non-recursive)
    // facts, which become the first delta.
    let seed = apply_round(prog, edb, &state, None, indexed);
    let (_, mut delta) = integrate(prog, edb, &mut state, seed);
    let mut rounds = 1;

    loop {
        let empty = delta.rels.values().all(|r| r.is_empty());
        if empty {
            return (state, rounds);
        }
        let derived = apply_round(prog, edb, &state, Some(&delta), indexed);
        let (new_count, next_delta) = integrate(prog, edb, &mut state, derived);
        if new_count == 0 {
            return (state, rounds);
        }
        delta = next_delta;
        rounds += 1;
    }
}

/// INCREMENTAL maintenance (Axis 3): given an already-materialised `state` and
/// a set of NEW base facts `new_edb`, extend the fixpoint by propagating only
/// the delta, rather than recomputing from scratch. The new base facts are the
/// initial delta; each round derives consequences that use a new fact.
///
/// Returns (updated state, rounds). The `edb` passed in must already include
/// the new facts (so joins see them); `new_edb` names just the delta.
pub fn eval_delta(prog: &Program, edb: &Db, state: &Db, new_edb: &Db) -> (Db, usize) {
    let mut state = state.clone();

    // The initial delta is the new EDB facts, promoted into the delta db under
    // their predicates, PLUS any IDB facts they immediately derive.
    let mut delta = new_edb.clone();
    let mut rounds = 0;

    loop {
        let empty = delta.rels.values().all(|r| r.is_empty());
        if empty {
            return (state, rounds);
        }
        let derived = apply_round(prog, edb, &state, Some(&delta), true);
        let (new_count, next_delta) = integrate(prog, edb, &mut state, derived);
        rounds += 1;
        if new_count == 0 {
            return (state, rounds);
        }
        delta = next_delta;
    }
}
