# EnrollmentAudit Table — Business Context

## Overview

The **EnrollmentAudit** table is an audit trail that captures every change made to student enrollment records. It is used for compliance reporting, dispute resolution, and institutional accreditation reviews.

## Business Definition

Every time an enrollment record is created, modified, or deleted, a corresponding row is written to `EnrollmentAudit`. This table is append-only — rows are never updated or deleted. It serves as the institution's official record of enrollment lifecycle events.

## Key Columns

| Column | Business Meaning |
|--------|-----------------|
| `AuditId` | Unique identifier for the audit entry. Auto-generated, sequential. |
| `StudentId` | The student whose enrollment was affected. Foreign key to `Students`. |
| `EnrollmentId` | The specific enrollment record that changed. Foreign key to `Enrollment`. |
| `Action` | The type of change: `INSERT` (new enrollment), `UPDATE` (status change), `DELETE` (enrollment removed). |
| `PreviousStatus` | The enrollment status before the change. NULL for `INSERT` actions. |
| `NewStatus` | The enrollment status after the change. NULL for `DELETE` actions. |
| `ChangedBy` | The user or system account that performed the change. Format: `user@institution.edu` or `SYSTEM:batch_process_name`. |
| `ChangedAt` | Timestamp of the change in UTC. This is the authoritative timestamp for audit purposes. |
| `Reason` | Free-text field describing why the change was made. Required for `DELETE` actions per institutional policy. |
| `TermId` | The academic term associated with the enrollment. Format: `YYYY-TERM` (e.g., `2026-SPRING`). |

## Business Rules

1. This table is **append-only**. No UPDATE or DELETE operations are permitted on audit records.
2. Every enrollment change in the `Enrollment` table MUST generate a corresponding `EnrollmentAudit` row. Missing audit records indicate a system integrity issue.
3. `DELETE` actions require a non-empty `Reason` field per compliance policy (FERPA audit requirements).
4. `ChangedBy` must identify either a human user (email format) or a system process (`SYSTEM:` prefix). Anonymous changes are not permitted.
5. `ChangedAt` is always in UTC regardless of the user's timezone.

## Compliance Context

- This table is the primary data source for **FERPA compliance audits**.
- It is also used during **accreditation reviews** to demonstrate enrollment governance.
- Retention policy: audit records are retained for **7 years** from `ChangedAt` date.
- The table is classified as **Confidential** under the institution's data classification policy.

## Known Considerations

- High-volume table: approximately 50,000 new rows per enrollment period (twice per year).
- The `Reason` field is free-text and may contain inconsistent formatting. It is not suitable for automated categorization without NLP processing.
- Historical records (pre-2020) may have `ChangedBy = 'SYSTEM:legacy_import'` due to bulk migration from the previous SIS.

## Related Tables

- `Enrollment` — The source table whose changes are audited
- `Students` — Student identity context
- `Semesters` — Term/period reference for `TermId`
