import { PGlite } from "@electric-sql/pglite";
import { readFileSync, readdirSync } from "node:fs";
import { beforeAll, afterAll, describe, it, expect } from "vitest";

const owner = "11111111-1111-4111-8111-111111111111";
const sr = "22222222-2222-4222-8222-222222222222";
const supplier = "55555555-5555-4555-8555-555555555555";
const phone = "66666666-6666-4666-8666-666666666666";
const button = "77777777-7777-4777-8777-777777777777";
const retailer = "44444444-4444-4444-8444-444444444444";
const IMEI1 = "356938035643809";
const IMEI2 = "356938035643800";

describe("accounting chain (all migrations, PGlite)", () => {
  let db: PGlite;
  beforeAll(async () => {
    db = new PGlite();
    await db.exec(`CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role; CREATE SCHEMA auth; CREATE TABLE auth.users(id uuid PRIMARY KEY, raw_user_meta_data jsonb DEFAULT '{}'); CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('app.user',true),'')::uuid $$;`);
    const files = readdirSync("drizzle/migrations").filter((f) => f.endsWith(".sql")).sort();
    for (const f of files) await db.exec(readFileSync(`drizzle/migrations/${f}`, "utf8"));
    await db.exec(`INSERT INTO auth.users(id) VALUES('${owner}'),('${sr}');
      -- handle_new_user trigger creates profiles + roles: first user = admin, second = salesman
      SELECT set_config('app.user','${owner}',false);
      INSERT INTO suppliers(id, name) VALUES('${supplier}','Xiaomi Distributor');
      INSERT INTO products(id, name, is_smartphone, price) VALUES('${phone}','Redmi Note', true, 20000), ('${button}','Button Phone', false, 3000);
      INSERT INTO retailers(id, name, salesman_id) VALUES('${retailer}','Shop','${sr}');`);
  }, 120000);
  afterAll(async () => { await db?.close(); });
  async function as(user: string) { await db.query("SELECT set_config('app.user',$1,false)", [user]); }
  async function one<T = any>(sql: string, params: any[] = []) { return (await db.query<T>(sql, params)).rows[0] as T; }

  it("purchase creates costed stock, supplier due and sequential doc numbers", async () => {
    await as(owner);
    const pid = (await one<{ record_purchase: string }>("SELECT record_purchase($1,$2::jsonb,5000,'2026-11-01',$3) ", [supplier, JSON.stringify([
      { product_id: phone, cost_price: 15000, imeis: [IMEI1, IMEI2] },
      { product_id: button, cost_price: 2000, qty: 10 },
    ]), "a0000000-0000-4000-8000-000000000001"])).record_purchase;
    expect(pid).toBeTruthy();
    // idempotent replay returns the same purchase
    const again = (await one<{ record_purchase: string }>("SELECT record_purchase($1,$2::jsonb,5000,'2026-11-01',$3)", [supplier, "[]", "a0000000-0000-4000-8000-000000000001"])).record_purchase;
    expect(again).toBe(pid);
    expect((await one<{ n: number }>("SELECT count(*)::int n FROM imei_units WHERE status='in_stock'")).n).toBe(2);
    expect((await one<{ q: number }>(`SELECT stock_qty q FROM products WHERE id='${button}'`)).q).toBe(10);
    expect(Number((await one<{ supplier_due: string }>("SELECT supplier_due($1)", [supplier])).supplier_due)).toBe(45000); // 2*15000+10*2000-5000
    const doc = await one<{ doc_no: string }>(`SELECT doc_no FROM purchases WHERE id='${pid}'`);
    expect(doc.doc_no).toMatch(/^PUR-\d{6}$/);
    await expect(db.query("SELECT record_supplier_payment($1,46000,'cash',NULL,'2026-11-01',NULL)", [supplier])).rejects.toThrow("exceeds supplier due");
    await db.query("SELECT record_supplier_payment($1,45000,'bank',NULL,'2026-11-02',NULL)", [supplier]);
    expect(Number((await one<{ supplier_due: string }>("SELECT supplier_due($1)", [supplier])).supplier_due)).toBe(0);
  });

  it("direct stock edits are blocked; receive_stock writes a movement", async () => {
    await as(owner);
    // Direct API writes arrive as the 'authenticated' role; the guard keys on that.
    await db.exec("SET ROLE authenticated;");
    try {
      await expect(db.query(`UPDATE products SET stock_qty = 99 WHERE id='${button}'`)).rejects.toThrow("validated stock functions");
      await expect(db.query(`INSERT INTO imei_units(product_id, imei) VALUES('${phone}','356938035643811')`)).rejects.toThrow("permission denied");
    } finally { await db.exec("RESET ROLE;"); }
    await db.query("SELECT receive_stock($1,5,'opening','Opening count','2026-11-01',NULL)", [button]);
    expect((await one<{ q: number }>(`SELECT stock_qty q FROM products WHERE id='${button}'`)).q).toBe(15);
    expect((await one<{ n: number }>("SELECT count(*)::int n FROM stock_movements WHERE kind='opening'")).n).toBe(1);
  });

  it("issue -> sale -> collection -> deposit chain keeps every balance exact", async () => {
    await as(owner);
    const batch = (await one<{ issue_stock: string }>("SELECT issue_stock($1,$2::jsonb,'2026-11-03',$3)", [sr, JSON.stringify([
      { product_id: phone, imeis: [IMEI1] }, { product_id: button, qty: 4 },
    ]), "a0000000-0000-4000-8000-000000000002"])).issue_stock;
    expect(batch).toMatch(/^CH-\d{6}$/);
    // replay is a no-op returning the same challan
    const batch2 = (await one<{ issue_stock: string }>("SELECT issue_stock($1,$2::jsonb,'2026-11-03',$3)", [sr, JSON.stringify([{ product_id: button, qty: 1 }]), "a0000000-0000-4000-8000-000000000002"])).issue_stock;
    expect(batch2).toBe(batch);
    expect((await one<{ q: number }>("SELECT holding_qty($1,$2) q", [sr, button])).q).toBe(4);

    await as(sr);
    await expect(db.query("SELECT record_sale($1,$2::jsonb,0,0,'2026-11-03',NULL)", [retailer, JSON.stringify([{ product_id: phone, unit_price: 0, imeis: [IMEI1] }])])).rejects.toThrow("price must be positive");
    const saleId = (await one<{ record_sale: string }>("SELECT record_sale($1,$2::jsonb,12000,1000,'2026-11-03',$3)", [retailer, JSON.stringify([
      { product_id: phone, unit_price: 20000, imeis: [IMEI1] }, { product_id: button, unit_price: 3000, qty: 2 },
    ]), "a0000000-0000-4000-8000-000000000003"])).record_sale;
    const sale = await one<{ total: string; invoice_no: string }>(`SELECT total, invoice_no FROM sales WHERE id='${saleId}'`);
    expect(Number(sale.total)).toBe(25000); // 20000 + 2*3000 - 1000 discount
    expect(sale.invoice_no).toMatch(/^INV-\d{6}$/);
    // idempotent sale replay
    const saleAgain = (await one<{ record_sale: string }>("SELECT record_sale($1,'[]'::jsonb,0,0,'2026-11-03',$2)", [retailer, "a0000000-0000-4000-8000-000000000003"])).record_sale;
    expect(saleAgain).toBe(saleId);
    expect(Number((await one<{ retailer_due: string }>("SELECT retailer_due($1)", [retailer])).retailer_due)).toBe(13000);
    // over-collection is rejected by the database now
    await expect(db.query("SELECT record_retailer_payment($1,13001,'cash',NULL,'2026-11-04',NULL)", [retailer])).rejects.toThrow("exceeds retailer due");
    await db.query("SELECT record_retailer_payment($1,13000,'bkash',NULL,'2026-11-04',$2)", [retailer, "a0000000-0000-4000-8000-000000000004"]);
    expect(Number((await one<{ retailer_due: string }>("SELECT retailer_due($1)", [retailer])).retailer_due)).toBe(0);
    // salesman cash = 12000 at sale + 13000 collected = 25000; deposit above that is rejected
    await as(owner);
    await expect(db.query("SELECT record_deposit($1,25001,'cash',NULL,'2026-11-04',NULL)", [sr])).rejects.toThrow("exceeds cash in hand");
    await db.query("SELECT record_deposit($1,25000,'bank',NULL,'2026-11-04',NULL)", [sr]);
    expect(Number((await one<{ salesman_cash: string }>("SELECT salesman_cash($1)", [sr])).salesman_cash)).toBe(0);
  });

  it("retailer sales return credits the ledger and restocks the salesman", async () => {
    await as(sr);
    const sale2 = (await one<{ record_sale: string }>("SELECT record_sale($1,$2::jsonb,0,0,'2026-11-05',NULL)", [retailer, JSON.stringify([{ product_id: button, unit_price: 3000, qty: 1 }])])).record_sale;
    expect(sale2).toBeTruthy();
    expect(Number((await one<{ retailer_due: string }>("SELECT retailer_due($1)", [retailer])).retailer_due)).toBe(3000);
    await db.query("SELECT record_retailer_return($1,$2::jsonb,'2026-11-06',NULL)", [retailer, JSON.stringify([{ product_id: button, unit_price: 3000, qty: 1 }])]);
    expect(Number((await one<{ retailer_due: string }>("SELECT retailer_due($1)", [retailer])).retailer_due)).toBe(0);
    // a further return is stock-wise possible (3 sold, 1 returned) but the ledger is fully
    // settled, so the credit-note check must block it instead
    await expect(db.query("SELECT record_retailer_return($1,$2::jsonb,'2026-11-06',NULL)", [retailer, JSON.stringify([{ product_id: button, unit_price: 3000, qty: 1 }])])).rejects.toThrow("exceeds retailer due");
  });

  it("credit limit blocks sales that would exceed it", async () => {
    await as(owner);
    await db.query(`UPDATE retailers SET credit_limit = 1000 WHERE id='${retailer}'`);
    await as(sr);
    await expect(db.query("SELECT record_sale($1,$2::jsonb,0,0,'2026-11-06',NULL)", [retailer, JSON.stringify([{ product_id: button, unit_price: 3000, qty: 1 }])])).rejects.toThrow("Credit limit exceeded");
    await as(owner);
    await db.query(`UPDATE retailers SET credit_limit = NULL WHERE id='${retailer}'`);
  });

  it("profit summary: net sales - COGS - expenses", async () => {
    await as(owner);
    await db.query("SELECT record_expense('Rent',4000,NULL,'2026-11-06',NULL)");
    const p = (await one<{ profit_summary: any }>("SELECT profit_summary('2026-11-01','2026-11-30')")).profit_summary;
    // sales 25000 + 3000 = 28000; returns 3000; COGS = (15000 + 2*2000 + 2000) - 2000 = 19000; expenses 4000
    expect(Number(p.net_sales)).toBe(25000);
    expect(Number(p.cogs)).toBe(19000);
    expect(Number(p.gross_profit)).toBe(6000);
    expect(Number(p.net_profit)).toBe(2000);
  });

  it("backup snapshot covers the new accounting tables", async () => {
    await as(owner);
    const snap = (await one<{ export_business_data: any }>("SELECT export_business_data()")).export_business_data;
    expect(snap.tables.suppliers.length).toBeGreaterThan(0);
    expect(snap.tables.purchases.length).toBeGreaterThan(0);
    expect(snap.tables.expenses.length).toBeGreaterThan(0);
    expect(snap.tables.retailer_returns.length).toBeGreaterThan(0);
  });

  it("movement cancellation reverses adjustments, refuses purchase/sale_return movements", async () => {
    await as(owner);
    const before = Number((await one<{ stock_qty: string }>(`SELECT stock_qty FROM products WHERE id='${button}'`)).stock_qty);
    await db.query("SELECT receive_stock($1,3,'adjustment','recount fix',NULL,NULL)", [button]);
    expect(Number((await one<{ stock_qty: string }>(`SELECT stock_qty FROM products WHERE id='${button}'`)).stock_qty)).toBe(before + 3);
    const mv = await one<{ id: string }>("SELECT id FROM stock_movements WHERE kind='adjustment' ORDER BY created_at DESC LIMIT 1");
    await db.query("SELECT cancel_business_history('stock_movements',$1,'undo recount')", [mv.id]);
    expect(Number((await one<{ stock_qty: string }>(`SELECT stock_qty FROM products WHERE id='${button}'`)).stock_qty)).toBe(before);
    const pm = await one<{ id: string }>("SELECT id FROM stock_movements WHERE kind='purchase' AND imei IS NOT NULL LIMIT 1");
    await expect(db.query("SELECT cancel_business_history('stock_movements',$1,'not allowed')", [pm.id])).rejects.toThrow(/purchase record/);
    const sm = await one<{ id: string }>("SELECT id FROM stock_movements WHERE kind='sale_return' LIMIT 1");
    await expect(db.query("SELECT cancel_business_history('stock_movements',$1,'not allowed')", [sm.id])).rejects.toThrow(/sales return/);
  });

  it("invoice cancellation follows the FIFO rule, not any-payment", async () => {
    await as(sr);
    const s1 = (await one<{ record_sale: string }>("SELECT record_sale($1,$2::jsonb,0,0,'2026-11-07',NULL)", [retailer, JSON.stringify([{ product_id: button, unit_price: 3000, qty: 1 }])])).record_sale;
    const s2 = (await one<{ record_sale: string }>("SELECT record_sale($1,$2::jsonb,0,0,'2026-11-07',NULL)", [retailer, JSON.stringify([{ product_id: button, unit_price: 3000, qty: 1 }])])).record_sale;
    await db.query("SELECT record_retailer_payment($1,3000,'cash',NULL,'2026-11-07',NULL)", [retailer]);
    await as(owner);
    // first invoice is covered by the payment (FIFO) -> cannot cancel; second is not -> can cancel
    await expect(db.query("SELECT cancel_business_history('sales',$1,'Wrong entry')", [s1])).rejects.toThrow("already cover this invoice");
    await db.query("SELECT cancel_business_history('sales',$1,'Wrong entry')", [s2]);
    expect((await one<{ n: number }>(`SELECT count(*)::int n FROM sales WHERE id='${s2}'`)).n).toBe(0);
  });
});
