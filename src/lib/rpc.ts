import { supabase } from "@/integrations/supabase/client";

/**
 * Calls RPC functions that were added after the generated Supabase types were
 * last produced (0010-0012 migrations). Keeps the call sites typed at the
 * boundary instead of scattering `as any` through the pages.
 */
export async function rpc<T = unknown>(name: string, args?: Record<string, unknown>): Promise<{ data: T | null; error: { message: string } | null }> {
  const call = supabase.rpc as unknown as (fn: string, a?: Record<string, unknown>) => Promise<{ data: T | null; error: { message: string } | null }>;
  return await call(name, args);
}

export type RetailerLedger = {
  id: string;
  name: string;
  phone: string | null;
  address: string | null;
  salesman_id: string;
  credit_limit: number | null;
  due_days: number;
  sales_total: number;
  paid_at_sale: number;
  collected: number;
  returns_total: number;
  due: number;
};

export type ProfitSummary = {
  sales_total: number;
  discount_total: number;
  returns_total: number;
  cogs: number;
  expenses_total: number;
  purchases_total: number;
  supplier_due: number;
  net_sales: number;
  gross_profit: number;
  net_profit: number;
};
