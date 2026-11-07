-- 0011: purchases & suppliers, expenses, retailer sales returns, validated
-- payment/deposit RPCs, and reporting that understands returns and txn_date.

-- Holding formula, corrected for the new movement kinds:
-- issue and sale_return put stock in the salesman's hands; sale/return/damage take it out;
-- purchase/opening/adjustment are warehouse-level and never counted as held.
CREATE OR REPLACE FUNCTION public.holding_qty(_salesman uuid, _product uuid) RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN public.user_is_active(auth.uid()) AND (auth.uid()=_salesman OR public.has_role(auth.uid(),'admin'))
    THEN coalesce((SELECT sum(CASE WHEN kind IN ('issue','sale_return') THEN qty WHEN kind IN ('sale','return','damage') THEN -qty ELSE 0 END)::integer
                   FROM stock_movements WHERE salesman_id=_salesman AND product_id=_product),0)
    ELSE 0 END;
$$;

-- ---------- masters ----------
CREATE TABLE public.suppliers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  phone text,
  address text,
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE ON public.suppliers TO authenticated;
GRANT ALL ON public.suppliers TO service_role;
ALTER TABLE public.suppliers ENABLE ROW LEVEL SECURITY;
CREATE POLICY "suppliers admin rw" ON public.suppliers FOR ALL TO authenticated
  USING (public.has_role(auth.uid(),'admin')) WITH CHECK (public.has_role(auth.uid(),'admin'));

