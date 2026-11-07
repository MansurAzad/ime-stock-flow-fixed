-- 0012: integrity guards. Direct client writes can no longer move stock or
-- money around the validated RPCs; history functions get a fair FIFO rule.

-- First-user-admin race: serialize account creation role assignment.
CREATE OR REPLACE FUNCTION public.handle_new_user() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(9142027);
  INSERT INTO public.profiles(id, full_name, phone)
  VALUES (new.id, coalesce(new.raw_user_meta_data->>'full_name',''), new.raw_user_meta_data->>'phone');
  IF NOT EXISTS (SELECT 1 FROM public.user_roles WHERE role='admin') THEN
    INSERT INTO public.user_roles(user_id, role) VALUES (new.id,'admin');
  ELSE
    INSERT INTO public.user_roles(user_id, role) VALUES (new.id,'salesman');
  END IF;
  RETURN new;
END $$;

-- Referential integrity for salesman references (NOT VALID: enforced for new
-- rows immediately; run VALIDATE CONSTRAINT after cleaning any legacy orphans).
ALTER TABLE public.retailers ADD CONSTRAINT retailers_salesman_fk FOREIGN KEY (salesman_id) REFERENCES public.profiles(id) NOT VALID;
ALTER TABLE public.sales ADD CONSTRAINT sales_salesman_fk FOREIGN KEY (salesman_id) REFERENCES public.profiles(id) NOT VALID;
ALTER TABLE public.stock_movements ADD CONSTRAINT movements_salesman_fk FOREIGN KEY (salesman_id) REFERENCES public.profiles(id) NOT VALID;
ALTER TABLE public.retailer_payments ADD CONSTRAINT payments_salesman_fk FOREIGN KEY (salesman_id) REFERENCES public.profiles(id) NOT VALID;
ALTER TABLE public.deposits ADD CONSTRAINT deposits_salesman_fk FOREIGN KEY (salesman_id) REFERENCES public.profiles(id) NOT VALID;
ALTER TABLE public.imei_units ADD CONSTRAINT imei_salesman_fk FOREIGN KEY (salesman_id) REFERENCES public.profiles(id) NOT VALID;
ALTER TABLE public.retailer_returns ADD CONSTRAINT returns_salesman_fk FOREIGN KEY (salesman_id) REFERENCES public.profiles(id) NOT VALID;

-- Stock write guard: stock_qty and IMEI state may only change inside the
-- validated SECURITY DEFINER functions (which set app.via_rpc) or by the
-- database owner / service role (backup restore, maintenance).
CREATE OR REPLACE FUNCTION public.stock_write_allowed() RETURNS boolean
LANGUAGE sql STABLE SET search_path = public AS $$
  SELECT coalesce(current_setting('app.via_rpc', true),'') = 'on' OR current_user NOT IN ('authenticated','anon');
$$;

-- NOTE: these guard triggers are deliberately NOT security definer, so that
-- current_user inside them reflects how the write arrived (API role vs RPC).
CREATE OR REPLACE FUNCTION public.guard_product_stock() RETURNS trigger
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.stock_qty <> 0 AND NOT public.stock_write_allowed() THEN
      RAISE EXCEPTION 'Opening stock must be entered through receive_stock or a purchase';
    END IF;
    RETURN NEW;
  ELSIF TG_OP = 'UPDATE' THEN
    IF NEW.stock_qty IS DISTINCT FROM OLD.stock_qty AND NOT public.stock_write_allowed() THEN
      RAISE EXCEPTION 'Stock quantity can only change through validated stock functions';
    END IF;
    RETURN NEW;
  ELSE
    IF (EXISTS(SELECT 1 FROM public.imei_units WHERE product_id=OLD.id) OR EXISTS(SELECT 1 FROM public.stock_movements WHERE product_id=OLD.id))
       AND NOT public.stock_write_allowed() THEN
      RAISE EXCEPTION 'Product has stock or history; cannot delete';
    END IF;
    RETURN OLD;
  END IF;
END $$;
CREATE TRIGGER product_stock_guard BEFORE INSERT OR UPDATE OR DELETE ON public.products FOR EACH ROW EXECUTE FUNCTION public.guard_product_stock();

