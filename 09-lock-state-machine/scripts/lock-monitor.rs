// Lock monitor: runs at market open every trading day.
// Checks each ticker's lock state, emits timeouts, and fires pending orders.

use std::collections::HashMap;
use chrono::{Duration, NaiveDate, Utc};
use tokio::sync::mpsc;
use uuid::Uuid;

use crate::events::{LockEvent, LockExpiry, LockTransition, OrderEvent};
use crate::locks::{LockState, LockTable};
use crate::trading_calendar::TradingCalendar;

pub struct LockMonitor {
    locks: LockTable,
    calendar: TradingCalendar,
    lock_event_tx: mpsc::Sender<LockEvent>,
    order_event_tx: mpsc::Sender<OrderEvent>,
}

impl LockMonitor {
    pub fn new(
        locks: LockTable,
        calendar: TradingCalendar,
        lock_event_tx: mpsc::Sender<LockEvent>,
        order_event_tx: mpsc::Sender<OrderEvent>,
    ) -> Self {
        Self { locks, calendar, lock_event_tx, order_event_tx }
    }

    /// Run at market open. Checks timeouts and fires pending orders.
    pub async fn daily_check(&mut self) -> Result<(), LockError> {
        let today = Utc::now().date_naive();

        // Step 1: Advance expired locks
        for (ticker, state) in self.locks.iter() {
            if let Some(expiry) = state.lock_expiry() {
                if today > expiry {
                    let new_state = match state {
                        LockState::LongLocked { .. } => LockState::LongUnlocked,
                        LockState::FlatLocked { .. } => LockState::FlatUnlocked,
                        other => other.clone(),
                    };

                    self.locks.set(ticker, new_state.clone());

                    let event = LockTransition {
                        event_id: Uuid::new_v4(),
                        timestamp: Utc::now(),
                        ticker: ticker.clone(),
                        from_state: state.name().to_string(),
                        to_state: new_state.name().to_string(),
                        trigger_order_id: None,
                    };

                    self.lock_event_tx.send(LockEvent::Transition(event)).await?;
                }
            }
        }

        // Step 2: Fire pending orders whose lock expired
        let pending = self.locks.pending_orders_due(today).await?;
        for order in pending {
            let decision = self.revalidate_signal(&order).await?;
            match decision {
                RevalidationDecision::Fire => {
                    self.order_event_tx
                        .send(OrderEvent::Submit(order.into_submit()))
                        .await?;
                    self.locks.mark_pending_fired(&order.pending_id).await?;
                }
                RevalidationDecision::Cancel(reason) => {
                    self.locks
                        .mark_pending_cancelled(&order.pending_id, &reason)
                        .await?;
                }
                RevalidationDecision::Extend(new_expiry) => {
                    self.locks
                        .extend_pending(&order.pending_id, new_expiry)
                        .await?;
                }
            }
        }

        Ok(())
    }

    async fn revalidate_signal(
        &self,
        order: &PendingOrder,
    ) -> Result<RevalidationDecision, LockError> {
        // Fetch the latest signal for this ticker
        let latest = self.locks.latest_signal(&order.ticker).await?;
        let snapshot: SignalSnapshot = serde_json::from_str(&order.signal_snapshot)?;

        // Comparison rules (see PENDING-ORDERS.md §4)
        if latest.q_50.signum() != snapshot.q_50.signum() {
            return Ok(RevalidationDecision::Cancel("signal_reversed".into()));
        }
        if latest.q_50.abs() < 0.5 * snapshot.q_50.abs() {
            return Ok(RevalidationDecision::Cancel("signal_weakened".into()));
        }
        if latest.veto_active {
            return Ok(RevalidationDecision::Cancel("veto_triggered".into()));
        }
        if latest.regime_factor == 0.0 {
            return Ok(RevalidationDecision::Cancel("regime_crisis".into()));
        }

        // Check if the lock has extended (e.g., a new same-direction buy)
        let current_lock = self.locks.get(&order.ticker);
        if let Some(expiry) = current_lock.lock_expiry() {
            if expiry > order.earliest_execution {
                return Ok(RevalidationDecision::Extend(expiry));
            }
        }

        Ok(RevalidationDecision::Fire)
    }
}

pub enum RevalidationDecision {
    Fire,
    Cancel(String),
    Extend(NaiveDate),
}

pub struct PendingOrder {
    pub pending_id: Uuid,
    pub ticker: String,
    pub side: Side,
    pub target_quantity: i64,
    pub earliest_execution: NaiveDate,
    pub signal_snapshot: String,
    pub created_at: chrono::DateTime<Utc>,
    pub status: String,
}