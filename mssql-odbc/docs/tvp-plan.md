# Table-Valued Parameter (TVP) Support in mssql-odbc

**Status:** Proposed · **Owner:** mssql-odbc (Rust ODBC driver) · **Consumer:** mssql-python
**Work item:** AB#49353 (TVP support in mssql-odbc)
**Related:** AB#47790 (mssql-odbc parameter matrix) · AB#48177 (mssql-python TVP feature)

---

## 1. Purpose

This is a high-level design for adding SQL Server **table-valued parameter (TVP)** support to
the `mssql-odbc` Rust driver, so that mssql-python can offer TVPs through its synchronous
(ODBC) cursor against **both** ODBC providers it ships.

It is written for two audiences: the **mssql-python team**, to state what the driver will
expose and guarantee; and the **mssql-odbc team**, to record the scope of the work.

The design goal is **behavioral parity with msodbcsql18 at the ODBC surface**. mssql-python
drives TVPs through standard ODBC calls, and those calls must produce identical observable
results whether the active provider is msodbcsql18 or mssql-odbc — with no provider-specific
code path.

---

## 2. Context: two adapters behind one mssql-python contract

mssql-python exposes a single public `TableValuedParameter` value. Behind it, the driver
selects a backend adapter:

| Adapter | Transport | Owner | This document |
| --- | --- | --- | --- |
| Synchronous cursor → ODBC | ODBC → **msodbcsql18** | mssql-python | Not in scope (native TVP support) |
| Synchronous cursor → ODBC | ODBC → **mssql-odbc (Rust)** | **mssql-odbc team** | **In scope** |
| Asynchronous cursor → Rust/TDS | Rust/TDS | Separate owner | Not in scope |

The ODBC adapter is **driver-agnostic**: mssql-python issues the same ODBC sequence
regardless of which driver is loaded. msodbcsql18 supports the SQL Server ODBC TVP contract
natively. This document covers bringing the Rust `mssql-odbc` driver to the same contract, so
the ODBC adapter runs unchanged on it. The asynchronous / Rust-TDS adapter is delivered
separately and is out of scope here.

### 2.1 ODBC call sequence (conceptual)

| # | Flow | Operation |
| --- | --- | --- |
| 1 | App → Driver | Prepare the statement |
| 2 | App → Driver | Describe the TVP parameter |
| 3 | Driver → SQL Server | Request parameter metadata |
| 4 | SQL Server → Driver | Returns `SQL_SS_TABLE` + the table type's three-part name |
| 5 | App → Driver | Read the table type identity |
| 6 | App → Driver | Bind the table parameter (`SQL_SS_TABLE`) with its type name and row count |
| 7 | App → Driver | Set parameter focus to the TVP |
| 8 | App → Driver | Bind each TVP column's values |
| 9 | App → Driver | Restore parameter focus to 0 |
| 10 | App → Driver | Execute |
| 11 | Driver | Assemble the rows and send the TVP |
| 12 | Driver → SQL Server | Send the statement carrying the TVP |
| 13 | SQL Server → Driver | Procedure result set(s) |
| 14 | App → Driver | Fetch the procedure results |

---

## 3. Current state in mssql-odbc

TVP support is **not available today**. The driver recognizes the table type at describe
time, but binding a table parameter and setting parameter focus are rejected, so a TVP
cannot be sent. This work makes the ODBC TVP contract functional end to end.

---

## 4. The ODBC contract mssql-odbc will support

At a high level, mssql-python performs the following, identical to msodbcsql18:

- **Describe** — `SQLDescribeParam` reports `SQL_SS_TABLE` and exposes the table type's
  three-part (catalog / schema / type) name.
- **Bind the TVP** — the parameter is bound as `SQL_SS_TABLE`, input-only, carrying the type
  name and the number of rows (or an empty-table marker).
- **Bind the columns under focus** — parameter focus is set to the TVP, each column's values
  are bound, and focus is then restored.
- **Execute** — the statement runs; procedure result sets are returned through the normal
  fetch path. TVPs are input-only and are never fetched back.

---

## 5. Scope of work

mssql-odbc will add the following capabilities:

- **Expose the table type identity** from describe — report `SQL_SS_TABLE` and the table
  type's three-part name, extending the driver's existing SQL Server user-type-name handling
  to table types.
- **Support the SQL Server TVP descriptor fields** — the type / schema / catalog name and the
  per-column default-value marker.
- **Accept a table parameter** bound as `SQL_SS_TABLE`, validated as input-only and
  non-nullable, with msodbcsql18-compatible diagnostics.
- **Implement parameter focus** so a TVP's constituent columns can be bound and then
  restored to top-level binding.
- **Assemble the bound columns into rows** for transmission, applying the same per-cell
  conversion and null semantics as top-level scalar parameters.
- **Handle empty TVPs and all-NULL columns** correctly.
- **Preserve clean lifecycle and diagnostics** — reset TVP state on cursor close or
  re-prepare; on a bad value, report the offending row and column and keep the connection
  usable.

---

## 6. Out of scope

- **msodbcsql18 TVP support** — native to that driver; owned by mssql-python.
- **Asynchronous / Rust-TDS adapter** — delivered separately.
- **Output or input/output TVPs; fetching TVPs back** — TVPs are input-only by definition.
- **TVPs inside parameter arrays / `executemany`** — a TVP is one logical value, not a batch.
- **`sql_variant` columns within a TVP** — deferred.

---

## 7. Validation

TVP support is validated at the ODBC layer with driver-owned tests and confirmed end to end
against the mssql-python conformance suite:

- Describe returns the table type with its three-part name.
- Bind validation matches msodbcsql18 (input-only, non-nullable, correct diagnostics).
- Execute with mixed column types, embedded and all-NULL values, empty tables,
  schema-qualified names, large values, and multiple TVPs interleaved with scalar parameters.
- The cursor stays usable after a bad TVP value, and the error identifies the row and column.

**Parity gate:** mssql-python's TVP conformance suite (AB#48177) passes against the
mssql-odbc provider with the same expectations it uses for msodbcsql18 — no
provider-specific skips.

---

## 8. Dependencies & open items

- **Work-item tracking** — this work is tracked under AB#49353.

---

## 9. Summary for the mssql-python team

- mssql-odbc will implement the **SQL Server ODBC TVP contract to msodbcsql18 parity**:
  describe reports the table type and its name, the table parameter and its columns bind
  under parameter focus, and the statement executes with the TVP.
- Your ODBC TVP code path will run **unchanged** on mssql-odbc — no provider-specific branch
  or rejection is required once this work lands.
- The asynchronous / Rust-TDS path is owned separately and is not affected by this work.
