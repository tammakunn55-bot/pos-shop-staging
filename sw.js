// Service worker: ให้แอปเปิดได้แม้ไม่มีอินเทอร์เน็ต (วางไฟล์นี้ไว้โฟลเดอร์เดียวกับ index.html)
//
// การทำงาน:
// - เลขเวอร์ชัน (V) คำนวณอัตโนมัติจากเนื้อหาของ index.html และรายการไลบรารี ไม่ต้องแก้มือ
//   ถ้า index.html หรือรายการไลบรารีเปลี่ยน เครื่องจะติดตั้งชุด cache ใหม่เอง
// - cache รูปสินค้า (IMG_CACHE) แยกต่างหาก และไม่ถูกลบเมื่ออัปเดตแอป
//   รูปจะถูกจำกัดจำนวนเพื่อไม่ให้เต็มพื้นที่ของเครื่อง
// - ข้อมูล/API ของ Supabase ใช้เครือข่ายเสมอ ไม่เก็บใน cache

const SHELL_PREFIX = 'pos-shell-';
const IMG_CACHE = 'pos-img-v1';
const IMG_MAX_ENTRIES = 2500;

// ต้องตรงกับ URL ใน <script src> ของ index.html ทุกตัว (ไม่งั้นเปิดออฟไลน์ครั้งแรกไม่ได้)
const SHELL = [
  './', './index.html', './manifest.webmanifest', './icon.svg',
  './icon-192.png', './icon-512.png', './icon-maskable-512.png',
  'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4',
  'https://unpkg.com/html5-qrcode@2.3.8/html5-qrcode.min.js',
  'https://cdnjs.cloudflare.com/ajax/libs/xlsx/0.18.5/xlsx.full.min.js',
  'https://cdnjs.cloudflare.com/ajax/libs/jszip/3.10.1/jszip.min.js',
  'https://cdn.jsdelivr.net/npm/exceljs@4.4.0/dist/exceljs.min.js'
];

// คำนวณเลขเวอร์ชันจากเนื้อหา index.html + รายการ SHELL (SHA-256 ตัดเหลือ 12 ตัวอักษร)
async function computeVersion() {
  try {
    const res = await fetch('./index.html', { cache: 'no-store' });
    if (!res.ok) throw new Error('HTTP ' + res.status);
    const text = await res.text() + '\n' + SHELL.join('\n');
    const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
    const hex = Array.from(new Uint8Array(digest)).map(b => b.toString(16).padStart(2, '0')).join('');
    return SHELL_PREFIX + hex.slice(0, 12);
  } catch (err) {
    // ออฟไลน์ตอนติดตั้ง: ใช้ชื่อ fallback เพื่อให้ยังมี cache ใช้งาน
    console.warn('computeVersion fallback', err);
    return SHELL_PREFIX + 'fallback';
  }
}
const OFFLINE_PAGE = `<!doctype html><html lang="th"><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<body style="font-family:sans-serif;padding:24px;background:#f1f5f9;color:#0f172a">
<h2>ยังไม่มีข้อมูลแอปในเครื่องนี้</h2>
<p>เครื่องนี้ยังไม่เคยเปิดแอปแบบออนไลน์จนเสร็จ จึงเปิดโหมดออฟไลน์ไม่ได้</p>
<p><b>วิธีแก้:</b> ต่อ Wi-Fi หรือปิดโหมดเครื่องบิน เปิดแอปครั้งหนึ่งให้โหลดเสร็จ แล้วจึงใช้โหมดออฟไลน์ได้</p>
</body></html>`;

const VERSION = computeVersion();

// จำกัดจำนวนรูปใน cache (ลบรายการเก่าสุดก่อน)
async function trimImages(cache) {
  const keys = await cache.keys();
  if (keys.length > IMG_MAX_ENTRIES) {
    await Promise.all(keys.slice(0, keys.length - IMG_MAX_ENTRIES).map(k => cache.delete(k)));
  }
}

self.addEventListener('install', e => e.waitUntil((async () => {
  const v = await VERSION;
  const c = await caches.open(v);
  // เก็บทีละไฟล์: ถ้าไฟล์ไหนโหลดไม่ได้ ไม่ทำให้การติดตั้งทั้งชุดล้ม
  // หน้าแอปหลักต้องเก็บได้ ถ้าไม่ได้ให้ล้มการติดตั้ง (จะลองใหม่ในการเปิดครั้งถัดไป)
  await c.add('./index.html');
  // ไลบรารี: เก็บแบบพยายามที่สุด ถ้าไฟล์ไหนพลาดจะโหลดและเก็บตอนเปิดออนไลน์ครั้งถัดไป
  await Promise.all(SHELL.map(u => c.add(u).catch(err => console.warn('precache skip', u, err))));
  await self.skipWaiting();
})()));

self.addEventListener('activate', e => e.waitUntil((async () => {
  const v = await VERSION;
  const keys = await caches.keys();
  // ลบเฉพาะ cache ของ shell รุ่นเก่า; ไม่แตะ IMG_CACHE
  await Promise.all(keys.filter(k => k.startsWith(SHELL_PREFIX) && k !== v).map(k => caches.delete(k)));
  await self.clients.claim();
})()));

self.addEventListener('fetch', e => {
  const r = e.request;
  if (r.method !== 'GET') return;
  const u = new URL(r.url);
  const isSupabase = u.hostname.endsWith('.supabase.co');

  // ข้อมูล/API: ใช้เครือข่ายเสมอ
  if (isSupabase && !u.pathname.startsWith('/storage/')) return;

  // รูปจาก Supabase Storage: network-first แล้ว fallback ไป cache รูป (แยกจาก shell)
  if (isSupabase && u.pathname.startsWith('/storage/')) {
    e.respondWith((async () => {
      const c = await caches.open(IMG_CACHE);
      try {
        const res = await fetch(r);
        if (res && res.ok) { c.put(r, res.clone()); trimImages(c); }
        return res;
      } catch (err) {
        const hit = await c.match(r);
        if (hit) return hit;
        throw err;
      }
    })());
    return;
  }

  // หน้าแอป (navigation)
  if (r.mode === 'navigate') {
    if (!/(index\.html|app\.html|\/)$/.test(u.pathname)) return;
    e.respondWith((async () => {
      const v = await VERSION;
      const c = await caches.open(v);
      try {
        const res = await fetch(r);
        c.put('./', res.clone());
        return res;
      } catch (err) {
        const cached = (await c.match('./')) || (await c.match('./index.html'));
        if (cached) return cached;
        return new Response(OFFLINE_PAGE, { status: 503, headers: { 'Content-Type': 'text/html; charset=utf-8' } });
      }
    })());
    return;
  }

  // รูปอื่น (เช่น รูปในแอป): cache-first ใน IMG_CACHE
  if (r.destination === 'image') {
    e.respondWith((async () => {
      const c = await caches.open(IMG_CACHE);
      const hit = await c.match(r);
      if (hit) return hit;
      const res = await fetch(r);
      if (res && res.ok) { c.put(r, res.clone()); trimImages(c); }
      return res;
    })());
    return;
  }

  // ไลบรารีและไฟล์ที่เหลือ: cache-first ใน shell cache ของเวอร์ชันปัจจุบัน
  e.respondWith((async () => {
    const v = await VERSION;
    const c = await caches.open(v);
    const hit = await c.match(r);
    if (hit) return hit;
    const res = await fetch(r);
    if (res && res.ok) c.put(r, res.clone());
    return res;
  })());
});
