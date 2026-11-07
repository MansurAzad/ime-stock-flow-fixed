# Mobile Phone Distribution & Salesman Hisab App

Dealer house (stock house) থেকে salesman (HR) মাল নিয়ে বাজারে retailer-দের কাছে বিক্রি করবে, আর পুরো হিসাব — মাল, টাকা, বাকি, পেমেন্ট, ফেরত — অ্যাপে থাকবে। Smartphone-দের IMEI দিয়ে ট্র্যাক করা হবে, button phone-দের নয়।

## যা বানানো হবে

### 1. Login ও ভূমিকা (Lovable Cloud + Auth)
- Email/password লগইন; admin নিজের অ্যাকাউন্ট খোলবে এবং salesman-দের অ্যাকাউন্ট তৈরি করে দেবে।
- ভূমিকা: **admin** (dealer house মালিক — সব দেখবেন) এবং **salesman** (নিজের হিসাব দেখবে)। Roles আলাদা `user_roles` টেবিলে, RLS দিয়ে সুরক্ষিত।

### 2. Admin অংশ
- **Product তালিকা**: নাম, মডেল, দাম, ক্যাটাগরি (smartphone / button phone)। Smartphone হলে IMEI tracking চালু।
- **Salesman তালিকা**: নতুন salesman অ্যাকাউন্ট তৈরি, active/inactive।
- **Stock issue**: কোন salesman-কে কোন product কত দেওয়া হলো; smartphone হলে IMEI scan করে মাল হস্তান্তর।
- **Settlement দেখা**: প্রতিটি ট্রিপের হিসাব — কত মাল গেল, কত বিক্রি হলো, কত টাকা জমা পেল, কত ফেরত এলো, salesman-এর কাছে কত বাকি/অবশিষ্ট।
- **Report/Dashboard**: salesman-ভিত্তিক ও retailer-ভিত্তিক সারসংক্ষেপ।

### 3. Salesman অংশ (মোবাইল-বান্ধব)
- **আমার হাতের মাল**: কোন product কত পেয়েছি, কত বিক্রি হলো, কত বাকি আছে।
- **বিক্রি entry**: retailer বেছে নিয়ে product ও পরিমাণ দিয়ে বিক্রি; smartphone হলে IMEI scan; টাকা কত নিলো, কত বাকি — সব লেখা থাকবে।
- **Retailer লেজার**: প্রতি retailer-এর আলাদা হিসাব — কত মাল নিলো, কত টাকা দিলো, কত বাকি; পরে payment আনলে সেটাও লেজারে ঢুকবে।
- **Payment collection**: retailer থেকে টাকা আদায়ের খতিয়ান।
- **ফেরত ও জমা (settlement)**: ট্রিপ শেষে যা বিক্রি হয়নি (damage সহ) IMEI/quantity দিয়ে ফেরত করা, বিক্রির টাকা dealer house-এ জমা দেওয়া, বাকি টাকার হিসাব মেলানো।

### 4. IMEI Scanner (modern feature)
- ক্যামেরা দিয়ে IMEI barcode scan (ফোনের বক্সের barcode) + চাইলে হাতে টাইপও করা যাবে।
- **Validation**: মাল নেওয়ার ও ফেরতের সময় scan করা IMEI সিস্টেমে থাকা IMEI-র সাথে মিলবে।
  - ভুল/অপরিচিত IMEI হলে → ফোন **vibrate** করবে + **লাল** সিগন্যাল।
  - ঠিক হলে → **সবুজ** সিগন্যাল, vibrate হবে না।
- শুধু smartphone-এ IMEI; button phone-এ কেবল quantity দিয়ে হিসাব।

### 5. ভাষা
- পুরো অ্যাপে বাংলা ↔ ইংরেজি toggle; পছন্দ মনে রাখা হবে।

## প্রযুক্তিগত বিবরণ

- **Backend**: Lovable Cloud (database + auth)। টেবিল: `products`, `imei_units`, `stock_issues`, `stock_issue_items`, `retailers`, `sales`, `sale_items`, `retailer_payments`, `deposits`, `returns`, `settlements`, `profiles`, `user_roles` — প্রতিটিতে GRANT + RLS policy (admin সব, salesman নিজের ডেটা)।
- **IMEI status flow**: `in_dealer_stock → with_salesman → sold` (বিক্রিতে) বা `returned → in_dealer_stock` (ফেরতে)। ভুল scan প্রতিরোধে প্রতিটি পরিবর্তন ডেটাবেস ফাংশনে যাচাই হবে।
- **Scanner**: `html5-qrcode` (barcode/QR) — ক্যামেরা চালু হবে শুধু ব্যবহারকারী scan বোতামে চাপলে। Vibration: `navigator.vibrate`।
- **Pages**: `/auth`, `/dashboard` (admin ও salesman-এর আলাদা ভিউ), `/products`, `/salesmen`, `/stock-issue`, `/sales`, `/retailers`, `/settlement` — সব `_authenticated` gate-এর নিচে।
- IMEI-ভিত্তিক নিয়মের জন্য ছোট টেস্ট থাকবে (যেমন: ভুল IMEI ফেরত দিলে reject হবে)।

## ধাপে ধাপে
1. Lovable Cloud চালু + auth (email/password), roles ও টেবিলের migration
2. Admin: products, salesmen, stock issue (IMEI scan সহ)
3. Salesman: হাতের মাল, বিক্রি entry, retailer লেজার, payment
4. Settlement: ফেরত (IMEI validation, লাল/সবুজ সিগন্যাল + vibrate), টাকা জমা, বাকির হিসাব
5. Dashboard/report ও বাংলা–ইংরেজি toggle, চূড়ান্ত যাচাই
