//! Constant-work demand accounting, independent of ERTS and graph locks.
//!
//! Counts bound graph-node traversal cost; accounted positive growth bounds
//! saved-state traversal cost. Neither admission reservations nor failed writes
//! count as growth. A request is consumed at START of a round: arrivals during
//! the scan can queue the next round rather than disappear at its end.
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

const MIN_COUNT: usize = 16 * 1024;
const MIN_BYTES: usize = 16 * 1024 * 1024;

pub(crate) struct Schedule {
    count: AtomicUsize,
    bytes: AtomicUsize,
    count_threshold: AtomicUsize,
    byte_threshold: AtomicUsize,
    requested: AtomicBool,
}

impl Schedule {
    pub(crate) const fn new() -> Self {
        Self {
            count: AtomicUsize::new(0),
            bytes: AtomicUsize::new(0),
            count_threshold: AtomicUsize::new(MIN_COUNT),
            byte_threshold: AtomicUsize::new(MIN_BYTES),
            requested: AtomicBool::new(false),
        }
    }

    fn request(&self, due: bool) -> bool {
        due && !self.requested.swap(true, Ordering::AcqRel)
    }

    fn due(&self) -> bool {
        self.count.load(Ordering::Acquire) >= self.count_threshold.load(Ordering::Acquire)
            || self.bytes.load(Ordering::Acquire) >= self.byte_threshold.load(Ordering::Acquire)
    }

    pub(crate) fn registration(&self) -> bool {
        // Snapshot BEFORE adding: raising a threshold at round completion
        // cannot swallow a demand that crossed the previous threshold.
        let threshold = self.count_threshold.load(Ordering::Acquire);
        let count = add(&self.count, 1);
        self.request(count >= threshold)
    }

    pub(crate) fn growth(&self, bytes: usize) -> bool {
        if bytes == 0 {
            return false;
        }
        let threshold = self.byte_threshold.load(Ordering::Acquire);
        let total = add(&self.bytes, bytes);
        self.request(total >= threshold)
    }

    pub(crate) fn begin_round(&self) -> bool {
        self.count.swap(0, Ordering::AcqRel);
        self.bytes.swap(0, Ordering::AcqRel);
        // Acquire the preceding producer's latch publication BEFORE rechecking
        // counters. An arrival between reset and latch clear either gets seen
        // here or observes the cleared latch and wakes the worker itself.
        self.requested.swap(false, Ordering::AcqRel);
        self.request(self.due())
    }

    pub(crate) fn finish_round(&self, live_nodes: usize, retained_bytes: usize) -> bool {
        self.count_threshold
            .store(live_nodes.max(MIN_COUNT), Ordering::Release);
        self.byte_threshold
            .store(retained_bytes.max(MIN_BYTES), Ordering::Release);
        // Do NOT clear the latch: an arrival during the scan already owns the
        // next wake. Rechecking also covers a newly lowered threshold.
        self.request(self.due())
    }
}

fn add(counter: &AtomicUsize, delta: usize) -> usize {
    let old = counter
        .fetch_update(Ordering::AcqRel, Ordering::Acquire, |n| {
            Some(n.saturating_add(delta))
        })
        .expect("saturating addition always succeeds");
    old.saturating_add(delta)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Barrier};

    #[test]
    fn few_large_cells_trigger_without_count_threshold() {
        let s = Schedule::new();
        assert!(!s.registration());
        assert!(!s.growth(MIN_BYTES - 1));
        assert!(s.growth(1));
        assert_eq!(s.count.load(Ordering::Acquire), 1);
        assert!(!s.growth(MIN_BYTES), "coalesced while already requested");
    }

    #[test]
    fn allocation_count_trigger_is_preserved() {
        let s = Schedule::new();
        for _ in 1..MIN_COUNT {
            assert!(!s.registration());
        }
        assert!(s.registration());
        assert!(!s.registration());
    }

    #[test]
    fn equal_shrinking_or_uncommitted_growth_has_no_demand() {
        let s = Schedule::new();
        for _ in 0..100 {
            assert!(!s.growth(0));
        }
        assert_eq!(s.bytes.load(Ordering::Acquire), 0);
        assert!(!s.requested.load(Ordering::Acquire));
    }

    #[test]
    fn thresholds_scale_with_live_graph_and_accounted_bytes() {
        let s = Schedule::new();
        assert!(!s.finish_round(MIN_COUNT * 3, MIN_BYTES * 4));
        assert!(!s.growth(MIN_BYTES * 4 - 1));
        assert!(s.growth(1));
        assert!(!s.begin_round());
        assert_eq!(s.bytes.load(Ordering::Acquire), 0);
        assert!(!s.finish_round(0, 0));
        assert!(s.growth(MIN_BYTES));
    }

    #[test]
    fn demand_during_round_survives_end_and_threshold_raise() {
        let s = Schedule::new();
        assert!(s.growth(MIN_BYTES));
        assert!(!s.begin_round());
        assert!(s.growth(MIN_BYTES), "arrival while collection is running");
        assert!(!s.finish_round(MIN_COUNT * 8, MIN_BYTES * 8));
        assert!(
            s.requested.load(Ordering::Acquire),
            "next round remains queued"
        );
        assert!(!s.begin_round());
        assert!(!s.requested.load(Ordering::Acquire));
    }

    #[test]
    fn lowering_threshold_rechecks_accumulated_growth() {
        let s = Schedule::new();
        assert!(!s.finish_round(0, MIN_BYTES * 8));
        assert!(!s.begin_round());
        assert!(!s.growth(MIN_BYTES * 2));
        assert!(s.finish_round(0, 0));
        assert!(s.requested.load(Ordering::Acquire));
    }

    #[test]
    fn concurrent_growth_has_one_wake_per_round() {
        let s = Arc::new(Schedule::new());
        for _ in 0..16 {
            assert!(!s.begin_round());
            let barrier = Arc::new(Barrier::new(9));
            let workers: Vec<_> = (0..8)
                .map(|_| {
                    let s = s.clone();
                    let barrier = barrier.clone();
                    std::thread::spawn(move || {
                        barrier.wait();
                        s.growth(MIN_BYTES)
                    })
                })
                .collect();
            barrier.wait();
            let wakes = workers
                .into_iter()
                .map(|t| usize::from(t.join().unwrap()))
                .sum::<usize>();
            assert_eq!(wakes, 1);
            assert_eq!(s.bytes.load(Ordering::Acquire), MIN_BYTES * 8);
            assert!(!s.finish_round(0, 0));
            assert!(s.requested.load(Ordering::Acquire));
        }
    }

    #[test]
    fn saturated_accounting_cannot_wrap_and_hide_pressure() {
        let s = Schedule::new();
        assert!(s.growth(usize::MAX));
        assert!(!s.growth(1));
        assert_eq!(s.bytes.load(Ordering::Acquire), usize::MAX);
        assert!(!s.begin_round());
        assert!(s.growth(MIN_BYTES));
    }
}
