//! The intermediate representation: rules and relations as integers.
//!
//! bl interns every predicate name, variable, and constant to an integer
//! before calling in, so this module never sees a string. That keeps the hot
//! path branch-free on tags and lets relations be `Vec<i64>` blocks.

use std::collections::HashMap;

/// A term in a rule-body atom: either a variable (a slot in the rule) or a
/// bound constant.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Term {
    /// A variable, identified by its slot index within the rule (0-based).
    Var(u32),
    /// A ground constant.
    Const(i64),
}

/// An atom: a predicate applied to terms. `pred` is a predicate id; the arity
/// is `terms.len()`.
#[derive(Clone, Debug)]
pub struct Atom {
    pub pred: u32,
    pub terms: Vec<Term>,
}

impl Atom {
    /// The distinct variable slots this atom mentions.
    pub fn vars(&self) -> Vec<u32> {
        let mut vs = Vec::new();
        for t in &self.terms {
            if let Term::Var(v) = t {
                if !vs.contains(v) {
                    vs.push(*v);
                }
            }
        }
        vs
    }
}

/// A COMPUTED atom: a value derived from bound variables by a primitive
/// operation, then bound to (or checked against) a target term. This is the
/// ONLY thing a rule body needs that a pre-materialised base relation cannot
/// supply, because its inputs may be recursive variables (`d = dx + w` in
/// shortest-path). The operation set is CLOSED and universal — `+ - * min max`
/// and the comparisons — so it introduces no bl-defined semantics that could
/// drift; `+` means `+`. Anything outside this set is rejected at compile time
/// (see the bl compiler), which keeps the boundary exact.
#[derive(Clone, Debug)]
pub struct Computed {
    pub op: Op,
    /// argument terms (variables must already be bound by an earlier body atom)
    pub args: Vec<Term>,
    /// where the result goes: a Var binds it, a Const asserts equality (a guard)
    pub out: Term,
}

/// The closed primitive vocabulary. Integer semantics are pinned: wrapping is
/// forbidden (overflow saturates to i64::MIN/MAX so a runaway cost can't wrap
/// negative and corrupt a min-fixpoint); division by zero yields no binding
/// (the row is dropped) rather than trapping.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Op {
    Add,
    Sub,
    Mul,
    Min,
    Max,
    Lt,
    Le,
    Gt,
    Ge,
    Eq,
    Ne,
}

impl Op {
    pub fn from_code(c: i64) -> Option<Op> {
        Some(match c {
            0 => Op::Add,
            1 => Op::Sub,
            2 => Op::Mul,
            3 => Op::Min,
            4 => Op::Max,
            10 => Op::Lt,
            11 => Op::Le,
            12 => Op::Gt,
            13 => Op::Ge,
            14 => Op::Eq,
            15 => Op::Ne,
            _ => return None,
        })
    }

    /// Whether this op is a COMPARISON (returns a guard, binds nothing).
    pub fn is_predicate(&self) -> bool {
        matches!(self, Op::Lt | Op::Le | Op::Gt | Op::Ge | Op::Eq | Op::Ne)
    }

    /// Evaluate over two integers. Arithmetic saturates; comparisons return
    /// 1/0. Returns None only if a comparison — the caller treats a false
    /// comparison as "drop the row".
    pub fn apply(&self, a: i64, b: i64) -> i64 {
        match self {
            Op::Add => a.saturating_add(b),
            Op::Sub => a.saturating_sub(b),
            Op::Mul => a.saturating_mul(b),
            Op::Min => a.min(b),
            Op::Max => a.max(b),
            Op::Lt => (a < b) as i64,
            Op::Le => (a <= b) as i64,
            Op::Gt => (a > b) as i64,
            Op::Ge => (a >= b) as i64,
            Op::Eq => (a == b) as i64,
            Op::Ne => (a != b) as i64,
        }
    }
}

/// A body element: either an atom (a relation to join) or a computed value.
#[derive(Clone, Debug)]
pub enum BodyItem {
    Atom(Atom),
    Computed(Computed),
}

