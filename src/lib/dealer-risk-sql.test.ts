// Runs the real dealer_risk_history() function in PGlite (no Lovable CLI needed).
import { PGlite } from "@electric-sql/pglite";
import { readFileSync, readdirSync } from "node:fs";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { DealerFacts } from "./dealer-risk";

const owner = "11111111-1111-4111-8111-111111111111";
const sr = "22222222-2222-4222-8222-222222222222";
const retailer = "44444444-4444-4444-8444-444444444444";
const product = "66666666-6666-4666-8666-666666666666";

describe("dealer risk history SQL", () => {
  let db: PGlite;
  let report: DealerFacts[];
  beforeAll(async () => {
    db = new PGlite();
    await db.exec(`CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role; CREATE SCHEMA auth; CREATE TABLE auth.users(id uuid PRIMARY KEY, raw_user_meta_data jsonb DEFAULT '{}'); CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('app.user',true),'')::uuid $$;`);
    const files = readdirSync("drizzle/migrations").filter((f) => f.endsWith(".sql")).sort();
    for (const f of files) await db.exec(readFileSync(`drizzle/migrations/${f}`, "utf8"));
    await db.exec(`INSERT INTO auth.users(id) VALUES('${owner}'),('${sr}');
      SELECT set_config('app.user','${sr}',false);
      INSERT INTO products(id, name, is_smartphone, price) VALUES('${product}','Phone',false,10);
      INSERT INTO retailers(id, name, salesman_id) VALUES('${retailer}','A','${sr}');
      INSERT INTO sales(salesman_id, retailer_id, total, paid, txn_date, created_at) VALUES
        ('${sr}','${retailer}',100,20,((now() AT TIME ZONE 'Asia/Dhaka')::date - 45), now() - interval '45 days'),
        ('${sr}','${retailer}',80,0,((now() AT TIME ZONE 'Asia/Dhaka')::date - 10), now() - interval '10 days');
      INSERT INTO retailer_payments(salesman_id, retailer_id, amount, created_at) VALUES('${sr}','${retailer}',50, now() - interval '5 days');
      INSERT INTO stock_movements(salesman_id, product_id, kind, qty, unit_price, retailer_id) VALUES
        ('${sr}','${product}','return',2,10,'${retailer}'),
        ('${sr}','${product}','return',7,10,NULL);
      SELECT set_config('app.user','${owner}',false);`);
    const rows = (await db.query<{ dealer_risk_history: DealerFacts[] }>("SELECT dealer_risk_history()")).rows;
    report = rows[0]?.dealer_risk_history ?? [];
  }, 120000);
  afterAll(async () => { await db?.close(); });

  it("uses sales, FIFO dues, collections and only dealer-linked returns", () => {
    expect(report[0]?.sales_total).toBe(180);
    expect(report[0]?.paid_at_sale).toBe(20);
    expect(report[0]?.collected).toBe(50);
    expect(report[0]?.total_due).toBe(110);
    expect(report[0]?.overdue_amount).toBe(30);
    expect(report[0]?.linked_return_qty).toBe(2);
    expect(report[0]?.linked_return_value).toBe(20);
    // unattributed returns are now scoped to the retailer's own salesman (1 row), not a global total
    expect(report[0]?.unattributed_return_count).toBe(1);
  });
});
