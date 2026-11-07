-- 0013: backups, reset and restore now cover the accounting tables added in
-- 0011 (suppliers, purchases, supplier_payments, expenses, retailer_returns),
-- so an export can no longer silently omit purchases/expenses/returns and a
-- reset no longer leaves them behind. doc_counters stay monotonic on purpose.

CREATE OR REPLACE FUNCTION public.business_snapshot() RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=public AS $$
SELECT jsonb_build_object('products',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY id),'[]') FROM products t),'retailers',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY id),'[]') FROM retailers t),'imei_units',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY id),'[]') FROM imei_units t),'sales',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY id),'[]') FROM sales t),'stock_movements',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY id),'[]') FROM stock_movements t),'retailer_payments',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY id),'[]') FROM retailer_payments t),'deposits',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY id),'[]') FROM deposits t),'dealer_blocks',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY retailer_id),'[]') FROM dealer_blocks t),'dealer_risk_assessments',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY retailer_id),'[]') FROM dealer_risk_assessments t),'suppliers',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY id),'[]') FROM suppliers t),'purchases',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY id),'[]') FROM purchases t),'supplier_payments',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY id),'[]') FROM supplier_payments t),'expenses',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY id),'[]') FROM expenses t),'retailer_returns',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY id),'[]') FROM retailer_returns t)); $$;

CREATE OR REPLACE FUNCTION public.export_business_data() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ DECLARE snap jsonb; bid uuid; BEGIN
IF NOT public.has_role(auth.uid(),'admin') THEN RAISE EXCEPTION 'Owner only'; END IF;
LOCK TABLE products,retailers,imei_units,sales,stock_movements,retailer_payments,deposits,dealer_blocks,dealer_risk_assessments,suppliers,purchases,supplier_payments,expenses,retailer_returns IN SHARE MODE;
snap:=public.business_snapshot(); IF octet_length(snap::text)>20971520 THEN RAISE EXCEPTION 'Use Cloud export for data larger than 20 MB'; END IF;
INSERT INTO business_exports(actor,snapshot) VALUES(auth.uid(),snap) RETURNING id INTO bid;
RETURN jsonb_build_object('format','firoza-business-data','version',1,'source',bid,'exported_at',now(),'tables',snap); END; $$;

