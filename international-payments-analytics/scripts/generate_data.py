#!/usr/bin/env python3
"""
Synthetic data generator - International Payments Analytics
===========================================================

Builds a fictitious dataset for a bank in Ecuador that sends and receives
international payments through correspondent banks (nostro accounts).

* Every name, SWIFT code, customer and amount is fictitious.
* Only the Python standard library is used.
* The output is reproducible: the same --seed always gives the same files.
* A few data-quality problems are injected on purpose (extra spaces,
  inconsistent casing, duplicated rows, test records) so the SQL layer
  has real cleaning work to do.
* A few operational events are simulated so the analysis has something
  to discover (see SCENARIO EVENTS below).

Usage:
    python scripts/generate_data.py
    python scripts/generate_data.py --seed 7 --out data/raw
"""

from __future__ import annotations

import argparse
import csv
import math
import random
from bisect import bisect_left
from datetime import date, datetime, time, timedelta
from itertools import accumulate
from pathlib import Path

START = date(2024, 1, 1)
END = date(2025, 12, 31)
TARGET_PAYMENTS = 48_000

# SCENARIO EVENTS -----------------------------------------------------------
# 1. The CNY correspondent suffers settlement delays in Aug-Sep 2025.
CNY_DELAY = (date(2025, 8, 1), date(2025, 9, 30))
# 2. A mobile-app release breaks beneficiary validation in Apr-May 2025,
#    so many outbound personal transfers are rejected.
MOBILE_BUG = (date(2025, 4, 1), date(2025, 5, 31))

# code, name, units per USD at START, daily volatility, yearly drift
CURRENCIES = [
    ("USD", "US Dollar", 1.0, 0.0, 0.0),
    ("EUR", "Euro", 0.92, 0.0035, -0.02),
    ("GBP", "Pound Sterling", 0.79, 0.0035, -0.01),
    ("CHF", "Swiss Franc", 0.88, 0.0035, -0.02),
    ("CAD", "Canadian Dollar", 1.35, 0.0030, 0.02),
    ("JPY", "Japanese Yen", 148.0, 0.0050, 0.03),
    ("CNY", "Chinese Yuan", 7.15, 0.0015, 0.01),
    ("MXN", "Mexican Peso", 17.2, 0.0060, 0.06),
    ("COP", "Colombian Peso", 3950.0, 0.0060, 0.04),
    ("PEN", "Peruvian Sol", 3.72, 0.0025, 0.00),
    ("CLP", "Chilean Peso", 900.0, 0.0050, 0.03),
    ("BRL", "Brazilian Real", 4.95, 0.0065, 0.08),
]
ZERO_DECIMALS = {"JPY", "CLP", "COP"}

COUNTRIES = [
    ("EC", "Ecuador", "Latin America", "USD"),
    ("US", "United States", "North America", "USD"),
    ("CA", "Canada", "North America", "CAD"),
    ("MX", "Mexico", "Latin America", "MXN"),
    ("PA", "Panama", "Latin America", "USD"),
    ("CO", "Colombia", "Latin America", "COP"),
    ("PE", "Peru", "Latin America", "PEN"),
    ("CL", "Chile", "Latin America", "CLP"),
    ("BR", "Brazil", "Latin America", "BRL"),
    ("ES", "Spain", "Europe", "EUR"),
    ("IT", "Italy", "Europe", "EUR"),
    ("DE", "Germany", "Europe", "EUR"),
    ("GB", "United Kingdom", "Europe", "GBP"),
    ("CH", "Switzerland", "Europe", "CHF"),
    ("CN", "China", "Asia", "CNY"),
    ("JP", "Japan", "Asia", "JPY"),
]
COUNTRY_CCY = {c[0]: c[3] for c in COUNTRIES}

