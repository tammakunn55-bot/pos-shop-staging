# 🛒 Smart POS Pro V9.63 - Hardware Single-Shop Edition

ระบบบริหารจัดการหน้าร้าน คลังสินค้า ลูกหนี้การค้า และรายงานสรุปผล ยอดขาย รองรับการใช้งานแบบ Offline-First พร้อมระบบบันทึกและซิงค์ข้อมูล Supabase PostgreSQL แบบ Real-time

---

## 🛠️ ขั้นตอนการนำโค้ดขึ้น GitHub

1. สร้าง Repository ใหม่บน GitHub เช่น `smart-pos-pro`
2. โคลน Repository ลงเครื่องคอมพิวเตอร์ของคุณ:
   ```bash
   git clone https://github.com/YOUR_USERNAME/smart-pos-pro.git
   cd smart-pos-pro
   ```
3. คัดลอกไฟล์ `index.html` และ `README.md` วางลงในโฟลเดอร์โปรเจกต์
4. ทำการ Commit และ Push ขึ้น GitHub:
   ```bash
   git add .
   git commit -m "Deploy Smart POS Pro V9.63 Enterprise Hardware Edition"
   git push origin main
   ```

---

## 🗄️ การตั้งค่า Supabase Database

1. เข้าไปยัง [Supabase Dashboard](https://supabase.com) แล้วสร้าง Project ใหม่
2. ไปที่เมนู **SQL Editor** ในแถบเมนูด้านซ้าย
3. คัดลอกเนื้อหาทั้งหมดจากไฟล์ `supabase_schema.sql` วางใน SQL Editor แล้วกด **Run**
4. ไปที่ **Project Settings > API** แล้วนำ **URL** และ **anon public key** มาใส่ที่เมนูตั้งค่า (`⚙️`) ในหน้าเว็บ Smart POS Pro