CREATE OR REPLACE FUNCTION public.reset_business_data(_confirmation text,_backup_id uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ DECLARE snap jsonb; BEGIN
IF NOT public.has_role(auth.uid(),'admin') OR _confirmation IS DISTINCT FROM 'RESET FIROZA' THEN RAISE EXCEPTION 'Owner confirmation required'; END IF;
LOCK TABLE products,retailers,imei_units,sales,stock_movements,retailer_payments,deposits,dealer_blocks,dealer_risk_assessments,suppliers,purchases,supplier_payments,expenses,retailer_returns IN ACCESS EXCLUSIVE MODE;
SELECT snapshot INTO snap FROM business_exports WHERE id=_backup_id AND actor=auth.uid() AND created_at>now()-interval '30 minutes';
IF snap IS NULL OR snap IS DISTINCT FROM public.business_snapshot() THEN RAISE EXCEPTION 'Download a fresh backup first; data may have changed'; END IF;
DELETE FROM dealer_risk_assessments WHERE retailer_id IS NOT NULL; DELETE FROM dealer_blocks WHERE retailer_id IS NOT NULL; DELETE FROM retailer_returns WHERE id IS NOT NULL; DELETE FROM supplier_payments WHERE id IS NOT NULL; DELETE FROM expenses WHERE id IS NOT NULL;
DELETE FROM stock_movements WHERE id IS NOT NULL; DELETE FROM retailer_payments WHERE id IS NOT NULL; DELETE FROM deposits WHERE id IS NOT NULL; DELETE FROM sales WHERE id IS NOT NULL; DELETE FROM imei_units WHERE id IS NOT NULL; DELETE FROM purchases WHERE id IS NOT NULL; DELETE FROM retailers WHERE id IS NOT NULL; DELETE FROM products WHERE id IS NOT NULL; DELETE FROM suppliers WHERE id IS NOT NULL;
INSERT INTO business_audit(actor,action,reason,before_data) VALUES(auth.uid(),'reset','RESET FIROZA',jsonb_build_object('backup_id',_backup_id)); END; $$;

CREATE OR REPLACE FUNCTION public.restore_business_data(_confirmation text,_snapshot jsonb,_backup_id uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ DECLARE tab text; row_data jsonb; saved jsonb; BEGIN
IF NOT public.has_role(auth.uid(),'admin') OR _confirmation IS DISTINCT FROM 'RESTORE FIROZA' THEN RAISE EXCEPTION 'Owner confirmation required'; END IF;
IF _snapshot->>'format' IS DISTINCT FROM 'firoza-business-data' OR _snapshot->>'version' IS DISTINCT FROM '1' OR octet_length(_snapshot::text)>20971520 THEN RAISE EXCEPTION 'Invalid backup format or size'; END IF;
-- Only authentic exports from this database are eligible, preventing fabricated stock/account histories.
SELECT snapshot INTO saved FROM business_exports WHERE id=(_snapshot->>'source')::uuid;
IF saved IS NULL OR saved IS DISTINCT FROM _snapshot->'tables' THEN RAISE EXCEPTION 'Backup is modified or belongs to another installation'; END IF;
PERFORM public.reset_business_data('RESET FIROZA',_backup_id);
INSERT INTO suppliers SELECT * FROM jsonb_populate_recordset(NULL::public.suppliers,saved->'suppliers');
INSERT INTO purchases SELECT * FROM jsonb_populate_recordset(NULL::public.purchases,saved->'purchases');
INSERT INTO products SELECT * FROM jsonb_populate_recordset(NULL::public.products,saved->'products');
INSERT INTO retailers SELECT * FROM jsonb_populate_recordset(NULL::public.retailers,saved->'retailers');
INSERT INTO imei_units SELECT * FROM jsonb_populate_recordset(NULL::public.imei_units,saved->'imei_units');
-- Restore sales before blocks so the sales-insert protection remains untouched.
INSERT INTO sales SELECT * FROM jsonb_populate_recordset(NULL::public.sales,saved->'sales');
INSERT INTO stock_movements SELECT * FROM jsonb_populate_recordset(NULL::public.stock_movements,saved->'stock_movements');
INSERT INTO retailer_payments SELECT * FROM jsonb_populate_recordset(NULL::public.retailer_payments,saved->'retailer_payments');
INSERT INTO deposits SELECT * FROM jsonb_populate_recordset(NULL::public.deposits,saved->'deposits');
INSERT INTO retailer_returns SELECT * FROM jsonb_populate_recordset(NULL::public.retailer_returns,saved->'retailer_returns');
INSERT INTO supplier_payments SELECT * FROM jsonb_populate_recordset(NULL::public.supplier_payments,saved->'supplier_payments');
INSERT INTO expenses SELECT * FROM jsonb_populate_recordset(NULL::public.expenses,saved->'expenses');
-- AI advice and blocking are not restored: every block requires a new explicit dealer confirmation.
INSERT INTO business_audit(actor,action,reason,after_data) VALUES(auth.uid(),'restore','RESTORE FIROZA',jsonb_build_object('source',_snapshot->>'source','safety_backup',_backup_id)); END; $$;

-- Internal helpers that no client calls directly lose their public EXECUTE
-- grant; the validated RPCs reach them in owner context. supplier_due() is
-- deliberately kept callable: the purchases page reads it per supplier, and
-- as an invoker function it stays scoped by row-level security.
REVOKE EXECUTE ON FUNCTION public.retailer_due(uuid) FROM PUBLIC, authenticated;
REVOKE EXECUTE ON FUNCTION public.salesman_cash(uuid) FROM PUBLIC, authenticated;
REVOKE EXECUTE ON FUNCTION public.next_doc_no(text) FROM PUBLIC, authenticated;
