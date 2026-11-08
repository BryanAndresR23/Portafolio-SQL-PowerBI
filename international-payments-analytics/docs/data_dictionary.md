# Diccionario de datos / Data dictionary

Todas las tablas viven en la base `InternationalPaymentsAnalytics`. Los datos son **100% ficticios**.
All tables live in the `InternationalPaymentsAnalytics` database. Data is **100% synthetic**.

## Capas / Layers

| Esquema / Schema | Propósito (ES) | Purpose (EN) |
|---|---|---|
| `stg` | Copia exacta de los CSV, todo como texto | Exact copy of the CSV files, everything as text |
| `core` | Modelo limpio, tipado y con restricciones | Clean, typed and constrained model |
| `recon` | Motor y resultados de conciliación | Reconciliation engine and results |
| `rpt` | Vistas en esquema estrella para Power BI | Star-schema views for Power BI |

## core.payment — pagos / payments (48,041 filas / rows)

| Columna / Column | Tipo / Type | ES | EN |
|---|---|---|---|
| `payment_id` | INT (PK) | Identificador del pago | Payment identifier |
| `reference` | CHAR(14) (UQ) | Referencia única `PAYyymmddNNNNN` | Unique reference |
| `customer_id` | CHAR(6) (FK) | Cliente ordenante o beneficiario | Ordering or beneficiary customer |
| `direction` | NVARCHAR(10) | `Inbound` (entra a Ecuador) / `Outbound` (sale) | Money in / money out |
| `payment_type` | NVARCHAR(30) | Remesa, pago a proveedor, servicio de deuda, etc. | Remittance, supplier payment, debt service… |
| `counterparty_country` | CHAR(2) (FK) | País de la contraparte (ISO 3166) | Counterparty country |
| `currency_code` | CHAR(3) (FK) | Moneda del pago (ISO 4217) | Payment currency |
| `amount` | DECIMAL(19,2) | Monto en la moneda original | Amount in original currency |
| `fx_rate_to_usd` | DECIMAL(18,6) | Unidades de moneda por 1 USD en la fecha de creación | Units of currency per 1 USD on creation date |
| `amount_usd` | DECIMAL(19,2) | Monto convertido a USD | Amount converted to USD |
| `fee_usd` | DECIMAL(10,2) | Comisión cobrada (0 si fue rechazado) | Fee charged (0 if rejected) |
| `channel_id` | TINYINT (FK) | Canal: app, banca en línea, agencia, host-to-host, SWIFT | Channel |
| `correspondent_bank_id` | INT (FK) | Banco corresponsal que liquida | Settling correspondent bank |
| `created_at` | DATETIME2 | Fecha y hora de creación | Creation timestamp |
| `settled_at` | DATETIME2 NULL | Fecha y hora de liquidación | Settlement timestamp |
| `status` | NVARCHAR(10) | `Completed`, `Pending`, `Rejected`, `Returned` | Payment status |
| `status_reason` | NVARCHAR(60) NULL | Motivo de rechazo, devolución o pendiente | Rejection / return / pending reason |
| `processing_hours` | computed | Horas entre creación y liquidación | Hours from creation to settlement |

## core.bank_statement_line — estado de cuenta del corresponsal / nostro statement (47,770)

| Columna / Column | Tipo / Type | ES | EN |
|---|---|---|---|
| `statement_line_id` | INT (PK) | Línea del estado de cuenta | Statement line id |
| `bank_id`, `currency_code` | FK | Cuenta nostro (banco + moneda) | Nostro account (bank + currency) |
| `value_date` | DATE | Fecha valor | Value date |
| `amount` | DECIMAL(19,2) | Con signo: + crédito, − débito | Signed: + credit, − debit |
| `reference_text` | NVARCHAR(40) NULL | Referencia en texto libre (puede venir sucia o truncada) | Free-text reference (may be messy or truncated) |
| `description` | NVARCHAR(120) | Descripción del corresponsal | Correspondent description |

## core.customer — clientes / customers (2,500)

| Columna / Column | ES | EN |
|---|---|---|
| `customer_id` | Identificador `C00001` | Identifier |
| `customer_name` | Nombre (persona, empresa o entidad pública ficticia) | Name (fictitious) |
| `customer_type` | `Individual`, `Company`, `Public Entity` | Customer type |
| `segment` | `Retail`, `SME`, `Corporate`, `Government` | Segment |
| `city` | Ciudad en Ecuador | City |
| `onboarding_date` | Fecha de vinculación | Onboarding date |
| `risk_rating` | Riesgo de cumplimiento: `Low`, `Medium`, `High` | Compliance risk rating |

## Tablas de referencia / Reference tables

| Tabla / Table | ES | EN |
|---|---|---|
| `core.currency` | 12 monedas | 12 currencies |
| `core.country` | 16 países con región y moneda local | 16 countries with region and local currency |
| `core.exchange_rate` | Tipo de cambio diario por moneda (unidades por USD) | Daily FX rate per currency (units per USD) |
| `core.correspondent_bank` | 12 bancos corresponsales ficticios | 12 fictitious correspondent banks |
| `core.channel` | 5 canales | 5 channels |
| `core.calendar` | Calendario con número acumulado de días hábiles | Calendar with running business-day number |
| `core.etl_reject` | Filas excluidas en la carga y su motivo | Rows excluded during the load and why |

## recon.match_result — resultado de conciliación / reconciliation result

| Columna / Column | ES | EN |
|---|---|---|
| `item_type` | `Payment`, `Return`, `Statement only` | Item type |
| `ledger_amount` / `statement_amount` | Monto en libros / en el estado de cuenta | Book amount / statement amount |
| `amount_difference`, `days_difference` | Diferencias calculadas | Computed differences |
| `match_rule` | `Reference` o `Amount + date window` | Matching rule used |
| `recon_status` | `Reconciled` / `Exception` | Status |
| `recon_category` | Cuadrado, diferencia de monto, de fecha, faltante, duplicado, cargo no registrado… | Matched, amount / timing difference, missing, duplicate, charge not booked… |

## Reglas de negocio en `rpt` / Business rules in `rpt`

| Regla / Rule | Definición (ES) | Definition (EN) |
|---|---|---|
| SLA | Liquidado a más tardar el siguiente día hábil (T+1) | Settled no later than the next business day (T+1) |
| `business_days_to_settle` | Diferencia de `business_day_number` entre liquidación y creación | Difference of running business-day numbers |
| `net_flow_usd` | + entradas, − salidas | + inbound, − outbound |
| `aging_bucket` | Antigüedad de la excepción al cierre (31-dic-2025) | Exception age at period close |
