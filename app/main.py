import logging
import os
import time

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("invoice-api")

APP_VERSION = os.getenv("APP_VERSION", "dev")
START_TIME = time.time()

app = FastAPI(title="Invoice API", version=APP_VERSION)


class InvoiceIn(BaseModel):
    customer: str = Field(min_length=1, max_length=100)
    amount_cents: int = Field(gt=0)


class Invoice(InvoiceIn):
    id: int
    status: str = "open"


# In-memory store keeps the demo cheap; swap for Azure SQL / Cosmos DB in a real system.
_invoices: dict[int, Invoice] = {}
_next_id = 1


@app.get("/health")
def health():
    """Liveness/readiness probe used by Container Apps."""
    return {"status": "ok", "version": APP_VERSION, "uptime_s": round(time.time() - START_TIME, 1)}


@app.post("/invoices", response_model=Invoice, status_code=201)
def create_invoice(body: InvoiceIn):
    global _next_id
    invoice = Invoice(id=_next_id, **body.model_dump())
    _invoices[invoice.id] = invoice
    _next_id += 1
    log.info("invoice_created id=%s amount_cents=%s", invoice.id, invoice.amount_cents)
    return invoice


@app.get("/invoices/{invoice_id}", response_model=Invoice)
def get_invoice(invoice_id: int):
    invoice = _invoices.get(invoice_id)
    if invoice is None:
        raise HTTPException(status_code=404, detail="invoice not found")
    return invoice


@app.post("/invoices/{invoice_id}/pay", response_model=Invoice)
def pay_invoice(invoice_id: int):
    invoice = get_invoice(invoice_id)
    if invoice.status == "paid":
        raise HTTPException(status_code=409, detail="invoice already paid")
    invoice.status = "paid"
    log.info("invoice_paid id=%s", invoice_id)
    return invoice
