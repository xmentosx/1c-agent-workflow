# Source evidence transport

## Purpose

Сохранить точные Unicode-данные и семантику доказательств на границах исходников,
дочерних процессов и JSON между поддерживаемыми PowerShell runtime.

## ADDED Requirements

### Requirement: Source remains compatible with supported PowerShell
Workflow-owned PowerShell source SHALL preserve compatibility with Windows
PowerShell 5.1, including the encoding of non-ASCII source. Detection MUST use
the existing short source-validation route before dependent expensive stages.

#### Scenario: Cyrillic PowerShell source is edited
- **WHEN** a source edit contains non-ASCII strings or paths
- **THEN** both the supported runtime and the source validation interpret the intended characters exactly

### Requirement: Native boundaries preserve exact Unicode
Workflow-owned native transport SHALL preserve stdout, stderr and serialized
arguments exactly for paths containing whitespace and non-ASCII characters.
Decoding MUST follow an explicitly established encoding at the boundary.

#### Scenario: Failed child returns Unicode evidence
- **WHEN** an owned child reports an error and artifacts under a path containing spaces and Cyrillic
- **THEN** surfaced and persisted output retains the original characters and failure evidence remains attributable

### Requirement: Evidence meaning survives runtime serialization
Evidence readers and writers SHALL retain the owner's signed or hashed payload
semantics across supported runtimes. Valid records MUST NOT be classified as
corrupt solely because a reader coerces date strings or formats values differently.
Actual payload changes MUST continue to fail integrity validation.

#### Scenario: Evidence is read by another supported PowerShell version
- **WHEN** an unchanged record contains ISO date strings and a valid owner hash
- **THEN** both supported readers accept the same record and report its original timing and status

#### Scenario: Payload has been modified
- **WHEN** a hashed evidence payload changes without its valid integrity data
- **THEN** the reader rejects the evidence and does not use it to claim qualification
