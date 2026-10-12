from fastapi.testclient import TestClient

from main import app

client = TestClient(app)


def test_health():
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json()["status"] == "ok"


def test_invoice_lifecycle():
    r = client.post("/invoices", json={"customer": "Acme", "amount_cents": 12500})
    assert r.status_code == 201
    invoice_id = r.json()["id"]
    assert r.json()["status"] == "open"

    r = client.post(f"/invoices/{invoice_id}/pay")
    assert r.status_code == 200
    assert r.json()["status"] == "paid"

    r = client.post(f"/invoices/{invoice_id}/pay")
    assert r.status_code == 409


def test_not_found():
    assert client.get("/invoices/99999").status_code == 404


def test_validation():
    r = client.post("/invoices", json={"customer": "", "amount_cents": -5})
    assert r.status_code == 422