/// A rule: `head :- body`. `nvars` is how many variable slots the rule uses
/// (so a binding row can be a fixed-width `Vec<Option<i64>>`).
#[derive(Clone, Debug)]
pub struct Rule {
    pub head: Atom,
    pub body: Vec<BodyItem>,
    pub nvars: u32,
}

impl Rule {
    /// The relation-atoms in the body (skipping computed items).
    pub fn atoms(&self) -> impl Iterator<Item = &Atom> {
        self.body.iter().filter_map(|b| match b {
            BodyItem::Atom(a) => Some(a),
            _ => None,
        })
    }

    /// Whether the body references any of the given IDB predicates — i.e. the
    /// rule is recursive with respect to them.
    pub fn is_recursive(&self, idb: &[u32]) -> bool {
        self.atoms().any(|a| idb.contains(&a.pred))
    }
}

/// A program: the rules plus the set of predicate ids that are IDB (defined by
/// rules, computed to a fixpoint) rather than EDB (given as base facts).
#[derive(Clone, Debug)]
pub struct Program {
    pub rules: Vec<Rule>,
    pub idb: Vec<u32>,
}

impl Program {
    /// The rules whose head is predicate `p`.
    pub fn rules_for(&self, p: u32) -> impl Iterator<Item = &Rule> {
        self.rules.iter().filter(move |r| r.head.pred == p)
    }
}

/// A relation: the set of tuples derived (or given) for one predicate. Tuples
/// are fixed-arity `i64` rows, stored flat (row-major) with a dedup set for
/// membership. The flat block is what makes a join scan cache-friendly.
#[derive(Clone, Debug, Default)]
pub struct Relation {
    pub arity: usize,
    /// row-major tuple data: row i is `data[i*arity .. (i+1)*arity]`
    pub data: Vec<i64>,
    /// membership set, keyed by the tuple bytes, for O(1) "is this new?"
    seen: std::collections::HashSet<Vec<i64>>,
}

impl Relation {
    pub fn new(arity: usize) -> Self {
        Relation {
            arity,
            data: Vec::new(),
            seen: std::collections::HashSet::new(),
        }
    }

    pub fn len(&self) -> usize {
        if self.arity == 0 {
            0
        } else {
            self.data.len() / self.arity
        }
    }

    pub fn is_empty(&self) -> bool {
        self.data.is_empty()
    }

    /// Row `i` as a slice.
    pub fn row(&self, i: usize) -> &[i64] {
        &self.data[i * self.arity..(i + 1) * self.arity]
    }

    /// Insert a tuple if not already present; returns true if it was new.
    pub fn insert(&mut self, tuple: &[i64]) -> bool {
        if self.seen.contains(tuple) {
            return false;
        }
        self.seen.insert(tuple.to_vec());
        self.data.extend_from_slice(tuple);
        true
    }

    /// Iterate rows.
    pub fn rows(&self) -> impl Iterator<Item = &[i64]> {
        (0..self.len()).map(move |i| self.row(i))
    }

    /// A hash index mapping a projection on `key_cols` to the row indices that
    /// carry those key values. This is the Axis-2 structure: build once, probe
    /// in O(1) instead of scanning every row.
    pub fn index_on(&self, key_cols: &[usize]) -> HashMap<Vec<i64>, Vec<usize>> {
        let mut idx: HashMap<Vec<i64>, Vec<usize>> = HashMap::new();
        for i in 0..self.len() {
            let row = self.row(i);
            let key: Vec<i64> = key_cols.iter().map(|&c| row[c]).collect();
            idx.entry(key).or_default().push(i);
        }
        idx
    }
}

/// The full set of relations, indexed by predicate id.
#[derive(Clone, Debug, Default)]
pub struct Db {
    pub rels: HashMap<u32, Relation>,
}

impl Db {
    pub fn get(&self, p: u32) -> Option<&Relation> {
        self.rels.get(&p)
    }

    pub fn get_or_empty(&self, p: u32, arity: usize) -> Relation {
        self.rels
            .get(&p)
            .cloned()
            .unwrap_or_else(|| Relation::new(arity))
    }

    pub fn set(&mut self, p: u32, r: Relation) {
        self.rels.insert(p, r);
    }
}
