-- 0010: accounting core primitives.
-- New movement kinds first (enum values must not be used in this same file).
ALTER TYPE public.move_kind ADD VALUE IF NOT EXISTS 'purchase';
ALTER TYPE public.move_kind ADD VALUE IF NOT EXISTS 'opening';
ALTER TYPE public.move_kind ADD VALUE IF NOT EXISTS 'adjustment';
ALTER TYPE public.move_kind ADD VALUE IF NOT EXISTS 'sale_return';

-- Sequential, human-readable document numbers (INV-, MR-, DEP-, CH-, RT-, SR-, PUR-, SP-).
CREATE TABLE public.doc_counters (
  kind text PRIMARY KEY,
  prefix text NOT NULL,
  last_no integer NOT NULL DEFAULT 0
);
GRANT SELECT ON public.doc_counters TO authenticated;
GRANT ALL ON public.doc_counters TO service_role;
ALTER TABLE public.doc_counters ENABLE ROW LEVEL SECURITY;
CREATE POLICY "doc counters admin read" ON public.doc_counters FOR SELECT TO authenticated USING (public.has_role(auth.uid(),'admin'));
INSERT INTO public.doc_counters(kind,prefix) VALUES
 ('invoice','INV-'),('money_receipt','MR-'),('deposit','DEP-'),('challan','CH-'),
 ('return_challan','RT-'),('sale_return','SR-'),('purchase','PUR-'),('supplier_payment','SP-'),('expense','EXP-')
ON CONFLICT (kind) DO NOTHING;

CREATE OR REPLACE FUNCTION public.next_doc_no(_kind text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE p text; n integer;
BEGIN
  UPDATE public.doc_counters SET last_no = last_no + 1 WHERE kind = _kind RETURNING prefix, last_no INTO p, n;
  IF p IS NULL THEN RAISE EXCEPTION 'Unknown document kind %', _kind; END IF;
  RETURN p || lpad(n::text, 6, '0');
END $$;
REVOKE ALL ON FUNCTION public.next_doc_no(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.next_doc_no(text) TO authenticated, service_role;

-- Document numbers, idempotency keys and business (value) dates on existing tables.
ALTER TABLE public.sales ADD COLUMN invoice_no text UNIQUE;
ALTER TABLE public.sales ADD COLUMN client_op_id uuid UNIQUE;
ALTER TABLE public.sales ADD COLUMN discount numeric(12,2) NOT NULL DEFAULT 0 CHECK (discount >= 0);
ALTER TABLE public.sales ADD COLUMN txn_date date NOT NULL DEFAULT ((now() AT TIME ZONE 'Asia/Dhaka')::date);

ALTER TABLE public.retailer_payments ADD COLUMN receipt_no text UNIQUE;
ALTER TABLE public.retailer_payments ADD COLUMN client_op_id uuid UNIQUE;
ALTER TABLE public.retailer_payments ADD COLUMN method text NOT NULL DEFAULT 'cash' CHECK (method IN ('cash','bank','bkash','nagad','other'));
ALTER TABLE public.retailer_payments ADD COLUMN txn_date date NOT NULL DEFAULT ((now() AT TIME ZONE 'Asia/Dhaka')::date);

ALTER TABLE public.deposits ADD COLUMN receipt_no text UNIQUE;
ALTER TABLE public.deposits ADD COLUMN client_op_id uuid UNIQUE;
ALTER TABLE public.deposits ADD COLUMN method text NOT NULL DEFAULT 'cash' CHECK (method IN ('cash','bank','bkash','nagad','other'));
ALTER TABLE public.deposits ADD COLUMN txn_date date NOT NULL DEFAULT ((now() AT TIME ZONE 'Asia/Dhaka')::date);

ALTER TABLE public.stock_movements ADD COLUMN batch_no text;
ALTER TABLE public.stock_movements ADD COLUMN cost_price numeric(12,2);
ALTER TABLE public.stock_movements ADD COLUMN txn_date date NOT NULL DEFAULT ((now() AT TIME ZONE 'Asia/Dhaka')::date);
CREATE INDEX IF NOT EXISTS stock_movements_batch_idx ON public.stock_movements (batch_no);
CREATE INDEX IF NOT EXISTS stock_movements_txn_date_idx ON public.stock_movements (txn_date);
CREATE INDEX IF NOT EXISTS sales_txn_date_idx ON public.sales (txn_date);

-- Credit terms per retailer (NULL credit_limit = not set by owner yet).
ALTER TABLE public.retailers ADD COLUMN credit_limit numeric(12,2) CHECK (credit_limit IS NULL OR credit_limit >= 0);
ALTER TABLE public.retailers ADD COLUMN due_days integer NOT NULL DEFAULT 30 CHECK (due_days >= 0);

-- Cost prices (purchase side of the ledger).
ALTER TABLE public.products ADD COLUMN cost_price numeric(12,2) NOT NULL DEFAULT 0 CHECK (cost_price >= 0);
ALTER TABLE public.imei_units ADD COLUMN cost_price numeric(12,2) NOT NULL DEFAULT 0 CHECK (cost_price >= 0);

-- Idempotency registry for batch operations that do not create a header row.
CREATE TABLE public.processed_ops (
  client_op_id uuid PRIMARY KEY,
  kind text NOT NULL,
  actor uuid NOT NULL,
  result_ref text,
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.processed_ops TO authenticated;
GRANT ALL ON public.processed_ops TO service_role;
ALTER TABLE public.processed_ops ENABLE ROW LEVEL SECURITY;
CREATE POLICY "processed ops own read" ON public.processed_ops FOR SELECT TO authenticated USING (actor = auth.uid() OR public.has_role(auth.uid(),'admin'));

-- Canonical retailer due, used by every validation and report from now on:
-- due = sum(invoice balances) - later collections - retailer sales returns.
-- retailer_returns is created in 0011; plpgsql keeps name resolution deferred until first call.
CREATE OR REPLACE FUNCTION public.retailer_due(_retailer uuid) RETURNS numeric
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  RETURN coalesce((SELECT sum(total - paid) FROM public.sales WHERE retailer_id=_retailer),0)
       - coalesce((SELECT sum(amount) FROM public.retailer_payments WHERE retailer_id=_retailer),0)
       - coalesce((SELECT sum(total) FROM public.retailer_returns WHERE retailer_id=_retailer),0);
END $$;
REVOKE ALL ON FUNCTION public.retailer_due(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.retailer_due(uuid) TO authenticated, service_role;

-- Salesman cash in hand: collected at sale + later collections - office deposits.
CREATE OR REPLACE FUNCTION public.salesman_cash(_salesman uuid) RETURNS numeric
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  RETURN coalesce((SELECT sum(paid) FROM public.sales WHERE salesman_id=_salesman),0)
       + coalesce((SELECT sum(amount) FROM public.retailer_payments WHERE salesman_id=_salesman),0)
       - coalesce((SELECT sum(amount) FROM public.deposits WHERE salesman_id=_salesman),0);
END $$;
REVOKE ALL ON FUNCTION public.salesman_cash(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.salesman_cash(uuid) TO authenticated, service_role;
