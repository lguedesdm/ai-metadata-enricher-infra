# Students Table — Business Context

## Overview

The **Students** table is the authoritative source of student demographic and enrollment information within the institution's Student Information System (SIS). It contains official enrollment records for both active and historical students across all campuses and programs.

## Business Definition

This table represents the institution's official student roster. Each row corresponds to a unique student identified by `StudentId`. The table is maintained by the Registrar's Office and updated through the enrollment management workflow.

## Key Columns

| Column | Business Meaning |
|--------|-----------------|
| `StudentId` | Unique institutional identifier assigned at first enrollment. Format: numeric, auto-generated. This is the primary key used across all downstream systems (financial aid, housing, grades). |
| `FirstName`, `LastName` | Legal name as recorded in the admission application. Updated only through a formal Name Change Request process. |
| `DateOfBirth` | Used for identity verification and age-based eligibility checks (e.g., FERPA compliance, housing eligibility). |
| `EnrollmentDate` | The date of the student's **first official enrollment** in any program at the institution. This is NOT the same as the date they applied or were admitted. |
| `RegistrationDate` | The date the student record was **created in the system**. In most cases this matches `EnrollmentDate`, but for records migrated from legacy systems, `RegistrationDate` may reflect the migration date rather than actual enrollment. |
| `Status` | Current enrollment status: `Active`, `Inactive`, `Graduated`, `Withdrawn`, `On Leave`. Transitions are governed by the Enrollment Lifecycle policy. |
| `CampusId` | Foreign key to the Campuses table. Represents the student's primary campus assignment. |
| `ProgramId` | Foreign key to the Programs table. Represents the student's declared program of study. |

## Business Rules

1. **EnrollmentDate** represents the first official enrollment in the institution. It is immutable once set.
2. **RegistrationDate** may reflect system ingestion date, not actual enrollment. In legacy records imported from the previous SIS (pre-2019), `RegistrationDate` was set to the migration date (2019-06-15) for all migrated students.
3. A student with `Status = Active` must have at least one active enrollment in the current term.
4. `StudentId` is never reused. Withdrawn students retain their ID permanently.

## Known Ambiguities

- In some legacy systems, `RegistrationDate` is used interchangeably with `EnrollmentDate`. Consumers should always prefer `EnrollmentDate` for business reporting.
- The `Status` field is updated asynchronously by a nightly batch process. During the day, a student who has withdrawn may still show as `Active` until the batch runs.

## Related Tables

- `Enrollment` — Individual term-level enrollment records linked by `StudentId`
- `Grades` — Academic performance records linked by `StudentId`
- `StudentFinancials` — Tuition and fee records linked by `StudentId`
- `GuardianContacts` — Parent/guardian information linked by `StudentId`