# bank_id, name, SWIFT/BIC (fictitious), country, currencies held (nostro)
BANKS = [
    (1, "Atlantic Clearing Bank", "ATCLUS3N", "US", ["USD"]),
    (2, "Liberty Federal Trust", "LBFTUS3N", "US", ["USD"]),
    (3, "Euro Meridian Bank", "EUMRDEFF", "DE", ["EUR"]),
    (4, "Iberia Commerce Bank", "IBCOESMM", "ES", ["EUR"]),
    (5, "Thames Settlement Bank", "THSTGB2L", "GB", ["GBP"]),
    (6, "Alpine Private Bank", "ALPBCHZZ", "CH", ["CHF"]),
    (7, "Maple Leaf Clearing", "MPLCCATT", "CA", ["CAD"]),
    (8, "Pacific Rim Banking Corp", "PRBCJPJT", "JP", ["JPY"]),
    (9, "Silk Road Trade Bank", "SRTBCNSH", "CN", ["CNY"]),
    (10, "Aztec Capital Bank", "AZCBMXMM", "MX", ["MXN"]),
    (11, "Andean Regional Bank", "ANRBCOBB", "CO", ["COP", "PEN", "CLP"]),
    (12, "Cruzeiro Commercial Bank", "CRZCBRSP", "BR", ["BRL"]),
]
BANK_BY_CCY = {}
for _b in BANKS:
    for _c in _b[4]:
        BANK_BY_CCY.setdefault(_c, _b[0])

CHANNELS = ["Mobile App", "Online Banking", "Branch", "Host-to-Host", "SWIFT Inbound"]

# Median settlement time in hours by currency (before other factors).
MEDIAN_HOURS = {
    "USD": 3, "CAD": 6, "EUR": 8, "GBP": 8, "CHF": 10, "MXN": 10,
    "PEN": 14, "COP": 14, "CLP": 16, "BRL": 26, "JPY": 22, "CNY": 20,
}

SEASON_REMIT = {1: .85, 2: .9, 5: 1.3, 6: 1.05, 9: .95, 11: 1.05, 12: 1.35}
SEASON_TRADE = {1: .85, 2: .9, 10: 1.1, 11: 1.15, 12: 1.1}
SEASON_PERSONAL = {1: .9, 7: 1.2, 8: 1.25, 12: 1.15}

FLOWS = {
    "remit_in": dict(
        direction="Inbound", payment_type="Family Remittance", share=.42,
        segments={"Retail": 1.0},
        countries={"US": .55, "ES": .24, "IT": .12, "CA": .03, "CL": .03, "MX": .03},
        median=350, sigma=.65, lo=50, hi=6_000, weekend=.55, hours=(6, 22),
        local_ccy=.5, season=SEASON_REMIT),
    "export_in": dict(
        direction="Inbound", payment_type="Export Proceeds", share=.14,
        segments={"SME": .6, "Corporate": .4},
        countries={"US": .3, "DE": .1, "ES": .08, "IT": .05, "GB": .06, "CN": .08,
                   "JP": .05, "CO": .07, "PE": .06, "CL": .05, "MX": .04, "BR": .03, "CA": .03},
        median=24_000, sigma=1.0, lo=1_000, hi=2_500_000, weekend=.05, hours=(7, 18),
        local_ccy=.55, season=SEASON_TRADE),
    "invest_in": dict(
        direction="Inbound", payment_type="Investment", share=.03,
        segments={"Corporate": .8, "Government": .2},
        countries={"US": .45, "PA": .2, "CH": .15, "GB": .1, "ES": .1},
        median=150_000, sigma=1.0, lo=10_000, hi=20_000_000, weekend=.02, hours=(8, 17),
        local_ccy=.35, season={}),
    "trade_out": dict(
        direction="Outbound", payment_type="Supplier Payment", share=.24,
        segments={"SME": .6, "Corporate": .4},
        countries={"CN": .28, "US": .25, "DE": .07, "ES": .05, "IT": .04, "JP": .05, "CO": .06,
                   "PE": .05, "MX": .05, "BR": .04, "CL": .03, "GB": .02, "CH": .01},
        median=18_000, sigma=1.1, lo=500, hi=3_000_000, weekend=.08, hours=(8, 18),
        local_ccy=.55, season=SEASON_TRADE),
    "personal_out": dict(
        direction="Outbound", payment_type="Personal Transfer", share=.155,
        segments={"Retail": 1.0},
        countries={"US": .4, "ES": .2, "IT": .05, "CO": .1, "PE": .08, "CL": .05,
                   "MX": .05, "GB": .03, "CA": .04},
        median=1_200, sigma=.8, lo=100, hi=50_000, weekend=.5, hours=(7, 23),
        local_ccy=.4, season=SEASON_PERSONAL),
    "debt_out": dict(
        direction="Outbound", payment_type="Debt Service", share=.015,
        segments={"Government": 1.0},
        countries={"US": .5, "DE": .15, "ES": .1, "JP": .15, "CN": .1},
        median=2_500_000, sigma=.9, lo=100_000, hi=80_000_000, weekend=0.0, hours=(9, 15),
        local_ccy=.6, season={}),
}

