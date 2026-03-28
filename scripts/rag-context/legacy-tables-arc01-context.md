# Legacy Tables — ARC01 Series — Business Context

## Overview

Tables prefixed with **ARC01** are legacy artifacts from the institution's original archival system, decommissioned in 2018. These tables were migrated to the current SQL database as-is, without schema normalization or documentation. They are retained for historical reference and regulatory compliance.

## ARC01_TBL_A — Specific Context

### Business Definition

**ARC01_TBL_A** contains legacy or system-generated fields with no clear business meaning. This table was part of the archival module responsible for storing compressed student records before the institution adopted the current SIS.

The original system used auto-generated column names (C01, C02, C03, etc.) and the mapping documentation was lost during the 2018 migration.

### Column Information

| Column | Known Context |
|--------|--------------|
| `C01` | **Not documented.** Likely a foreign key based on value patterns (numeric, non-null). Should not be inferred without context. |
| `C02` | **Not documented.** Contains date-like values in some rows and NULL in others. Format inconsistent (some ISO 8601, some MM/DD/YYYY). |
| `C03` | **Not documented.** Appears to contain encoded or abbreviated text values. Maximum observed length: 50 characters. |
| `ARC_ID` | Auto-generated primary key. Sequential integer. |
| `ARC_TS` | Timestamp of record creation in the archival system. Always UTC. |
| `ARC_SRC` | Source system identifier. Known values: `SIS_V1`, `SIS_V2`, `MANUAL`. |

### Critical Warnings

1. **Columns C01, C02, C03 are not documented and should not be inferred without context.** Any AI-generated description for these columns MUST explicitly state that the business meaning is unknown.
2. **Do not assume** that C01 is a student ID, even if the values appear numeric. The archival system used internal sequence numbers that do not map to current `StudentId` values.
3. **Do not assume** that C02 contains enrollment dates. The date-like values may represent archival timestamps, not business dates.
4. This table is **read-only** in the current system. No application writes to it.
5. The table is retained for **regulatory compliance** (10-year retention requirement). It is scheduled for review in 2028.

### Data Quality Issues

- Approximately 15% of rows have NULL values in C01, C02, and C03 simultaneously.
- The `ARC_SRC` field contains the value `MANUAL` for approximately 200 records that were hand-entered by staff during the migration. These records have lower data quality.
- Character encoding issues exist in C03 for records with `ARC_SRC = 'SIS_V1'` (legacy system used Latin-1, current system uses UTF-8).

### Related Context

- No active application reads from this table.
- It is not joined to any current tables in production queries.
- The Registrar's Office occasionally queries it for historical student record requests (approximately 2-3 times per year).

## General Guidance for ARC01 Tables

- All ARC01 tables follow the same pattern: auto-generated column names, missing documentation, legacy data.
- AI-generated descriptions for ARC01 tables should emphasize the **unknown** nature of the data and avoid speculative interpretations.
- The institution is considering a data archaeology project to reverse-engineer column meanings, but this has not been funded as of 2026.
