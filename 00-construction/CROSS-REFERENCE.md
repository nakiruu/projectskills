# Invariant → Skill Cross-Reference

When an invariant changes, these skills must be updated in the same PR.

| Invariant (§)              | Implementing skills                                        |
|----------------------------|------------------------------------------------------------|
| §1 Five-day lock           | 09-lock-state-machine, 10-execution-schwab, 11-rust-event-bus |
| §2 Point-in-time           | 01-data-ingestion, 02-panel-construction, 13-parquet-lake  |
| §3 No lookahead            | 02-panel-construction, 14-backtest-protocol                |
| §4 Language boundaries     | 12-julia-rust-bridge, 15-ai-dev-workflow                   |
| §5 Schema immutability     | 13-parquet-lake                                            |
| §6 Execution constraints   | 08-portfolio-optimization, 10-execution-schwab             |
| §7 Veto vs. conviction     | 07-fundamental-overlay, 08-portfolio-optimization          |
| §8 Audit log               | 11-rust-event-bus, 10-execution-schwab                     |
| §9 Output contracts        | 03-gspqr-model, 04-tcp-calibration, 05-evt-tails, 12-julia-rust-bridge |
| §10 Amendment process      | 15-ai-dev-workflow                                         |

## Reverse Index

Skills with no constitutional dependency (pure implementation detail):

- 06-regime-detection

If a skill appears in neither table, it is unclassified. Classify it or
delete it.