CITIES = {"Guayaquil": .32, "Quito": .30, "Cuenca": .10, "Ambato": .05, "Manta": .05,
          "Machala": .05, "Loja": .04, "Santo Domingo": .04, "Riobamba": .03, "Ibarra": .02}

FIRST_NAMES = [
    "María", "José", "Luis", "Ana", "Carlos", "Rosa", "Jorge", "Lucía", "Diego", "Carmen",
    "Andrés", "Gabriela", "Fernando", "Daniela", "Miguel", "Paola", "Juan", "Verónica", "Pedro",
    "Sofía", "Ricardo", "Valeria", "Javier", "Patricia", "Santiago", "Mónica", "Pablo", "Elena",
    "Marco", "Isabel", "Esteban", "Camila", "Héctor", "Diana", "Raúl", "Andrea", "Fabián",
    "Natalia", "Óscar", "Lorena"]
LAST_NAMES = [
    "Andrade", "Benítez", "Cevallos", "Delgado", "Espinoza", "Flores", "García", "Guerrero",
    "Herrera", "Jaramillo", "León", "López", "Mendoza", "Morales", "Naranjo", "Ortiz", "Paredes",
    "Pérez", "Quiroga", "Ramírez", "Salazar", "Sánchez", "Torres", "Vásquez", "Villacís",
    "Zambrano", "Cárdenas", "Chávez", "Montenegro", "Reyes", "Castillo", "Vega", "Suárez",
    "Mora", "Calderón", "Navarrete", "Proaño", "Yánez", "Erazo", "Bravo"]
COMPANY_PREFIX = [
    "Comercial", "Importadora", "Exportadora", "Distribuidora", "Industrias", "Agrícola",
    "Inversiones", "Corporación", "Textiles", "Florícola", "Camaronera", "Constructora",
    "Farmacéutica", "Tecnología", "Logística"]
COMPANY_CORE = [
    "Andina", "del Pacífico", "Austral", "Equinoccial", "del Valle", "Sierra Norte", "Costa Azul",
    "Los Ríos", "del Litoral", "Cordillera", "Horizonte", "Mitad del Mundo", "Puerto Nuevo",
    "Volcán", "Río Verde", "Cumbre", "Bahía", "Nevado", "Estrella", "Cóndor"]
COMPANY_SUFFIX = ["S.A.", "Cía. Ltda.", "S.A.S."]
PUBLIC_SECTORS = ["Infraestructura", "Salud", "Educación", "Energía", "Transporte", "Agua"]

REJECT_REASONS_OUT = {"Compliance screening hold": .3, "Invalid beneficiary account": .3,
                      "Insufficient funds": .25, "Incomplete beneficiary data": .15}