CREATE OR REPLACE FUNCTION public.guard_imei_state() RETURNS trigger
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NOT public.stock_write_allowed() THEN RAISE EXCEPTION 'IMEIs must be registered through register_imeis or a purchase'; END IF;
    RETURN NEW;
  ELSE
    IF (NEW.status IS DISTINCT FROM OLD.status OR NEW.salesman_id IS DISTINCT FROM OLD.salesman_id OR NEW.retailer_id IS DISTINCT FROM OLD.retailer_id)
       AND NOT public.stock_write_allowed() THEN
      RAISE EXCEPTION 'IMEI state can only change through validated stock functions';
    END IF;
    RETURN NEW;
  END IF;
END $$;
CREATE TRIGGER imei_state_guard BEFORE INSERT OR UPDATE ON public.imei_units FOR EACH ROW EXECUTE FUNCTION public.guard_imei_state();

-- Money tables are written only by their RPCs from now on.
REVOKE INSERT ON public.retailer_payments FROM authenticated;
REVOKE INSERT ON public.deposits FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.imei_units FROM authenticated;

-- manage_business_record re-issued: payment edits now respect retailer sales returns.
CREATE OR REPLACE FUNCTION public.manage_business_record(_table text,_id uuid,_action text,_values jsonb,_reason text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ DECLARE old jsonb; updated jsonb; owner boolean:=public.has_role(auth.uid(),'admin'); r record; BEGIN
IF auth.uid() IS NULL OR length(trim(_reason))<3 OR _action NOT IN ('update','delete') THEN RAISE EXCEPTION 'Valid reason and authentication required'; END IF;
IF NOT owner AND _table<>'retailers' THEN RAISE EXCEPTION 'Owner only'; END IF;
IF _table='products' THEN
 SELECT to_jsonb(p) INTO old FROM products p WHERE id=_id FOR UPDATE;
 IF _action='delete' THEN
 IF EXISTS(SELECT 1 FROM stock_movements WHERE product_id=_id) OR EXISTS(SELECT 1 FROM imei_units WHERE product_id=_id) OR coalesce((old->>'stock_qty')::int,0)<>0 THEN RAISE EXCEPTION 'Product has stock or history; cannot delete'; END IF;
 DELETE FROM products WHERE id=_id;
 ELSE
 IF length(trim(_values->>'name'))=0 OR (_values->>'price')::numeric<0 THEN RAISE EXCEPTION 'Invalid product name or price'; END IF;
 UPDATE products SET name=trim(_values->>'name'),model=nullif(_values->>'model',''),price=(_values->>'price')::numeric WHERE id=_id RETURNING to_jsonb(products.*) INTO updated;
 END IF;
ELSIF _table='retailers' THEN
 SELECT to_jsonb(t) INTO old FROM retailers t WHERE id=_id AND (owner OR salesman_id=auth.uid()) FOR UPDATE;
 IF old IS NULL THEN RAISE EXCEPTION 'Retailer not available'; END IF;
 IF _action='delete' THEN
 IF EXISTS(SELECT 1 FROM sales WHERE retailer_id=_id) OR EXISTS(SELECT 1 FROM retailer_payments WHERE retailer_id=_id) OR EXISTS(SELECT 1 FROM stock_movements WHERE retailer_id=_id) OR EXISTS(SELECT 1 FROM dealer_blocks WHERE retailer_id=_id) OR EXISTS(SELECT 1 FROM dealer_risk_assessments WHERE retailer_id=_id) THEN RAISE EXCEPTION 'Retailer has history; cannot delete'; END IF;
 DELETE FROM retailers WHERE id=_id;
 ELSE
 IF length(trim(_values->>'name'))=0 THEN RAISE EXCEPTION 'Name required'; END IF;
 UPDATE retailers SET name=trim(_values->>'name'),phone=_values->>'phone',address=_values->>'address' WHERE id=_id RETURNING to_jsonb(retailers.*) INTO updated;
 END IF;
ELSIF _table='profiles' THEN
 SELECT to_jsonb(p) INTO old FROM profiles p WHERE id=_id FOR UPDATE;
 IF NOT public.has_role(_id,'salesman') THEN RAISE EXCEPTION 'Only salesman profiles can be managed'; END IF;
 IF _action='delete' THEN
 IF EXISTS(SELECT 1 FROM stock_movements WHERE salesman_id=_id) OR EXISTS(SELECT 1 FROM sales WHERE salesman_id=_id) OR EXISTS(SELECT 1 FROM retailers WHERE salesman_id=_id) OR EXISTS(SELECT 1 FROM deposits WHERE salesman_id=_id) THEN RAISE EXCEPTION 'Salesman has history; reconcile and deactivate instead'; END IF;
 UPDATE profiles SET active=false WHERE id=_id RETURNING to_jsonb(profiles.*) INTO updated;
 ELSE
 IF length(trim(_values->>'full_name'))=0 THEN RAISE EXCEPTION 'Name required'; END IF;
 UPDATE profiles SET full_name=trim(_values->>'full_name'),phone=_values->>'phone' WHERE id=_id RETURNING to_jsonb(profiles.*) INTO updated;
 END IF;
ELSIF _table IN ('sales','stock_movements') THEN
 RAISE EXCEPTION 'Stock and sales history cannot be rewritten; use validated sale/return/issue functions';
ELSIF _table IN ('retailer_payments','deposits') THEN
 IF _table='retailer_payments' THEN
 SELECT * INTO r FROM retailer_payments WHERE id=_id FOR UPDATE; old:=to_jsonb(r);
 IF _action='delete' THEN DELETE FROM retailer_payments WHERE id=_id;
 ELSE
 IF (_values->>'amount')::numeric<=0 OR (_values->>'amount') IS NULL THEN RAISE EXCEPTION 'Positive amount required'; END IF;
 IF (_values->>'amount')::numeric>(SELECT coalesce(sum(total-paid),0) FROM sales WHERE retailer_id=r.retailer_id)-(SELECT coalesce(sum(amount),0) FROM retailer_payments WHERE retailer_id=r.retailer_id AND id<>_id)-(SELECT coalesce(sum(total),0) FROM retailer_returns WHERE retailer_id=r.retailer_id) THEN RAISE EXCEPTION 'Amount exceeds retailer due'; END IF;
 UPDATE retailer_payments SET amount=(_values->>'amount')::numeric,note=_values->>'note' WHERE id=_id RETURNING to_jsonb(retailer_payments.*) INTO updated;
 END IF;
 ELSE
 SELECT * INTO r FROM deposits WHERE id=_id FOR UPDATE; old:=to_jsonb(r);
 IF _action='delete' THEN DELETE FROM deposits WHERE id=_id;
 ELSE
 IF (_values->>'amount')::numeric<=0 OR (_values->>'amount') IS NULL THEN RAISE EXCEPTION 'Positive amount required'; END IF;
 UPDATE deposits SET amount=(_values->>'amount')::numeric,note=_values->>'note' WHERE id=_id RETURNING to_jsonb(deposits.*) INTO updated;
 END IF;
 END IF;
ELSIF _table='imei_units' THEN
 SELECT to_jsonb(t) INTO old FROM imei_units t WHERE id=_id FOR UPDATE;
 IF old->>'status'<>'in_stock' OR EXISTS(SELECT 1 FROM stock_movements WHERE imei=old->>'imei') THEN RAISE EXCEPTION 'IMEI has history or is not in stock'; END IF;
 IF _action<>'delete' THEN RAISE EXCEPTION 'Delete unused IMEI then register the correct IMEI'; END IF;
 DELETE FROM imei_units WHERE id=_id;
ELSE RAISE EXCEPTION 'Unsupported list'; END IF;
IF old IS NULL THEN RAISE EXCEPTION 'Record not found'; END IF;
INSERT INTO business_audit(actor,action,entity,entity_id,reason,before_data,after_data) VALUES(auth.uid(),_action,_table,_id,_reason,old,updated);
END; $$;

-- cancel_business_history re-issued: an invoice may be cancelled when later FIFO settlements
-- do not yet reach it (the old rule blocked on ANY payment by the retailer, for any invoice).
CREATE OR REPLACE FUNCTION public.cancel_business_history(_table text,_id uuid,_reason text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ DECLARE r record; m record; p record; old jsonb; BEGIN
IF NOT public.has_role(auth.uid(),'admin') OR length(trim(_reason))<3 THEN RAISE EXCEPTION 'Owner and reason required'; END IF;
LOCK TABLE products,retailers,imei_units,sales,stock_movements,retailer_payments,deposits,dealer_blocks,dealer_risk_assessments IN SHARE ROW EXCLUSIVE MODE;
IF _table='sales' THEN
 SELECT * INTO r FROM sales WHERE id=_id FOR UPDATE; IF r.id IS NULL THEN RAISE EXCEPTION 'Invoice not found'; END IF;
 IF (SELECT coalesce(sum(amount),0) FROM retailer_payments WHERE retailer_id=r.retailer_id) + (SELECT coalesce(sum(total),0) FROM retailer_returns WHERE retailer_id=r.retailer_id)
      > (SELECT coalesce(sum(greatest(total-paid,0)),0) FROM sales WHERE retailer_id=r.retailer_id AND (txn_date,created_at,id) < (r.txn_date,r.created_at,r.id))
   THEN RAISE EXCEPTION 'Payments or returns already cover this invoice; reconcile them before cancelling invoice'; END IF;
 IF EXISTS(SELECT 1 FROM stock_movements WHERE sale_id=_id AND kind='sale_return') THEN RAISE EXCEPTION 'Invoice has sales returns; reconcile them before cancelling invoice'; END IF;
 old:=jsonb_build_object('sale',to_jsonb(r),'items',(SELECT jsonb_agg(to_jsonb(t)) FROM stock_movements t WHERE sale_id=_id));
 FOR m IN SELECT * FROM stock_movements WHERE sale_id=_id LOOP
 IF m.imei IS NOT NULL THEN
 IF EXISTS(SELECT 1 FROM stock_movements WHERE imei=m.imei AND created_at>m.created_at) THEN RAISE EXCEPTION 'Later IMEI history prevents cancellation'; END IF;
 UPDATE imei_units SET status='with_salesman',retailer_id=NULL WHERE imei=m.imei AND status='sold' AND salesman_id=m.salesman_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'IMEI state has changed'; END IF;
 END IF;
 END LOOP;
 DELETE FROM stock_movements WHERE sale_id=_id; DELETE FROM sales WHERE id=_id;
ELSIF _table='stock_movements' THEN
 SELECT * INTO m FROM stock_movements WHERE id=_id FOR UPDATE; IF m.id IS NULL THEN RAISE EXCEPTION 'Movement not found'; END IF;
 IF m.kind='sale' THEN RAISE EXCEPTION 'Cancel the whole invoice instead'; END IF;
 IF m.kind='purchase' THEN RAISE EXCEPTION 'Cancel the purchase record instead of its stock movement'; END IF;
 IF m.kind='sale_return' THEN RAISE EXCEPTION 'Reverse a sales return from the retailer record instead of cancelling its movement'; END IF;
 IF EXISTS(SELECT 1 FROM stock_movements WHERE salesman_id=m.salesman_id AND product_id=m.product_id AND (created_at>m.created_at OR (created_at=m.created_at AND id<>m.id))) THEN RAISE EXCEPTION 'Later stock history prevents cancellation'; END IF;
 SELECT * INTO p FROM products WHERE id=m.product_id FOR UPDATE;
 old:=to_jsonb(m);
 IF m.imei IS NOT NULL THEN
 IF m.kind='issue' THEN
 UPDATE imei_units SET status='in_stock',salesman_id=NULL,retailer_id=NULL WHERE imei=m.imei AND status='with_salesman' AND salesman_id=m.salesman_id;
 ELSE
 UPDATE imei_units SET status='with_salesman',salesman_id=m.salesman_id,retailer_id=NULL WHERE imei=m.imei AND status=(CASE WHEN m.kind='damage' THEN 'damaged'::imei_status ELSE 'in_stock'::imei_status END) AND salesman_id IS NULL;
 END IF;
 IF NOT FOUND THEN RAISE EXCEPTION 'IMEI state has changed'; END IF;
 ELSE
 IF m.kind='issue' THEN
 IF public.holding_qty(m.salesman_id,m.product_id)<m.qty THEN RAISE EXCEPTION 'Issued stock no longer in hand'; END IF;
 UPDATE products SET stock_qty=stock_qty+m.qty WHERE id=m.product_id;
 ELSIF m.kind='return' THEN
 IF p.stock_qty<m.qty THEN RAISE EXCEPTION 'Returned stock no longer available'; END IF;
 UPDATE products SET stock_qty=stock_qty-m.qty WHERE id=m.product_id;
 ELSIF m.kind IN ('purchase','opening') THEN
 IF p.stock_qty<m.qty THEN RAISE EXCEPTION 'Stock no longer available to reverse'; END IF;
 UPDATE products SET stock_qty=stock_qty-m.qty WHERE id=m.product_id;
 ELSIF m.kind='adjustment' THEN
 IF p.stock_qty-m.qty<0 THEN RAISE EXCEPTION 'Stock no longer available to reverse'; END IF;
 UPDATE products SET stock_qty=stock_qty-m.qty WHERE id=m.product_id;
 END IF;
 END IF;
 DELETE FROM stock_movements WHERE id=_id;
ELSE RAISE EXCEPTION 'Unsupported history'; END IF;
INSERT INTO business_audit(actor,action,entity,entity_id,reason,before_data) VALUES(auth.uid(),'cancel',_table,_id,_reason,old);
END; $$;
