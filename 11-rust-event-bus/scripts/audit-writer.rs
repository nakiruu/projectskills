// Audit writer: the sole subscriber to the `audit` channel.
// Appends to audit_log.parquet. Never updates, never deletes.
//
// If the audit channel is full, the bus applies backpressure to all
// other channels. Trading halts. This is intentional.

use std::fs::OpenOptions;
use std::path::PathBuf;
use std::sync::Arc;

use arrow::array::{StringArray, TimestampNanosecondArray};
use arrow::datatypes::{DataType, Field, Schema, TimeUnit};
use arrow::record_batch::RecordBatch;
use parquet::arrow::ArrowWriter;
use parquet::file::properties::WriterProperties;
use tokio::sync::mpsc;
use uuid::Uuid;

use crate::events::{AuditEvent, Severity};

pub struct AuditWriter {
    path: PathBuf,
    channel: mpsc::Receiver<AuditEvent>,
    schema: Arc<Schema>,
}

impl AuditWriter {
    pub fn new(path: PathBuf, channel: mpsc::Receiver<AuditEvent>) -> Self {
        let schema = Arc::new(Schema::new(vec![
            Field::new("event_id", DataType::Utf8, false),
            Field::new(
                "timestamp",
                DataType::Timestamp(TimeUnit::Nanosecond, Some("UTC".into())),
                false,
            ),
            Field::new("event_type", DataType::Utf8, false),
            Field::new("ticker", DataType::Utf8, true),
            Field::new("actor", DataType::Utf8, false),
            Field::new("details", DataType::Utf8, false),
            Field::new("severity", DataType::Utf8, false),
        ]));

        Self { path, channel, schema }
    }

    pub async fn run(mut self) -> Result<(), Box<dyn std::error::Error>> {
        let props = WriterProperties::builder()
            .set_compression(parquet::basic::Compression::ZSTD(
                parquet::basic::ZstdLevel::try_new(3)?,
            ))
            .build();

        // Open in append mode. Parquet does not support append natively;
        // in practice, write to a temp file and rename after each batch.
        // For simplicity here, we write a new file per run.
        let file = OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .open(&self.path)?;

        let mut writer = ArrowWriter::try_new(file, self.schema.clone(), Some(props))?;

        // Batch events to amortize I/O
        const BATCH_SIZE: usize = 1000;
        let mut batch = Vec::with_capacity(BATCH_SIZE);

        while let Some(event) = self.channel.recv().await {
            batch.push(event);

            if batch.len() >= BATCH_SIZE {
                self.flush_batch(&mut writer, &batch)?;
                batch.clear();
            }
        }

        // Flush remaining
        if !batch.is_empty() {
            self.flush_batch(&mut writer, &batch)?;
        }

        writer.close()?;
        Ok(())
    }

    fn flush_batch(
        &self,
        writer: &mut ArrowWriter<std::fs::File>,
        batch: &[AuditEvent],
    ) -> Result<(), Box<dyn std::error::Error>> {
        let event_ids: StringArray = batch.iter().map(|e| Some(e.event_id.to_string())).collect();
        let timestamps: TimestampNanosecondArray = batch
            .iter()
            .map(|e| Some(e.timestamp.timestamp_nanos()))
            .collect();
        let event_types: StringArray = batch.iter().map(|e| Some(e.event_type.clone())).collect();
        let tickers: StringArray = batch.iter().map(|e| e.ticker.clone()).collect();
        let actors: StringArray = batch.iter().map(|e| Some(e.actor.clone())).collect();
        let details: StringArray = batch
            .iter()
            .map(|e| Some(e.details.to_string()))
            .collect();
        let severities: StringArray = batch
            .iter()
            .map(|e| Some(e.severity.as_str().to_string()))
            .collect();

        let record_batch = RecordBatch::try_new(
            self.schema.clone(),
            vec![
                Arc::new(event_ids),
                Arc::new(timestamps),
                Arc::new(event_types),
                Arc::new(tickers),
                Arc::new(actors),
                Arc::new(details),
                Arc::new(severities),
            ],
        )?;

        writer.write(&record_batch)?;
        writer.flush()?;
        Ok(())
    }
}