REJECT_REASONS_IN = {"Compliance screening hold": .5, "Invalid beneficiary account": .5}
RETURN_REASONS = {"Beneficiary account closed": .45, "Beneficiary name mismatch": .35,
                  "Account not found at beneficiary bank": .2}


class Generator:
    def __init__(self, seed: int):
        self.rng = random.Random(seed)
        self.days = [START + timedelta(days=i) for i in range((END - START).days + 1)]

    # ---------------------------------------------------------------- helpers
    def pick(self, weights: dict):
        return self.rng.choices(list(weights), list(weights.values()))[0]

    def lognormal(self, median, sigma, lo, hi):
        return min(hi, max(lo, median * math.exp(self.rng.gauss(0, sigma))))

    def poisson(self, lam):
        if lam > 30:
            return max(0, round(self.rng.gauss(lam, math.sqrt(lam))))
        limit, k, p = math.exp(-lam), 0, 1.0
        while True:
            p *= self.rng.random()
            if p <= limit:
                return k
            k += 1

    @staticmethod
    def add_business_days(d: date, n: int) -> date:
        while n > 0:
            d += timedelta(days=1)
            if d.weekday() < 5:
                n -= 1
        return d

    # ------------------------------------------------------------ fx rates
    def build_rates(self):
        rates = {}
        for code, _name, base, vol, drift in CURRENCIES:
            x = math.log(base)
            for i, d in enumerate(self.days):
                if code != "USD" and i > 0 and d.weekday() < 5:
                    target = math.log(base) + drift * i / 365
                    x += 0.03 * (target - x) + self.rng.gauss(0, vol)
                rates[(d, code)] = 1.0 if code == "USD" else round(math.exp(x), 6)
        self.rates = rates

    # ----------------------------------------------------------- customers
    def build_customers(self):
        rng = self.rng
        counts = {"Government": 20, "Corporate": 220, "SME": 400, "Retail": 1_860}
        segs = [s for s, n in counts.items() for _ in range(n)]
        rng.shuffle(segs)
        risk_by_seg = {
            "Retail": {"Low": .72, "Medium": .23, "High": .05},
            "SME": {"Low": .6, "Medium": .3, "High": .1},
            "Corporate": {"Low": .7, "Medium": .25, "High": .05},
            "Government": {"Low": .8, "Medium": .2},
        }
        gov_n = 0
        customers = []
        for i, seg in enumerate(segs, start=1):
            if seg == "Retail":
                ctype = "Individual"
                name = f"{rng.choice(FIRST_NAMES)} {rng.choice(LAST_NAMES)} {rng.choice(LAST_NAMES)}"
                weight = math.exp(rng.gauss(0, 1.0))
            elif seg == "Government":
                gov_n += 1
                ctype = "Public Entity"
                name = f"Entidad Pública {rng.choice(PUBLIC_SECTORS)} {gov_n:02d}"
                weight = math.exp(rng.gauss(0, .8))
            else:
                ctype = "Company"
                name = (f"{rng.choice(COMPANY_PREFIX)} {rng.choice(COMPANY_CORE)} "
                        f"{rng.choice(COMPANY_SUFFIX)}")
                weight = math.exp(rng.gauss(0, 1.3))

            if seg == "Government":
                onboard = date(2012, 1, 1) + timedelta(days=rng.randint(0, 3_200))
            elif rng.random() < .82:
                onboard = date(2012, 1, 1) + timedelta(days=rng.randint(0, (date(2023, 12, 31) - date(2012, 1, 1)).days))
            else:
                onboard = START + timedelta(days=rng.randint(0, (date(2025, 11, 30) - START).days))

            customers.append(dict(
                customer_id=f"C{i:05d}", customer_name=name, customer_type=ctype, segment=seg,
                city=self.pick(CITIES), onboarding_date=onboard,
                risk_rating=self.pick(risk_by_seg[seg]), weight=weight))
        self.customers = customers

        self.by_segment = {}
        for seg in counts:
            members = [c for c in customers if c["segment"] == seg]
            cum = list(accumulate(c["weight"] for c in members))
            fallback = [c for c in members if c["onboarding_date"] < START]
            self.by_segment[seg] = (members, cum, fallback)

    def pick_customer(self, seg, d):
        members, cum, fallback = self.by_segment[seg]
        for _ in range(20):
            c = members[bisect_left(cum, self.rng.random() * cum[-1])]
            if c["onboarding_date"] <= d:
                return c
        return self.rng.choice(fallback)

    # ------------------------------------------------------------ payments
    def pick_channel(self, flow_key, seg, d):
        if FLOWS[flow_key]["direction"] == "Inbound":
            return "SWIFT Inbound"
        if flow_key == "debt_out":
            return "Host-to-Host"
        if flow_key == "trade_out":
            if seg == "Corporate":
                return self.pick({"Host-to-Host": .6, "Online Banking": .35, "Branch": .05})
            return self.pick({"Online Banking": .7, "Branch": .2, "Host-to-Host": .1})
        t = (d - START).days / len(self.days)          # mobile adoption grows over time
        mobile, online = .35 + .2 * t, .40 - .1 * t
        return self.pick({"Mobile App": mobile, "Online Banking": online, "Branch": 1 - mobile - online})

    def pick_bank(self, ccy, flow_key, country):
        if ccy == "USD":
            if flow_key in ("debt_out", "invest_in"):
                return 2
            return 1 if self.rng.random() < .65 else 2
        if ccy == "EUR":
            if country == "ES":
                return 4 if self.rng.random() < .8 else 3
            return 3 if self.rng.random() < .8 else 4
        return BANK_BY_CCY[ccy]

    def fee(self, flow_key, channel, amount_usd):
        if flow_key == "remit_in":
            return 2.50 if amount_usd < 200 else 4.00
        if flow_key in ("export_in", "invest_in"):
            return min(150, max(10, round(amount_usd * .001, 2)))
        if flow_key == "trade_out":
            return min(350, max(25, round(amount_usd * .0015, 2))) + (10 if channel == "Branch" else 0)
        if flow_key == "personal_out":
            base = {"Mobile App": 12, "Online Banking": 18, "Branch": 30}[channel]
            return round(base + max(0, amount_usd - 10_000) * .0005, 2)
        return 75.0  # debt service

    def settle_time(self, created, ccy, direction, channel, risk, amount_usd):
        h = MEDIAN_HOURS[ccy] * math.exp(self.rng.gauss(0, .7))
        if direction == "Inbound":
            h *= .8
        h *= {"Host-to-Host": .7, "Branch": 1.3}.get(channel, 1.0)
        h *= {"High": 1.8, "Medium": 1.15}.get(risk, 1.0)
        if amount_usd > 1_000_000:
            h *= 1.5
        if ccy == "CNY" and CNY_DELAY[0] <= created.date() <= CNY_DELAY[1]:
            h *= 3.0
        settled = created + timedelta(hours=max(h, .25))
        if settled.weekday() >= 5:                     # value dates are business days
            monday = settled.date() + timedelta(days=7 - settled.weekday())
            settled = datetime.combine(monday, time(9)) + timedelta(minutes=self.rng.randint(0, 120))
        return settled.replace(microsecond=0)

    def status(self, flow_key, direction, channel, risk, d):
        rng = self.rng
        p_reject = .012 + {"High": .05, "Medium": .008}.get(risk, 0)
        if flow_key in ("trade_out", "personal_out"):
            p_reject += .006
        if channel == "Mobile App" and MOBILE_BUG[0] <= d <= MOBILE_BUG[1] and rng.random() < .11:
            return "Rejected", "Incomplete beneficiary data"
        if rng.random() < p_reject:
            if risk == "High" and rng.random() < .6:
                return "Rejected", "Compliance screening hold"
            return "Rejected", self.pick(REJECT_REASONS_OUT if direction == "Outbound" else REJECT_REASONS_IN)
        if rng.random() < (.012 if direction == "Outbound" else .006):
            return "Returned", self.pick(RETURN_REASONS)
        if rng.random() < .0015:
            return "Pending", "Awaiting compliance review"
        return "Completed", ""

    def build_payments(self):
        rng = self.rng
        weekday_factor = [1.1, 1.05, 1.0, 1.0, 1.1]
        n_days = len(self.days)
        lam = []
        for i, d in enumerate(self.days):
            growth = 1 + .20 * i / 365
            row = {}
            for key, f in FLOWS.items():
                w = weekday_factor[d.weekday()] if d.weekday() < 5 else f["weekend"]
                row[key] = f["share"] * w * f["season"].get(d.month, 1.0) * growth
            lam.append(row)
        scale = TARGET_PAYMENTS / sum(sum(r.values()) for r in lam)

        payments = []
        for i, d in enumerate(self.days):
            for key, f in FLOWS.items():
                for _ in range(self.poisson(lam[i][key] * scale)):
                    payments.append(self.make_payment(d, key, f))
        payments.sort(key=lambda p: p["created_at"])
        for n, p in enumerate(payments, start=1):
            p["payment_id"] = n
            p["reference"] = f"PAY{p['created_at']:%y%m%d}{n:05d}"
        self.payments = payments
        assert n_days == len(lam)

    def make_payment(self, d, key, f):
        rng = self.rng
        seg = self.pick(f["segments"])
        cust = self.pick_customer(seg, d)
        country = self.pick(f["countries"])
        local = COUNTRY_CCY[country]
        ccy = local if local != "USD" and rng.random() < f["local_ccy"] else "USD"

        amount_usd = self.lognormal(f["median"], f["sigma"], f["lo"], f["hi"])
        if key == "remit_in" and rng.random() < .45:
            amount_usd = max(50, round(amount_usd / 50) * 50)
        rate = self.rates[(d, ccy)]
        decimals = 0 if ccy in ZERO_DECIMALS else 2
        amount = max(round(amount_usd * rate, decimals), 1)
        amount_usd = amount / rate

        lo, hi = f["hours"]
        created = datetime.combine(d, time()) + timedelta(
            hours=rng.triangular(lo, hi, (lo + hi) / 2), seconds=rng.randint(0, 59))
        created = created.replace(microsecond=0)

        channel = self.pick_channel(key, seg, d)
        status, reason = self.status(key, f["direction"], channel, cust["risk_rating"], d)
        settled = None
        if status in ("Completed", "Returned"):
            settled = self.settle_time(created, ccy, f["direction"], channel,
                                       cust["risk_rating"], amount_usd)
            if settled.date() > END:                   # not settled before period close
                status, reason, settled = "Pending", "Awaiting settlement", None

        return dict(
            customer_id=cust["customer_id"], direction=f["direction"],
            payment_type=f["payment_type"], counterparty_country=country, currency_code=ccy,
            amount=amount, decimals=decimals, amount_usd=amount_usd,
            fee_usd=0.0 if status == "Rejected" else self.fee(key, channel, amount_usd),
            channel=channel, correspondent_bank_id=self.pick_bank(ccy, key, country),
            created_at=created, settled_at=settled, status=status, status_reason=reason)

    # ---------------------------------------------------- bank statements
    def noisy_reference(self, ref):
        k = self.rng.random()
        if k < .30:
            return ref.lower()
        if k < .55:
            return f"REF {ref}"
        if k < .75:
            return f"/RFB/{ref}"
        if k < .90:
            return f"{ref[:3]} {ref[3:9]} {ref[9:]}"
        return ref[:-2]                                # truncated: needs rule-based matching

    def build_statements(self):
        rng = self.rng
        lines = []

        def add(bank, ccy, vdate, amount, ref, desc):
            lines.append(dict(bank_id=bank, currency_code=ccy, value_date=vdate,
                              amount=amount, reference_text=ref, description=desc))

        for p in self.payments:
            if p["status"] not in ("Completed", "Returned"):
                continue
            inbound = p["direction"] == "Inbound"
            sign = 1 if inbound else -1
            vdate = p["settled_at"].date()
            amount = p["amount"]
            ref = p["reference"]
            desc = "INCOMING CREDIT TRANSFER" if inbound else "OUTGOING DEBIT TRANSFER"
            bank, ccy, dec = p["correspondent_bank_id"], p["currency_code"], p["decimals"]

            if p["status"] == "Completed":
                if vdate >= END - timedelta(days=1) and rng.random() < .5:
                    continue                           # posted after period close
                roll = rng.random()
                if roll < .004:
                    continue                           # missing in statement
                if roll < .016:                        # correspondent deducted charges
                    charge = round(rng.choice([10, 15, 20, 25, 30, 35, 40]) * self.rates[(vdate, ccy)], dec)
                    amount = amount - charge if inbound else amount + charge
                    desc += " LESS CHARGES"
                elif roll < .031:                      # booked with a later value date
                    vdate = self.add_business_days(vdate, rng.randint(3, 6))
                    if vdate > END:
                        continue
            if rng.random() < .025:
                ref = self.noisy_reference(ref)
            add(bank, ccy, vdate, sign * amount, ref, desc)
            if rng.random() < .0015:
                add(bank, ccy, vdate, sign * amount, ref, desc)          # duplicated line

            if p["status"] == "Returned":
                rdate = self.add_business_days(vdate, rng.randint(2, 6))
                if rdate <= END:
                    add(bank, ccy, rdate, -sign * p["amount"], f"RTN/{p['reference']}",
                        f"RETURN OF FUNDS - {p['status_reason'].upper()}")

        # Items booked only by the correspondent (not in the bank's ledger).
        accounts = [(b[0], c) for b in BANKS for c in b[4]]
        months = sorted({(d.year, d.month) for d in self.days})
        for y, m in months:
            last = max(d for d in self.days if (d.year, d.month) == (y, m) and d.weekday() < 5)
            for bank, ccy in accounts:
                dec = 0 if ccy in ZERO_DECIMALS else 2
                rate = self.rates[(last, ccy)]
                add(bank, ccy, last, -round(rng.uniform(40, 150) * rate, dec),
                    f"FEE{y}{m:02d}", "ACCOUNT MAINTENANCE FEE")
                if ccy in ("USD", "EUR", "GBP", "CHF"):
                    add(bank, ccy, last, round(rng.uniform(20, 900) * rate, dec),
                        f"INT{y}{m:02d}", "INTEREST CREDIT")
        business_days = [d for d in self.days if d.weekday() < 5]
        for _ in range(150):
            bank, ccy = rng.choice(accounts)
            d = rng.choice(business_days)
            dec = 0 if ccy in ZERO_DECIMALS else 2
            add(bank, ccy, d, round(rng.uniform(100, 20_000) * self.rates[(d, ccy)], dec),
                "", "INCOMING TRANSFER - NO REFERENCE")

        lines.sort(key=lambda l: (l["value_date"], l["bank_id"], l["currency_code"]))
        for n, line in enumerate(lines, start=1):
            line["statement_line_id"] = n
        self.statements = lines

    # --------------------------------------------------------------- output
    def messy(self, text):
        """Return the text with inconsistent casing / spacing."""
        k = self.rng.random()
        if k < .33:
            return text.lower()
        if k < .66:
            return f" {text.upper()} "
        return f"{text}  "

    def write(self, out: Path):
        rng = self.rng
        out.mkdir(parents=True, exist_ok=True)

        def dump(name, header, rows):
            with open(out / name, "w", newline="", encoding="utf-8") as fh:
                w = csv.writer(fh, lineterminator="\n")
                w.writerow(header)
                w.writerows(rows)
            print(f"  {name:<28} {len(rows):>8,} rows")

        dump("currencies.csv", ["currency_code", "currency_name"],
             [(c[0], c[1]) for c in CURRENCIES])
        dump("countries.csv", ["country_code", "country_name", "region", "currency_code"], COUNTRIES)
        dump("correspondent_banks.csv", ["bank_id", "bank_name", "swift_code", "country_code"],
             [b[:4] for b in BANKS])
        dump("channels.csv", ["channel_id", "channel_name"],
             [(i, c) for i, c in enumerate(CHANNELS, start=1)])
        dump("exchange_rates.csv", ["rate_date", "currency_code", "units_per_usd"],
             [(d.isoformat(), c, f"{r:.6f}") for (d, c), r in sorted(self.rates.items())])

        cust_rows = []
        for c in self.customers:
            name, seg = c["customer_name"], c["segment"]
            if rng.random() < .03:
                name = f"  {name.replace(' ', '  ', 1)} "
            if rng.random() < .02:
                seg = self.messy(seg)
            cust_rows.append([c["customer_id"], name, c["customer_type"], seg, c["city"],
                              c["onboarding_date"].isoformat(), c["risk_rating"]])
        for row in rng.sample(cust_rows, 15):             # duplicated customers
            cust_rows.insert(rng.randrange(len(cust_rows)), list(row))
        dump("customers.csv", ["customer_id", "customer_name", "customer_type", "segment", "city",
                               "onboarding_date", "risk_rating"], cust_rows)

        pay_rows = []
        for p in self.payments:
            channel, country = p["channel"], p["counterparty_country"]
            if rng.random() < .006:
                channel = self.messy(channel)
            if rng.random() < .003:
                country = country.lower()
            pay_rows.append([
                p["payment_id"], p["reference"], p["customer_id"], p["direction"],
                p["payment_type"], country, p["currency_code"], f"{p['amount']:.{p['decimals']}f}",
                f"{p['fee_usd']:.2f}", channel, p["correspondent_bank_id"],
                p["created_at"].isoformat(sep=" "),
                p["settled_at"].isoformat(sep=" ") if p["settled_at"] else "",
                p["status"], p["status_reason"]])
        for row in rng.sample(pay_rows, 25):              # duplicated payments
            pay_rows.insert(rng.randrange(len(pay_rows)), list(row))
        for i in range(1, 7):                             # test records leaked from QA
            pay_rows.append([9_000_000 + i, f"TEST{i:06d}", "TEST0001", "Outbound",
                             "Supplier Payment", "US", "USD", "0.00", "0.00", "Online Banking", 1,
                             f"2025-06-0{i} 10:00:00", "", "Completed", ""])
        dump("payments.csv", ["payment_id", "reference", "customer_id", "direction", "payment_type",
                              "counterparty_country", "currency_code", "amount", "fee_usd", "channel",
                              "correspondent_bank_id", "created_at", "settled_at", "status",
                              "status_reason"], pay_rows)

        stmt_rows = []
        for l in self.statements:
            dec = 0 if l["currency_code"] in ZERO_DECIMALS else 2
            stmt_rows.append([l["statement_line_id"], l["bank_id"], l["currency_code"],
                              l["value_date"].isoformat(), f"{l['amount']:.{dec}f}",
                              l["reference_text"], l["description"]])
        dump("bank_statement_lines.csv", ["statement_line_id", "bank_id", "currency_code",
                                          "value_date", "amount", "reference_text", "description"],
             stmt_rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--out", type=Path,
                        default=Path(__file__).resolve().parent.parent / "data" / "raw")
    args = parser.parse_args()

    gen = Generator(args.seed)
    print(f"Generating data (seed={args.seed}) -> {args.out}")
    gen.build_rates()
    gen.build_customers()
    gen.build_payments()
    gen.build_statements()
    gen.write(args.out)
    print("Done.")


if __name__ == "__main__":
    main()