CREATE TABLE public.purchases (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  supplier_id uuid NOT NULL REFERENCES public.suppliers(id),
  doc_no text UNIQUE,
  total numeric(12,2) NOT NULL DEFAULT 0 CHECK (total >= 0),
  paid numeric(12,2) NOT NULL DEFAULT 0 CHECK (paid >= 0),
  txn_date date NOT NULL DEFAULT ((now() AT TIME ZONE 'Asia/Dhaka')::date),
  client_op_id uuid UNIQUE,
  created_by uuid NOT NULL DEFAULT auth.uid(),
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.purchases TO authenticated;
GRANT ALL ON public.purchases TO service_role;
ALTER TABLE public.purchases ENABLE ROW LEVEL SECURITY;
CREATE POLICY "purchases admin read" ON public.purchases FOR SELECT TO authenticated USING (public.has_role(auth.uid(),'admin'));

CREATE TABLE public.supplier_payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  supplier_id uuid NOT NULL REFERENCES public.suppliers(id),
  doc_no text UNIQUE,
  amount numeric(12,2) NOT NULL CHECK (amount > 0),
  method text NOT NULL DEFAULT 'cash' CHECK (method IN ('cash','bank','bkash','nagad','other')),
  note text,
  txn_date date NOT NULL DEFAULT ((now() AT TIME ZONE 'Asia/Dhaka')::date),
  client_op_id uuid UNIQUE,
  created_by uuid NOT NULL DEFAULT auth.uid(),
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.supplier_payments TO authenticated;
GRANT ALL ON public.supplier_payments TO service_role;
ALTER TABLE public.supplier_payments ENABLE ROW LEVEL SECURITY;
CREATE POLICY "supplier payments admin read" ON public.supplier_payments FOR SELECT TO authenticated USING (public.has_role(auth.uid(),'admin'));

ALTER TABLE public.imei_units ADD COLUMN supplier_id uuid REFERENCES public.suppliers(id);
ALTER TABLE public.imei_units ADD COLUMN purchase_id uuid REFERENCES public.purchases(id);

CREATE TABLE public.expenses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  doc_no text UNIQUE,
  category text NOT NULL,
  amount numeric(12,2) NOT NULL CHECK (amount > 0),
  note text,
  txn_date date NOT NULL DEFAULT ((now() AT TIME ZONE 'Asia/Dhaka')::date),
  client_op_id uuid UNIQUE,
  created_by uuid NOT NULL DEFAULT auth.uid(),
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.expenses TO authenticated;
GRANT ALL ON public.expenses TO service_role;
ALTER TABLE public.expenses ENABLE ROW LEVEL SECURITY;
CREATE POLICY "expenses admin read" ON public.expenses FOR SELECT TO authenticated USING (public.has_role(auth.uid(),'admin'));

CREATE TABLE public.retailer_returns (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  retailer_id uuid NOT NULL REFERENCES public.retailers(id),
  salesman_id uuid NOT NULL,
  sale_id uuid REFERENCES public.sales(id),
  doc_no text UNIQUE,
  total numeric(12,2) NOT NULL DEFAULT 0 CHECK (total >= 0),
  txn_date date NOT NULL DEFAULT ((now() AT TIME ZONE 'Asia/Dhaka')::date),
  client_op_id uuid UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.retailer_returns TO authenticated;
GRANT ALL ON public.retailer_returns TO service_role;
ALTER TABLE public.retailer_returns ENABLE ROW LEVEL SECURITY;
CREATE POLICY "retailer returns read" ON public.retailer_returns FOR SELECT TO authenticated
  USING (public.has_role(auth.uid(),'admin') OR salesman_id = auth.uid());

-- Letterhead in the database (one row), so every device prints the same documents.
CREATE TABLE public.business_profile (
  id boolean PRIMARY KEY DEFAULT true CHECK (id),
  name text NOT NULL DEFAULT '',
  address text NOT NULL DEFAULT '',
  phone text NOT NULL DEFAULT '',
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid
);
GRANT SELECT ON public.business_profile TO authenticated;
GRANT ALL ON public.business_profile TO service_role;
ALTER TABLE public.business_profile ENABLE ROW LEVEL SECURITY;
CREATE POLICY "business profile read" ON public.business_profile FOR SELECT TO authenticated USING (true);
INSERT INTO public.business_profile(id,name,address,phone) VALUES (true,'FIROZA ENTERPRISE','KONABARI, GAZIPUR','01817122232') ON CONFLICT (id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.set_business_profile(_name text,_address text,_phone text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.has_role(auth.uid(),'admin') THEN RAISE EXCEPTION 'Owner only'; END IF;
  INSERT INTO public.business_profile(id,name,address,phone,updated_at,updated_by)
  VALUES (true,trim(_name),coalesce(_address,''),coalesce(_phone,''),now(),auth.uid())
  ON CONFLICT (id) DO UPDATE SET name=EXCLUDED.name,address=EXCLUDED.address,phone=EXCLUDED.phone,updated_at=now(),updated_by=auth.uid();
END $$;
REVOKE ALL ON FUNCTION public.set_business_profile(text,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_business_profile(text,text,text) TO authenticated;

-- Active-account restrictive policies for the new tables (same pattern as 0006).
DO $$ DECLARE t text; BEGIN FOREACH t IN ARRAY ARRAY['suppliers','purchases','supplier_payments','expenses','retailer_returns','business_profile','doc_counters','processed_ops'] LOOP
  EXECUTE format('CREATE POLICY active_account_required ON public.%I AS RESTRICTIVE FOR ALL TO authenticated USING (public.user_is_active(auth.uid())) WITH CHECK (public.user_is_active(auth.uid()))',t);
END LOOP; END $$;

CREATE OR REPLACE FUNCTION public.supplier_due(_supplier uuid) RETURNS numeric
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  RETURN coalesce((SELECT sum(total - paid) FROM public.purchases WHERE supplier_id=_supplier),0)
       - coalesce((SELECT sum(amount) FROM public.supplier_payments WHERE supplier_id=_supplier),0);
END $$;
REVOKE ALL ON FUNCTION public.supplier_due(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.supplier_due(uuid) TO authenticated, service_role;

-- ---------- access guard understands the new movement kinds ----------
CREATE OR REPLACE FUNCTION public.guard_business_access() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ DECLARE target uuid; permission text; BEGIN
IF auth.uid() IS NULL OR NOT public.user_is_active(auth.uid()) THEN RAISE EXCEPTION 'Account inactive or unauthenticated'; END IF;
IF TG_TABLE_NAME='stock_movements' THEN
 IF TG_OP='INSERT' THEN target:=NEW.salesman_id; IF NOT public.user_is_active(target) THEN RAISE EXCEPTION 'Target account inactive'; END IF;
 permission:=CASE WHEN NEW.kind='sale' THEN 'sales' WHEN NEW.kind IN ('return','damage','sale_return') THEN 'returns' WHEN NEW.kind IN ('purchase','opening','adjustment') THEN 'stock_admin' ELSE 'issue_stock' END;
 IF permission='stock_admin' THEN
   IF NOT public.has_role(auth.uid(),'admin') THEN RAISE EXCEPTION 'Action permission denied'; END IF;
 ELSIF NOT public.user_can(auth.uid(),permission) THEN RAISE EXCEPTION 'Action permission denied'; END IF;
 END IF;
ELSIF TG_TABLE_NAME='sales' AND TG_OP='INSERT' THEN
 IF NOT public.user_can(auth.uid(),'sales') THEN RAISE EXCEPTION 'Sales permission denied'; END IF;
ELSIF TG_TABLE_NAME='retailers' THEN
 IF NOT public.user_can(auth.uid(),'retailer_manage') THEN RAISE EXCEPTION 'Retailer management permission denied'; END IF;
ELSIF TG_TABLE_NAME='retailer_payments' THEN
 IF NOT public.user_can(auth.uid(),'collect_payment') THEN RAISE EXCEPTION 'Collection permission denied'; END IF;
END IF;
IF TG_OP='DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF; END; $$;

-- ---------- sale: validated, priced, discounted, idempotent ----------
CREATE OR REPLACE FUNCTION public.record_sale(_retailer uuid, _items jsonb, _paid numeric, _discount numeric, _date date, _op uuid) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE it jsonb; p record; im text; n int; sid uuid; tot numeric := 0; me uuid := auth.uid(); price numeric; disc numeric := coalesce(_discount,0); lim numeric; due_after numeric; ucost numeric;
BEGIN
  PERFORM set_config('app.via_rpc','on',true);
  IF _op IS NOT NULL THEN SELECT id INTO sid FROM public.sales WHERE client_op_id=_op; IF sid IS NOT NULL THEN RETURN sid; END IF; END IF;
  IF disc < 0 THEN RAISE EXCEPTION 'Discount cannot be negative'; END IF;
  IF coalesce(_paid,0) < 0 THEN RAISE EXCEPTION 'Paid cannot be negative'; END IF;
  SELECT credit_limit INTO lim FROM public.retailers WHERE id=_retailer AND salesman_id=me;
  IF NOT FOUND THEN RAISE EXCEPTION 'retailer not yours'; END IF;
  INSERT INTO sales(salesman_id,retailer_id,total,paid,discount,invoice_no,client_op_id,txn_date)
    VALUES(me,_retailer,0,coalesce(_paid,0),disc,public.next_doc_no('invoice'),_op,coalesce(_date,(now() AT TIME ZONE 'Asia/Dhaka')::date)) RETURNING id INTO sid;
  FOR it IN SELECT * FROM jsonb_array_elements(_items) LOOP
    SELECT * INTO p FROM products WHERE id=(it->>'product_id')::uuid;
    price := coalesce((it->>'unit_price')::numeric, p.price);
    IF price <= 0 THEN RAISE EXCEPTION 'Unit price must be positive for %', p.name; END IF;
    IF p.is_smartphone THEN
      FOR im IN SELECT jsonb_array_elements_text(it->'imeis') LOOP
        UPDATE imei_units SET status='sold', retailer_id=_retailer
          WHERE imei=im AND product_id=p.id AND status='with_salesman' AND salesman_id=me;
        GET DIAGNOSTICS n = ROW_COUNT;
        IF n=0 THEN RAISE EXCEPTION 'IMEI % not with you', im; END IF;
        SELECT cost_price INTO ucost FROM imei_units WHERE imei=im;
        INSERT INTO stock_movements(salesman_id,product_id,kind,qty,unit_price,cost_price,imei,sale_id,retailer_id,txn_date)
          VALUES(me,p.id,'sale',1,price,coalesce(ucost,0),im,sid,_retailer,coalesce(_date,(now() AT TIME ZONE 'Asia/Dhaka')::date));
        tot := tot + price;
      END LOOP;
    ELSE
      n := (it->>'qty')::int;
      IF n<=0 OR public.holding_qty(me,p.id) < n THEN RAISE EXCEPTION 'Not enough % in hand', p.name; END IF;
      INSERT INTO stock_movements(salesman_id,product_id,kind,qty,unit_price,cost_price,sale_id,retailer_id,txn_date)
        VALUES(me,p.id,'sale',n,price,p.cost_price,sid,_retailer,coalesce(_date,(now() AT TIME ZONE 'Asia/Dhaka')::date));
      tot := tot + price*n;
    END IF;
  END LOOP;
  IF disc > tot THEN RAISE EXCEPTION 'Discount exceeds sale total'; END IF;
  tot := tot - disc;
  IF coalesce(_paid,0) > tot THEN RAISE EXCEPTION 'paid more than total'; END IF;
  IF lim IS NOT NULL THEN
    due_after := public.retailer_due(_retailer) + (tot - coalesce(_paid,0));
    IF due_after > lim THEN RAISE EXCEPTION 'Credit limit exceeded for this retailer'; END IF;
  END IF;
  UPDATE sales SET total=tot WHERE id=sid;
  RETURN sid;
END $$;

-- Backwards-compatible 3-argument signature delegates to the validated one.
CREATE OR REPLACE FUNCTION public.record_sale(_retailer uuid, _items jsonb, _paid numeric) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN RETURN public.record_sale(_retailer,_items,_paid,0,NULL,NULL); END $$;

-- ---------- issue / return with challan numbers + idempotency ----------
CREATE OR REPLACE FUNCTION public.issue_stock(_salesman uuid, _items jsonb, _date date, _op uuid) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE it jsonb; p record; im text; n int; batch text;
BEGIN
  PERFORM set_config('app.via_rpc','on',true);
  IF NOT public.has_role(auth.uid(),'admin') THEN RAISE EXCEPTION 'admin only'; END IF;
  IF _op IS NOT NULL THEN
    SELECT result_ref INTO batch FROM public.processed_ops WHERE client_op_id=_op;
    IF batch IS NOT NULL THEN RETURN batch; END IF;
  END IF;
  batch := public.next_doc_no('challan');
  FOR it IN SELECT * FROM jsonb_array_elements(_items) LOOP
    SELECT * INTO p FROM products WHERE id = (it->>'product_id')::uuid FOR UPDATE;
    IF p.is_smartphone THEN
      FOR im IN SELECT jsonb_array_elements_text(it->'imeis') LOOP
        UPDATE imei_units SET status='with_salesman', salesman_id=_salesman
          WHERE imei=im AND product_id=p.id AND status='in_stock';
        GET DIAGNOSTICS n = ROW_COUNT;
        IF n = 0 THEN RAISE EXCEPTION 'IMEI % not available', im; END IF;
        INSERT INTO stock_movements(salesman_id,product_id,kind,qty,unit_price,imei,batch_no,txn_date)
          VALUES(_salesman,p.id,'issue',1,p.price,im,batch,coalesce(_date,(now() AT TIME ZONE 'Asia/Dhaka')::date));
      END LOOP;
    ELSE
      n := (it->>'qty')::int;
      IF n <= 0 OR p.stock_qty < n THEN RAISE EXCEPTION 'Not enough stock for %', p.name; END IF;
      UPDATE products SET stock_qty = stock_qty - n WHERE id=p.id;
      INSERT INTO stock_movements(salesman_id,product_id,kind,qty,unit_price,batch_no,txn_date)
        VALUES(_salesman,p.id,'issue',n,p.price,batch,coalesce(_date,(now() AT TIME ZONE 'Asia/Dhaka')::date));
    END IF;
  END LOOP;
  IF _op IS NOT NULL THEN INSERT INTO public.processed_ops(client_op_id,kind,actor,result_ref) VALUES(_op,'issue',auth.uid(),batch); END IF;
  RETURN batch;
END $$;

CREATE OR REPLACE FUNCTION public.return_stock(_salesman uuid, _items jsonb, _date date, _op uuid) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE it jsonb; p record; im text; n int; dmg boolean; batch text;
BEGIN
  PERFORM set_config('app.via_rpc','on',true);
  IF NOT (public.has_role(auth.uid(),'admin') OR _salesman = auth.uid()) THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF _op IS NOT NULL THEN
    SELECT result_ref INTO batch FROM public.processed_ops WHERE client_op_id=_op;
    IF batch IS NOT NULL THEN RETURN batch; END IF;
  END IF;
  batch := public.next_doc_no('return_challan');
  FOR it IN SELECT * FROM jsonb_array_elements(_items) LOOP
    SELECT * INTO p FROM products WHERE id=(it->>'product_id')::uuid FOR UPDATE;
    dmg := coalesce((it->>'damaged')::boolean,false);
    IF p.is_smartphone THEN
      FOR im IN SELECT jsonb_array_elements_text(it->'imeis') LOOP
        UPDATE imei_units SET status = CASE WHEN dmg THEN 'damaged'::imei_status ELSE 'in_stock'::imei_status END,
          salesman_id = NULL
          WHERE imei=im AND product_id=p.id AND status='with_salesman' AND salesman_id=_salesman;
        GET DIAGNOSTICS n=ROW_COUNT;
        IF n=0 THEN RAISE EXCEPTION 'IMEI % not with this salesman', im; END IF;
        INSERT INTO stock_movements(salesman_id,product_id,kind,qty,unit_price,imei,batch_no,txn_date)
          VALUES(_salesman,p.id, CASE WHEN dmg THEN 'damage'::move_kind ELSE 'return'::move_kind END,1,p.price,im,batch,coalesce(_date,(now() AT TIME ZONE 'Asia/Dhaka')::date));
      END LOOP;
    ELSE
      n := (it->>'qty')::int;
      IF n<=0 OR public.holding_qty(_salesman,p.id) < n THEN RAISE EXCEPTION 'Return more than held for %', p.name; END IF;
      IF NOT dmg THEN UPDATE products SET stock_qty=stock_qty+n WHERE id=p.id; END IF;
      INSERT INTO stock_movements(salesman_id,product_id,kind,qty,unit_price,batch_no,txn_date)
        VALUES(_salesman,p.id, CASE WHEN dmg THEN 'damage'::move_kind ELSE 'return'::move_kind END,n,p.price,batch,coalesce(_date,(now() AT TIME ZONE 'Asia/Dhaka')::date));
    END IF;
  END LOOP;
  IF _op IS NOT NULL THEN INSERT INTO public.processed_ops(client_op_id,kind,actor,result_ref) VALUES(_op,'return',auth.uid(),batch); END IF;
  RETURN batch;
END $$;

-- Old void signatures delegate (result discarded).
CREATE OR REPLACE FUNCTION public.issue_stock(_salesman uuid, _items jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN PERFORM public.issue_stock(_salesman,_items,NULL,NULL); END $$;
CREATE OR REPLACE FUNCTION public.return_stock(_salesman uuid, _items jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN PERFORM public.return_stock(_salesman,_items,NULL,NULL); END $$;

-- ---------- collections & deposits as validated RPCs (no more raw inserts) ----------
CREATE OR REPLACE FUNCTION public.record_retailer_payment(_retailer uuid, _amount numeric, _method text, _note text, _date date, _op uuid) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE me uuid := auth.uid(); pid uuid; r record;
BEGIN
  IF _op IS NOT NULL THEN SELECT id INTO pid FROM public.retailer_payments WHERE client_op_id=_op; IF pid IS NOT NULL THEN RETURN pid; END IF; END IF;
  IF _amount IS NULL OR _amount <= 0 THEN RAISE EXCEPTION 'Positive amount required'; END IF;
  SELECT * INTO r FROM public.retailers WHERE id=_retailer;
  IF r.id IS NULL THEN RAISE EXCEPTION 'Retailer not found'; END IF;
  IF NOT (public.has_role(me,'admin') OR r.salesman_id = me) THEN RAISE EXCEPTION 'Retailer not yours'; END IF;
  IF _amount > public.retailer_due(_retailer) THEN RAISE EXCEPTION 'Amount exceeds retailer due'; END IF;
  INSERT INTO public.retailer_payments(salesman_id,retailer_id,amount,note,method,receipt_no,client_op_id,txn_date)
    VALUES(r.salesman_id,_retailer,_amount,_note,coalesce(_method,'cash'),public.next_doc_no('money_receipt'),_op,coalesce(_date,(now() AT TIME ZONE 'Asia/Dhaka')::date))
    RETURNING id INTO pid;
  RETURN pid;
END $$;
REVOKE ALL ON FUNCTION public.record_retailer_payment(uuid,numeric,text,text,date,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_retailer_payment(uuid,numeric,text,text,date,uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.record_deposit(_salesman uuid, _amount numeric, _method text, _note text, _date date, _op uuid) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE did uuid;
BEGIN
  IF NOT public.has_role(auth.uid(),'admin') THEN RAISE EXCEPTION 'Owner only'; END IF;
  IF _op IS NOT NULL THEN SELECT id INTO did FROM public.deposits WHERE client_op_id=_op; IF did IS NOT NULL THEN RETURN did; END IF; END IF;
  IF _amount IS NULL OR _amount <= 0 THEN RAISE EXCEPTION 'Positive amount required'; END IF;
  IF _amount > public.salesman_cash(_salesman) THEN RAISE EXCEPTION 'Deposit exceeds cash in hand'; END IF;
  INSERT INTO public.deposits(salesman_id,amount,note,method,receipt_no,client_op_id,txn_date,received_by)
    VALUES(_salesman,_amount,_note,coalesce(_method,'cash'),public.next_doc_no('deposit'),_op,coalesce(_date,(now() AT TIME ZONE 'Asia/Dhaka')::date),auth.uid())
    RETURNING id INTO did;
  RETURN did;
END $$;
REVOKE ALL ON FUNCTION public.record_deposit(uuid,numeric,text,text,date,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_deposit(uuid,numeric,text,text,date,uuid) TO authenticated;

-- ---------- purchases ----------
CREATE OR REPLACE FUNCTION public.record_purchase(_supplier uuid, _items jsonb, _paid numeric, _date date, _op uuid) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE it jsonb; p record; im text; n int; pid uuid; tot numeric := 0; cost numeric; d date := coalesce(_date,(now() AT TIME ZONE 'Asia/Dhaka')::date);
BEGIN
  PERFORM set_config('app.via_rpc','on',true);
  IF NOT public.has_role(auth.uid(),'admin') THEN RAISE EXCEPTION 'Owner only'; END IF;
  IF _op IS NOT NULL THEN SELECT id INTO pid FROM public.purchases WHERE client_op_id=_op; IF pid IS NOT NULL THEN RETURN pid; END IF; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.suppliers WHERE id=_supplier) THEN RAISE EXCEPTION 'Supplier not found'; END IF;
  INSERT INTO public.purchases(supplier_id,total,paid,doc_no,client_op_id,txn_date,created_by)
    VALUES(_supplier,0,coalesce(_paid,0),public.next_doc_no('purchase'),_op,d,auth.uid()) RETURNING id INTO pid;
  FOR it IN SELECT * FROM jsonb_array_elements(_items) LOOP
    SELECT * INTO p FROM products WHERE id=(it->>'product_id')::uuid FOR UPDATE;
    IF p.id IS NULL THEN RAISE EXCEPTION 'Product not found'; END IF;
    cost := coalesce((it->>'cost_price')::numeric, p.cost_price);
    IF cost < 0 THEN RAISE EXCEPTION 'Cost price cannot be negative'; END IF;
    IF p.is_smartphone THEN
      FOR im IN SELECT jsonb_array_elements_text(it->'imeis') LOOP
        INSERT INTO public.imei_units(product_id,imei,status,cost_price,supplier_id,purchase_id)
          VALUES(p.id,im,'in_stock',cost,_supplier,pid);
        INSERT INTO public.stock_movements(salesman_id,product_id,kind,qty,unit_price,cost_price,imei,batch_no,txn_date)
          VALUES(auth.uid(),p.id,'purchase',1,cost,cost,im,(SELECT doc_no FROM public.purchases WHERE id=pid),d);
        tot := tot + cost;
      END LOOP;
    ELSE
      n := (it->>'qty')::int;
      IF n <= 0 THEN RAISE EXCEPTION 'Quantity must be positive'; END IF;
      -- moving-average cost for non-IMEI stock
      UPDATE products SET cost_price = CASE WHEN stock_qty + n > 0 THEN round(((cost_price*stock_qty) + (cost*n)) / (stock_qty + n), 2) ELSE cost END,
                          stock_qty = stock_qty + n WHERE id=p.id;
      INSERT INTO public.stock_movements(salesman_id,product_id,kind,qty,unit_price,cost_price,batch_no,txn_date)
        VALUES(auth.uid(),p.id,'purchase',n,cost,cost,(SELECT doc_no FROM public.purchases WHERE id=pid),d);
      tot := tot + cost*n;
    END IF;
  END LOOP;
  IF coalesce(_paid,0) < 0 OR coalesce(_paid,0) > tot THEN RAISE EXCEPTION 'Paid must be between 0 and purchase total'; END IF;
  UPDATE public.purchases SET total=tot WHERE id=pid;
  RETURN pid;
END $$;
REVOKE ALL ON FUNCTION public.record_purchase(uuid,jsonb,numeric,date,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_purchase(uuid,jsonb,numeric,date,uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.record_supplier_payment(_supplier uuid, _amount numeric, _method text, _note text, _date date, _op uuid) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE pid uuid;
BEGIN
  IF NOT public.has_role(auth.uid(),'admin') THEN RAISE EXCEPTION 'Owner only'; END IF;
  IF _op IS NOT NULL THEN SELECT id INTO pid FROM public.supplier_payments WHERE client_op_id=_op; IF pid IS NOT NULL THEN RETURN pid; END IF; END IF;
  IF _amount IS NULL OR _amount <= 0 THEN RAISE EXCEPTION 'Positive amount required'; END IF;
  IF _amount > public.supplier_due(_supplier) THEN RAISE EXCEPTION 'Amount exceeds supplier due'; END IF;
  INSERT INTO public.supplier_payments(supplier_id,amount,method,note,doc_no,client_op_id,txn_date,created_by)
    VALUES(_supplier,_amount,coalesce(_method,'cash'),_note,public.next_doc_no('supplier_payment'),_op,coalesce(_date,(now() AT TIME ZONE 'Asia/Dhaka')::date),auth.uid())
    RETURNING id INTO pid;
  RETURN pid;
END $$;
REVOKE ALL ON FUNCTION public.record_supplier_payment(uuid,numeric,text,text,date,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_supplier_payment(uuid,numeric,text,text,date,uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.record_expense(_category text, _amount numeric, _note text, _date date, _op uuid) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE eid uuid;
BEGIN
  IF NOT public.has_role(auth.uid(),'admin') THEN RAISE EXCEPTION 'Owner only'; END IF;
  IF _op IS NOT NULL THEN SELECT id INTO eid FROM public.expenses WHERE client_op_id=_op; IF eid IS NOT NULL THEN RETURN eid; END IF; END IF;
  IF length(trim(coalesce(_category,''))) = 0 THEN RAISE EXCEPTION 'Category required'; END IF;
  IF _amount IS NULL OR _amount <= 0 THEN RAISE EXCEPTION 'Positive amount required'; END IF;
  INSERT INTO public.expenses(category,amount,note,doc_no,client_op_id,txn_date,created_by)
    VALUES(trim(_category),_amount,_note,public.next_doc_no('expense'),_op,coalesce(_date,(now() AT TIME ZONE 'Asia/Dhaka')::date),auth.uid())
    RETURNING id INTO eid;
  RETURN eid;
END $$;
REVOKE ALL ON FUNCTION public.record_expense(text,numeric,text,date,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_expense(text,numeric,text,date,uuid) TO authenticated;

-- ---------- stock intake that always writes a movement ----------
CREATE OR REPLACE FUNCTION public.receive_stock(_product uuid, _qty integer, _kind text, _reason text, _date date, _op uuid) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE p record; batch text; k move_kind; d date := coalesce(_date,(now() AT TIME ZONE 'Asia/Dhaka')::date);
BEGIN
  PERFORM set_config('app.via_rpc','on',true);
  IF NOT public.has_role(auth.uid(),'admin') THEN RAISE EXCEPTION 'Owner only'; END IF;
  IF _kind NOT IN ('opening','adjustment') THEN RAISE EXCEPTION 'Use purchase for bought stock'; END IF;
  IF _op IS NOT NULL THEN SELECT result_ref INTO batch FROM public.processed_ops WHERE client_op_id=_op; IF batch IS NOT NULL THEN RETURN batch; END IF; END IF;
  SELECT * INTO p FROM products WHERE id=_product FOR UPDATE;
  IF p.id IS NULL THEN RAISE EXCEPTION 'Product not found'; END IF;
  IF p.is_smartphone THEN RAISE EXCEPTION 'Register IMEIs for smartphones'; END IF;
  IF _qty IS NULL OR _qty = 0 THEN RAISE EXCEPTION 'Quantity required'; END IF;
  IF _kind='opening' AND _qty < 0 THEN RAISE EXCEPTION 'Opening quantity cannot be negative'; END IF;
  IF p.stock_qty + _qty < 0 THEN RAISE EXCEPTION 'Adjustment would make stock negative'; END IF;
  k := _kind::move_kind;
  batch := public.next_doc_no('challan');
  UPDATE products SET stock_qty = stock_qty + _qty WHERE id=p.id;
  INSERT INTO public.stock_movements(salesman_id,product_id,kind,qty,unit_price,batch_no,txn_date)
    VALUES(auth.uid(),p.id,k,(CASE WHEN _kind='adjustment' THEN _qty ELSE abs(_qty) END),p.cost_price,batch,d);
  INSERT INTO public.business_audit(actor,action,entity,entity_id,reason,before_data,after_data)
    VALUES(auth.uid(),'stock_'||_kind,'products',p.id,coalesce(_reason,_kind),jsonb_build_object('stock_qty',p.stock_qty),jsonb_build_object('stock_qty',p.stock_qty + _qty,'batch_no',batch));
  IF _op IS NOT NULL THEN INSERT INTO public.processed_ops(client_op_id,kind,actor,result_ref) VALUES(_op,_kind,auth.uid(),batch); END IF;
  RETURN batch;
END $$;
REVOKE ALL ON FUNCTION public.receive_stock(uuid,integer,text,text,date,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.receive_stock(uuid,integer,text,text,date,uuid) TO authenticated;

-- For adjustments the signed direction matters to the warehouse count; keep a signed copy in audit only.
-- (stock_qty itself is updated by the signed amount above; the movement stores the absolute quantity
--  with its kind so warehouse reports can add openings and net adjustments via business_audit when needed.)

CREATE OR REPLACE FUNCTION public.register_imeis(_product uuid, _imeis text[], _cost numeric) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE im text; n int := 0; p record;
BEGIN
  PERFORM set_config('app.via_rpc','on',true);
  IF NOT public.has_role(auth.uid(),'admin') THEN RAISE EXCEPTION 'Owner only'; END IF;
  SELECT * INTO p FROM products WHERE id=_product;
  IF p.id IS NULL OR NOT p.is_smartphone THEN RAISE EXCEPTION 'Smartphone product required'; END IF;
  FOREACH im IN ARRAY _imeis LOOP
    INSERT INTO public.imei_units(product_id,imei,status,cost_price) VALUES(p.id,trim(im),'in_stock',coalesce(_cost,0));
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;
REVOKE ALL ON FUNCTION public.register_imeis(uuid,text[],numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.register_imeis(uuid,text[],numeric) TO authenticated;

-- ---------- retailer sales return (credit note against the ledger) ----------
CREATE OR REPLACE FUNCTION public.record_retailer_return(_retailer uuid, _items jsonb, _date date, _op uuid) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE it jsonb; p record; im text; n int; rid uuid; tot numeric := 0; me uuid := auth.uid(); price numeric; sid uuid; d date := coalesce(_date,(now() AT TIME ZONE 'Asia/Dhaka')::date); sold_qty int; ret_qty int; ucost numeric;
BEGIN
  PERFORM set_config('app.via_rpc','on',true);
  IF _op IS NOT NULL THEN SELECT id INTO rid FROM public.retailer_returns WHERE client_op_id=_op; IF rid IS NOT NULL THEN RETURN rid; END IF; END IF;
  IF NOT EXISTS(SELECT 1 FROM retailers WHERE id=_retailer AND salesman_id=me) AND NOT public.has_role(me,'admin') THEN RAISE EXCEPTION 'retailer not yours'; END IF;
  INSERT INTO public.retailer_returns(retailer_id,salesman_id,total,doc_no,client_op_id,txn_date)
    VALUES(_retailer,me,0,public.next_doc_no('sale_return'),_op,d) RETURNING id INTO rid;
  FOR it IN SELECT * FROM jsonb_array_elements(_items) LOOP
    SELECT * INTO p FROM products WHERE id=(it->>'product_id')::uuid;
    price := coalesce((it->>'unit_price')::numeric, p.price);
    IF price < 0 THEN RAISE EXCEPTION 'Return price cannot be negative'; END IF;
    IF p.is_smartphone THEN
      FOR im IN SELECT jsonb_array_elements_text(it->'imeis') LOOP
        sid := NULL;
        SELECT sale_id INTO sid FROM stock_movements WHERE imei=im AND kind='sale' ORDER BY created_at DESC LIMIT 1;
        UPDATE imei_units SET status='with_salesman', retailer_id=NULL
          WHERE imei=im AND product_id=p.id AND status='sold' AND retailer_id=_retailer;
        GET DIAGNOSTICS n = ROW_COUNT;
        IF n=0 THEN RAISE EXCEPTION 'IMEI % was not sold to this retailer', im; END IF;
        SELECT cost_price INTO ucost FROM imei_units WHERE imei=im;
        INSERT INTO stock_movements(salesman_id,product_id,kind,qty,unit_price,cost_price,imei,sale_id,retailer_id,batch_no,txn_date)
          VALUES(me,p.id,'sale_return',1,price,coalesce(ucost,0),im,sid,_retailer,(SELECT doc_no FROM public.retailer_returns WHERE id=rid),d);
        tot := tot + price;
      END LOOP;
    ELSE
      n := (it->>'qty')::int;
      IF n <= 0 THEN RAISE EXCEPTION 'Quantity must be positive'; END IF;
      SELECT coalesce(sum(qty),0) INTO sold_qty FROM stock_movements WHERE kind='sale' AND retailer_id=_retailer AND product_id=p.id;
      SELECT coalesce(sum(qty),0) INTO ret_qty FROM stock_movements WHERE kind='sale_return' AND retailer_id=_retailer AND product_id=p.id;
      IF ret_qty + n > sold_qty THEN RAISE EXCEPTION 'Return more than sold for %', p.name; END IF;
      INSERT INTO stock_movements(salesman_id,product_id,kind,qty,unit_price,cost_price,retailer_id,batch_no,txn_date)
        VALUES(me,p.id,'sale_return',n,price,p.cost_price,_retailer,(SELECT doc_no FROM public.retailer_returns WHERE id=rid),d);
      tot := tot + price*n;
    END IF;
  END LOOP;
  UPDATE public.retailer_returns SET total=tot, sale_id=(SELECT sale_id FROM stock_movements WHERE batch_no=(SELECT doc_no FROM public.retailer_returns WHERE id=rid) AND sale_id IS NOT NULL LIMIT 1) WHERE id=rid;
  IF tot > public.retailer_due(_retailer) + tot THEN RAISE EXCEPTION 'Return exceeds retailer due'; END IF;
  RETURN rid;
END $$;
REVOKE ALL ON FUNCTION public.record_retailer_return(uuid,jsonb,date,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_retailer_return(uuid,jsonb,date,uuid) TO authenticated;

-- Grants for the new overloads (Postgres grants EXECUTE to PUBLIC by default).
REVOKE ALL ON FUNCTION public.record_sale(uuid,jsonb,numeric,numeric,date,uuid),
  public.issue_stock(uuid,jsonb,date,uuid), public.return_stock(uuid,jsonb,date,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_sale(uuid,jsonb,numeric,numeric,date,uuid),
  public.issue_stock(uuid,jsonb,date,uuid), public.return_stock(uuid,jsonb,date,uuid) TO authenticated;

-- ---------- reporting: returns-aware, business-date based, cost-valued ----------
CREATE OR REPLACE FUNCTION public.distribution_dashboard() RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
WITH s AS (SELECT salesman_id, sum(total) total, sum(paid) paid FROM public.sales GROUP BY salesman_id),
p AS (SELECT salesman_id, sum(amount) amount FROM public.retailer_payments GROUP BY salesman_id),
d AS (SELECT salesman_id, sum(amount) amount FROM public.deposits GROUP BY salesman_id),
rt AS (SELECT salesman_id, sum(total) amount FROM public.retailer_returns GROUP BY salesman_id),
i AS (SELECT count(*) FILTER (WHERE status='in_stock') stock, count(*) FILTER (WHERE status='with_salesman') held, count(*) FILTER (WHERE status='damaged') damaged FROM public.imei_units)
SELECT jsonb_build_object('inStock',i.stock,'withSales',i.held,'damaged',i.damaged,
'salesTotal',coalesce((SELECT sum(total) FROM s),0),
'due',coalesce((SELECT sum(total-paid) FROM s),0)-coalesce((SELECT sum(amount) FROM p),0)-coalesce((SELECT sum(amount) FROM rt),0),
'deposited',coalesce((SELECT sum(amount) FROM d),0),
'returnsTotal',coalesce((SELECT sum(amount) FROM rt),0),
'salesBy',coalesce((SELECT jsonb_object_agg(salesman_id,total) FROM s),'{}'::jsonb),
'paidBy',coalesce((SELECT jsonb_object_agg(salesman_id,paid) FROM s),'{}'::jsonb),
'collectedBy',coalesce((SELECT jsonb_object_agg(salesman_id,amount) FROM p),'{}'::jsonb),
'depBy',coalesce((SELECT jsonb_object_agg(salesman_id,amount) FROM d),'{}'::jsonb)) FROM i;
$$;

CREATE OR REPLACE FUNCTION public.distribution_insights() RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path=public AS $$
WITH payment_totals AS (SELECT retailer_id,sum(amount) amount FROM public.retailer_payments GROUP BY retailer_id),
return_totals AS (SELECT retailer_id,sum(total) amount FROM public.retailer_returns GROUP BY retailer_id),
invoice_balances AS (
 SELECT s.id,s.retailer_id,s.txn_date,greatest(s.total-s.paid,0) balance,
 coalesce(p.amount,0) payments, coalesce(rt.amount,0) returns_total,
 coalesce(sum(greatest(s.total-s.paid,0)) OVER (PARTITION BY s.retailer_id ORDER BY s.txn_date,s.created_at,s.id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0) prior_balance
 FROM public.sales s LEFT JOIN payment_totals p ON p.retailer_id=s.retailer_id LEFT JOIN return_totals rt ON rt.retailer_id=s.retailer_id
), outstanding AS (
 SELECT *, greatest(balance-greatest(payments+returns_total-prior_balance,0),0) remaining FROM invoice_balances
), aged AS (
 SELECT o.retailer_id,sum(o.remaining) total_due,
 sum(o.remaining) FILTER (WHERE o.txn_date <= ((now() AT TIME ZONE 'Asia/Dhaka')::date - r.due_days)) overdue_amount,
 min(o.txn_date) FILTER (WHERE o.remaining>0) oldest
 FROM outstanding o JOIN public.retailers r ON r.id=o.retailer_id GROUP BY o.retailer_id, r.due_days HAVING sum(o.remaining)>0
), overdue AS (
 SELECT r.id,r.name,r.phone,r.address,r.salesman_id,p.full_name salesman_name,
 a.total_due,a.overdue_amount,(((now() AT TIME ZONE 'Asia/Dhaka')::date - a.oldest))::integer age_days
 FROM aged a JOIN public.retailers r ON r.id=a.retailer_id LEFT JOIN public.profiles p ON p.id=r.salesman_id
 WHERE a.overdue_amount>0 ORDER BY a.oldest,r.name
), stock AS (
 SELECT p.id,p.name,p.model,p.price,p.cost_price,p.low_stock_threshold,
 CASE WHEN p.is_smartphone THEN (SELECT count(*) FROM public.imei_units i WHERE i.product_id=p.id AND i.status='in_stock') ELSE p.stock_qty END qty,
 CASE WHEN p.is_smartphone THEN (SELECT coalesce(sum(i.cost_price),0) FROM public.imei_units i WHERE i.product_id=p.id AND i.status='in_stock') ELSE p.stock_qty*p.cost_price END cost_value
 FROM public.products p
), moves AS (
 SELECT coalesce(sum(CASE WHEN kind IN ('issue','sale_return') THEN qty WHEN kind IN ('sale','return','damage') THEN -qty ELSE 0 END),0) held,
 coalesce(sum(CASE WHEN kind IN ('issue','sale_return') THEN qty*unit_price WHEN kind IN ('sale','return','damage') THEN -qty*unit_price ELSE 0 END),0) held_value,
 coalesce(sum(qty) FILTER (WHERE kind='return'),0) returned,
 coalesce(sum(qty) FILTER (WHERE kind='damage'),0) damaged
 FROM public.stock_movements
), sales_kpis AS (
 SELECT coalesce(sum(total),0) total,coalesce(sum(paid),0) paid,
 coalesce(sum(total) FILTER (WHERE txn_date=(now() AT TIME ZONE 'Asia/Dhaka')::date),0) today_sales,
 coalesce(sum(total) FILTER (WHERE date_trunc('month',txn_date)=date_trunc('month',(now() AT TIME ZONE 'Asia/Dhaka')::date)),0) month_sales,
 count(*) invoices FROM public.sales
), totals AS (
 SELECT coalesce((SELECT sum(amount) FROM public.retailer_payments),0) collected,
 coalesce((SELECT sum(amount) FROM public.deposits),0) deposited,
 coalesce((SELECT sum(total) FROM public.retailer_returns),0) returns_total
)
SELECT jsonb_build_object(
 'overdue',coalesce((SELECT jsonb_agg(to_jsonb(o) ORDER BY o.age_days DESC,o.name) FROM overdue o),'[]'::jsonb),
 'overdueTotal',coalesce((SELECT sum(overdue_amount) FROM overdue),0),
 'lowStock',CASE WHEN public.has_role(auth.uid(),'admin') THEN coalesce((SELECT jsonb_agg(to_jsonb(st) ORDER BY st.qty,st.name) FROM stock st WHERE st.qty<st.low_stock_threshold),'[]'::jsonb) ELSE '[]'::jsonb END,
 'warehouseQty',CASE WHEN public.has_role(auth.uid(),'admin') THEN (SELECT coalesce(sum(qty),0) FROM stock) ELSE NULL END,
 'warehouseValue',CASE WHEN public.has_role(auth.uid(),'admin') THEN (SELECT coalesce(sum(cost_value),0) FROM stock) ELSE NULL END,
 'warehouseRetailValue',CASE WHEN public.has_role(auth.uid(),'admin') THEN (SELECT coalesce(sum(qty*price),0) FROM stock) ELSE NULL END,
 'todaySales',s.today_sales,'monthSales',s.month_sales,'salesTotal',s.total,'invoiceCount',s.invoices,
 'collected',s.paid+t.collected,'cashInHand',s.paid+t.collected-t.deposited,'deposited',t.deposited,
 'retailerDue',s.total-s.paid-t.collected-t.returns_total,'returnsTotal',t.returns_total,
 'heldQty',m.held,'heldValue',m.held_value,'returnedQty',m.returned,'damagedQty',m.damaged,
 'retailerCount',(SELECT count(*) FROM public.retailers),
 'activeSalesmen',(SELECT count(*) FROM public.profiles pr JOIN public.user_roles ur ON ur.user_id=pr.id WHERE ur.role='salesman' AND pr.active)
) FROM moves m CROSS JOIN sales_kpis s CROSS JOIN totals t;
$$;

CREATE OR REPLACE FUNCTION public.dealer_risk_history() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path=public AS $$
DECLARE result jsonb;
BEGIN
 IF NOT public.has_role(auth.uid(),'admin') THEN RAISE EXCEPTION 'Owner only'; END IF;
 WITH payments AS(SELECT retailer_id,sum(amount) amount,max(created_at) last_payment,count(*) payment_count FROM retailer_payments GROUP BY retailer_id),
 returns_t AS(SELECT retailer_id,sum(total) amount FROM retailer_returns GROUP BY retailer_id),
 invoices AS(SELECT s.*,coalesce(p.amount,0)+coalesce(rt.amount,0) settled,coalesce(sum(greatest(s.total-s.paid,0)) OVER(PARTITION BY s.retailer_id ORDER BY s.txn_date,s.created_at,s.id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0) prior FROM sales s LEFT JOIN payments p ON p.retailer_id=s.retailer_id LEFT JOIN returns_t rt ON rt.retailer_id=s.retailer_id),
 balances AS(SELECT *,greatest(greatest(total-paid,0)-greatest(settled-prior,0),0) remaining FROM invoices),
 totals AS(SELECT retailer_id,count(*) invoice_count,sum(total) sales_total,sum(paid) paid_at_sale,sum(remaining) total_due,coalesce(sum(remaining) FILTER(WHERE txn_date<=((now() AT TIME ZONE 'Asia/Dhaka')::date - 30)),0) overdue_amount,coalesce(((now() AT TIME ZONE 'Asia/Dhaka')::date - min(txn_date) FILTER(WHERE remaining>0)),0) age_days,max(created_at) last_sale FROM balances GROUP BY retailer_id),
 returns AS(SELECT retailer_id,sum(qty) return_qty,sum(qty*unit_price) return_value FROM stock_movements WHERE kind IN('return','damage','sale_return') AND retailer_id IS NOT NULL GROUP BY retailer_id)
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',r.id,'name',r.name,'phone',r.phone,'salesman_name',pr.full_name,'invoice_count',coalesce(t.invoice_count,0),'sales_total',coalesce(t.sales_total,0),'paid_at_sale',coalesce(t.paid_at_sale,0),'collected',coalesce(p.amount,0),'payment_count',coalesce(p.payment_count,0),'last_payment',p.last_payment,'last_sale',t.last_sale,'total_due',coalesce(t.total_due,0),'overdue_amount',coalesce(t.overdue_amount,0),'age_days',coalesce(t.age_days,0),'linked_return_qty',coalesce(rt.return_qty,0),'linked_return_value',coalesce(rt.return_value,0),'unattributed_return_count',(SELECT count(*) FROM stock_movements WHERE kind IN('return','damage') AND retailer_id IS NULL AND salesman_id=r.salesman_id),'blocked',coalesce(b.blocked,false)) ORDER BY r.id),'[]'::jsonb) INTO result FROM retailers r LEFT JOIN profiles pr ON pr.id=r.salesman_id LEFT JOIN totals t ON t.retailer_id=r.id LEFT JOIN payments p ON p.retailer_id=r.id LEFT JOIN returns rt ON rt.retailer_id=r.id LEFT JOIN dealer_blocks b ON b.retailer_id=r.id;
 RETURN result;
END $$;

-- ---------- server-side retailer ledgers (no more browser summation) ----------
CREATE OR REPLACE FUNCTION public.retailer_ledgers() RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path=public AS $$
SELECT coalesce(jsonb_agg(row ORDER BY row->>'name'),'[]'::jsonb) FROM (
  SELECT jsonb_build_object(
    'id',r.id,'name',r.name,'phone',r.phone,'address',r.address,'salesman_id',r.salesman_id,
    'credit_limit',r.credit_limit,'due_days',r.due_days,
    'sales_total',coalesce(s.total,0),'paid_at_sale',coalesce(s.paid,0),
    'collected',coalesce(p.amount,0),'returns_total',coalesce(rt.amount,0),
    'due',coalesce(s.total,0)-coalesce(s.paid,0)-coalesce(p.amount,0)-coalesce(rt.amount,0)
  ) row
  FROM public.retailers r
  LEFT JOIN (SELECT retailer_id,sum(total) total,sum(paid) paid FROM public.sales GROUP BY retailer_id) s ON s.retailer_id=r.id
  LEFT JOIN (SELECT retailer_id,sum(amount) amount FROM public.retailer_payments GROUP BY retailer_id) p ON p.retailer_id=r.id
  LEFT JOIN (SELECT retailer_id,sum(total) amount FROM public.retailer_returns GROUP BY retailer_id) rt ON rt.retailer_id=r.id
) x;
$$;
REVOKE ALL ON FUNCTION public.retailer_ledgers() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.retailer_ledgers() TO authenticated, service_role;

-- ---------- profit & loss for a period ----------
CREATE OR REPLACE FUNCTION public.profit_summary(_from date, _to date) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path=public AS $$
DECLARE res jsonb;
BEGIN
 IF NOT public.has_role(auth.uid(),'admin') THEN RAISE EXCEPTION 'Owner only'; END IF;
 SELECT jsonb_build_object(
   'sales_total', coalesce((SELECT sum(total) FROM public.sales WHERE txn_date BETWEEN _from AND _to),0),
   'discount_total', coalesce((SELECT sum(discount) FROM public.sales WHERE txn_date BETWEEN _from AND _to),0),
   'returns_total', coalesce((SELECT sum(total) FROM public.retailer_returns WHERE txn_date BETWEEN _from AND _to),0),
   'cogs', coalesce((SELECT sum(qty*coalesce(cost_price,0)) FROM public.stock_movements WHERE kind='sale' AND txn_date BETWEEN _from AND _to),0)
          - coalesce((SELECT sum(qty*coalesce(cost_price,0)) FROM public.stock_movements WHERE kind='sale_return' AND txn_date BETWEEN _from AND _to),0),
   'expenses_total', coalesce((SELECT sum(amount) FROM public.expenses WHERE txn_date BETWEEN _from AND _to),0),
   'purchases_total', coalesce((SELECT sum(total) FROM public.purchases WHERE txn_date BETWEEN _from AND _to),0),
   'supplier_due', coalesce((SELECT sum(total-paid) FROM public.purchases),0) - coalesce((SELECT sum(amount) FROM public.supplier_payments),0)
 ) INTO res;
 SELECT res || jsonb_build_object(
   'net_sales', (res->>'sales_total')::numeric - (res->>'returns_total')::numeric,
   'gross_profit', (res->>'sales_total')::numeric - (res->>'returns_total')::numeric - (res->>'cogs')::numeric,
   'net_profit', (res->>'sales_total')::numeric - (res->>'returns_total')::numeric - (res->>'cogs')::numeric - (res->>'expenses_total')::numeric
 ) INTO res;
 RETURN res;
END $$;
REVOKE ALL ON FUNCTION public.profit_summary(date,date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.profit_summary(date,date) TO authenticated;
