import { pageHead } from "@/lib/page-head";
import { createFileRoute } from "@tanstack/react-router";
import { useState, type ReactNode } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { Printer } from "lucide-react";
import { supabase } from "@/integrations/supabase/client";
import { useMe, useSalesmen, requireAdmin } from "@/lib/me";
import { runOrQueue, useOnline } from "@/lib/offline";
import { useBusiness } from "@/lib/business";
import { useT } from "@/lib/i18n";
import { PrintSheet, TableDoc } from "@/components/PrintDocs";
import { CartBuilder, type CartLine } from "@/components/CartBuilder";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { PageTitle } from "@/components/Stat";

export const Route = createFileRoute("/_authenticated/stock-issue")({
  beforeLoad: requireAdmin,
  head: () => pageHead("মাল দেওয়া", "FIROZA ENTERPRISE stock issue and validated smartphone IMEI transfers."),
  component: StockIssue,
});

const todayDhaka = () => new Date().toLocaleDateString("en-CA", { timeZone: "Asia/Dhaka" });

function StockIssue() {
  const { t } = useT();
  const qc = useQueryClient();
  const { data: me } = useMe();
  const { data: salesmen = [] } = useSalesmen();
  const [business] = useBusiness();
  const [sid, setSid] = useState("");
  const [cart, setCart] = useState<CartLine[]>([]);
  const [date, setDate] = useState(todayDhaka());
  const [busy, setBusy] = useState(false);
  const [lastBatch, setLastBatch] = useState<string | null>(null);
  const [printDoc, setPrintDoc] = useState<ReactNode | null>(null);
  const online = useOnline();

  async function submit() {
    if (busy || !sid || !cart.length || !me) return;
    setBusy(true);
    try {
      const result = await runOrQueue(
        { kind: "issue_stock", payload: { _salesman: sid, _items: cart.map((l) => ({ product_id: l.product_id, qty: l.qty, imeis: l.imeis })), _date: date || null } },
        !online,
        me.id,
      );
      if (result.s === "error") { toast.error(result.error); return; }
      toast.success(t(result.s === "queued" ? "savedOffline" : "done"));
      if (result.s === "done" && typeof result.data === "string") setLastBatch(result.data);
      setCart([]);
      qc.invalidateQueries();
    } finally {
      setBusy(false);
    }
  }

  async function printChallan() {
    if (!lastBatch) return;
    const { data } = await supabase.from("stock_movements").select("qty, imei, products(name)").eq("batch_no", lastBatch).eq("kind", "issue");
    const rows = (data ?? []).map((m, i) => [i + 1, (m.products as { name: string } | null)?.name ?? "", m.qty, m.imei ?? ""]);
    const salesmanName = salesmen.find((s) => s.id === sid)?.full_name ?? "";
    setPrintDoc(
      <TableDoc b={business} appName={t("appName")} title={`${t("challan")} · ${lastBatch} · ${salesmanName}`}
        head={["#", t("products"), t("qty"), "IMEI"]} rows={rows} />,
    );
  }

  return (
    <div className="space-y-4">
      <PageTitle>{t("stockIssue")}</PageTitle>
      {lastBatch && (
        <div className="flex flex-wrap items-center justify-between gap-2 rounded-xl border border-success bg-success/10 p-3">
          <span className="text-sm font-semibold">{t("challan")}: {lastBatch}</span>
          <div className="flex gap-2">
            <Button size="sm" variant="secondary" onClick={printChallan}><Printer className="mr-1 h-4 w-4" />{t("print")}</Button>
            <Button size="sm" variant="ghost" onClick={() => setLastBatch(null)}>✕</Button>
          </div>
        </div>
      )}
      <div className="flex flex-wrap items-end gap-3">
        <Select value={sid} onValueChange={(v) => { setSid(v); setCart([]); }}>
          <SelectTrigger className="w-full sm:w-72"><SelectValue placeholder={t("selectSalesman")} /></SelectTrigger>
          <SelectContent>{salesmen.filter((s) => s.active).map((s) => <SelectItem key={s.id} value={s.id}>{s.full_name}</SelectItem>)}</SelectContent>
        </Select>
        <div className="space-y-1"><Label>{t("date")}</Label><Input type="date" value={date} onChange={(e) => setDate(e.target.value)} /></div>
      </div>
      {sid && <CartBuilder mode="issue" salesmanId={sid} cart={cart} setCart={setCart} />}
      <Button size="lg" className="w-full" disabled={!sid || !cart.length || busy} onClick={submit}>{t("confirm")}</Button>
      {printDoc && <PrintSheet onDone={() => setPrintDoc(null)}>{printDoc}</PrintSheet>}
    </div>
  );
}
