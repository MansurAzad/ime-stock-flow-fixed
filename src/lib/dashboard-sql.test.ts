// Runs the real distribution_insights() function in PGlite (no Lovable CLI needed).
import { PGlite } from "@electric-sql/pglite";
import { readFileSync, readdirSync } from "node:fs";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { DashboardInsights } from "./dashboard";

const owner = "11111111-1111-4111-8111-111111111111";
const sr = "22222222-2222-4222-8222-222222222222";
const R = { old: "44444444-4444-4444-8444-444444444441", boundary: "44444444-4444-4444-8444-444444444442", young: "44444444-4444-4444-8444-444444444443", cleared: "44444444-4444-4444-8444-444444444444" };

describe("Dashboard database calculations", () => {
  let db: PGlite;
  let report: DashboardInsights;
  beforeAll(async () => {
    db = new PGlite();
    await db.exec(`CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role; CREATE SCHEMA auth; CREATE TABLE auth.users(id uuid PRIMARY KEY, raw_user_meta_data jsonb DEFAULT '{}'); CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('app.user',true),'')::uuid $$;`);
    const files = readdirSync("drizzle/migrations").filter((f) => f.endsWith(".sql")).sort();
    for (const f of files) await db.exec(readFileSync(`drizzle/migrations/${f}`, "utf8"));
    const d = (n: number) => `((now() AT TIME ZONE 'Asia/Dhaka')::date - ${n})`;
    await db.exec(`INSERT INTO auth.users(id) VALUES('${owner}'),('${sr}');
      SELECT set_config('app.user','${sr}',false);
      INSERT INTO retailers(id, name, salesman_id) VALUES
        ('${R.old}','old','${sr}'), ('${R.boundary}','boundary','${sr}'), ('${R.young}','young','${sr}'), ('${R.cleared}','cleared','${sr}');
      INSERT INTO sales(salesman_id, retailer_id, total, paid, txn_date) VALUES
        ('${sr}','${R.old}',100,20,${d(45)}),
        ('${sr}','${R.old}',80,0,${d(10)}),
        ('${sr}','${R.boundary}',50,0,${d(30)}),
        ('${sr}','${R.young}',60,0,${d(29)}),
        ('${sr}','${R.cleared}',70,0,${d(60)});
      INSERT INTO retailer_payments(salesman_id, retailer_id, amount) VALUES
        ('${sr}','${R.old}',50), ('${sr}','${R.cleared}',100);
      INSERT INTO deposits(salesman_id, amount) VALUES('${sr}',10);
      INSERT INTO products(name, is_smartphone, price, cost_price, stock_qty, low_stock_threshold) VALUES
        ('Below',false,10,10,4,5), ('Equal',false,10,10,5,5), ('Unset',false,10,10,0,0);
      SELECT set_config('app.user','${owner}',false);`);
    const rows = (await db.query<{ distribution_insights: DashboardInsights }>("SELECT distribution_insights()")).rows;
    report = rows[0]?.distribution_insights as DashboardInsights;
    if (!report) throw new Error("No report returned");
  }, 120000);
  afterAll(async () => { await db?.close(); });

  it("includes exactly 30-day debt but excludes a younger balance", () => {
    expect(report.overdue.map((r) => r.id).sort()).toEqual([R.boundary, R.old].sort());
  });
  it("subtracts initial payments once and applies collections oldest-first", () => {
    expect(report.overdue.find((r) => r.id === R.old)?.overdue_amount).toBe(30);
    expect(report.overdue.find((r) => r.id === R.old)?.total_due).toBe(110);
  });
  it("does not move one retailer's excess credit to another retailer", () => {
    expect(report.overdueTotal).toBe(80);
    expect(report.overdue.some((r) => r.id === R.cleared)).toBe(false);
  });
  it("warns below each product threshold but not at the threshold", () => {
    expect(report.lowStock.map((p) => p.name)).toEqual(["Below"]);
    expect(report.warehouseQty).toBe(9);
    // warehouse value is now at cost price (10 x 9), with retail value reported separately
    expect(report.warehouseValue).toBe(90);
  });
  it("derives collections and cash from sales, payments and deposits", () => {
    expect(report.collected).toBe(170);
    expect(report.cashInHand).toBe(160);
    expect(report.deposited).toBe(10);
  });
});
