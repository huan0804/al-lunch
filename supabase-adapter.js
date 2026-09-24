// ============================================================
// Supabase adapter — giả lập API kiểu Claude Artifact (db.doc/
// collection/onSnapshot, user, sample) chạy trên Supabase, để
// index.html gần như không phải đổi phần UI/event logic.
//
// Mô hình quyền (theo yêu cầu người dùng — xem supabase-schema.sql để
// biết đầy đủ lý do và đánh đổi):
//   - Link gốc  index.html                        → AI mở cũng có toàn
//     quyền quản lý (tạo/sửa đơn, xác nhận thanh toán...). Không cần
//     đăng nhập/token gì cả — bảo mật dựa vào việc không public domain
//     Vercel ra ngoài phạm vi những người được phép quản lý.
//   - Link đơn  index.html?order=<order_token>     → chỉ xem/đặt món cho
//     ĐÚNG session đó, giao diện tự ẩn các nút quản lý (S.canEdit=false).
//
// Cần nạp @supabase/supabase-js (UMD) TRƯỚC file này, và định nghĩa
// window.SUPABASE_URL, window.SUPABASE_ANON_KEY trước khi load file này.
// ============================================================
(function(){
  if (!window.supabase?.createClient){ console.error("supabase-js chưa được nạp"); return; }
  if (!window.SUPABASE_URL || !window.SUPABASE_ANON_KEY){ console.error("Thiếu SUPABASE_URL/SUPABASE_ANON_KEY"); return; }
  const sb = window.supabase.createClient(window.SUPABASE_URL, window.SUPABASE_ANON_KEY);

  const rid = () => Math.random().toString(36).slice(2, 10);
  function lsGet(k){ try{ return localStorage.getItem(k); }catch{ return null; } }
  function lsSet(k,v){ try{ localStorage.setItem(k,v); }catch{} }

  /* ---------- uid ẩn danh của trình duyệt này ---------- */
  function getOrCreateUid(){
    let id = lsGet("comtrua:uid");
    if (!id){ id = "u" + rid() + rid(); lsSet("comtrua:uid", id); }
    return id;
  }

  /* ---------- link đơn (?order=<order_token>) → không có quyền quản lý ---------- */
  const orderToken = new URLSearchParams(location.search).get("order") || null;
  const isGuestLink = !!orderToken;

  /* ---------- map field: snake_case (DB) <-> camelCase (app) ---------- */
  const CONFIG_MAP = {
    bankBin:"bank_bin", bankName:"bank_name", accountNo:"account_no", accountName:"account_name",
    pricePerSet:"price_per_set", hostPays:"host_pays", showPaymentToTeam:"show_payment_to_team",
    shareUrl:"share_url", current:"current_session_key"
  };
  const SESSION_MAP = {
    date:"date", status:"status", pricePerSet:"price_per_set", deadlineAt:"deadline_at",
    deadline:"deadline", autoClose:"auto_close", hostName:"host_name", shopName:"shop_name",
    menu:"menu", createdAt:"created_at", orderToken:"order_token"
  };
  const ORDER_MAP = {
    name:"name", guests:"guests", sets:"sets", total:"total", pricePerSet:"price_per_set",
    payMethod:"pay_method", payStatus:"pay_status", byHost:"by_host", createdAt:"created_at", updatedAt:"updated_at"
  };
  function toApp(row, map){
    if (!row) return null;
    const out = {};
    for (const [appKey, dbKey] of Object.entries(map)) if (dbKey in row) out[appKey] = row[dbKey];
    return out;
  }
  function toDb(obj, map){
    const out = {};
    for (const [appKey, dbKey] of Object.entries(map)) if (appKey in obj) out[dbKey] = obj[appKey];
    return out;
  }

  /* ---------- doc() : 1 row ---------- */
  function doc(path){
    const [coll, id] = path.split("/");
    return {
      path, id,
      async get(){
        if (coll==="config"){
          const { data } = await sb.from("config").select("*").eq("id",1).maybeSingle();
          return { id:"main", exists: !!data, data: () => data ? toApp(data, CONFIG_MAP) : null };
        }
        if (coll==="sessions"){
          const { data } = await sb.from("sessions").select("*").eq("key", id).maybeSingle();
          return { id, exists: !!data, data: () => data ? toApp(data, SESSION_MAP) : null };
        }
        if (coll==="orders"){
          throw new Error("orders.doc().get() không hỗ trợ trực tiếp — dùng mutateOrder");
        }
        throw new Error("Không rõ collection: " + coll);
      },
      async set(obj){
        if (coll==="config"){
          const row = { id: 1, ...toDb(obj, CONFIG_MAP), updated_at: new Date().toISOString() };
          const { error } = await sb.from("config").upsert(row, { onConflict: "id" });
          if (error) throw error;
          return;
        }
        if (coll==="sessions"){
          // order_token: để DB tự sinh giá trị mặc định (xem cột default
          // trong schema) khi tạo mới — không set ở đây để không ghi đè
          // token đã có nếu đây thực ra là update qua set().
          const row = { key: id, ...toDb(obj, SESSION_MAP) };
          delete row.order_token;
          const { error } = await sb.from("sessions").upsert(row, { onConflict: "key" });
          if (error) throw error;
          return;
        }
        throw new Error("set() không hỗ trợ cho " + coll);
      },
      async update(patch){
        if (coll==="config"){
          const row = toDb(patch, CONFIG_MAP);
          const { error } = await sb.from("config").update({ ...row, updated_at: new Date().toISOString() }).eq("id", 1);
          if (error) throw error;
          return;
        }
        if (coll==="sessions"){
          const row = toDb(patch, SESSION_MAP);
          const { error } = await sb.from("sessions").update(row).eq("key", id);
          if (error) throw error;
          return;
        }
        throw new Error("update() không hỗ trợ cho " + coll);
      },
      async delete(){
        if (coll==="sessions"){
          const { error } = await sb.from("sessions").delete().eq("key", id);
          if (error) throw error;
          return;
        }
        throw new Error("delete() không hỗ trợ cho " + coll);
      },
      onSnapshot(onNext, onErr){
        let stopped = false;
        const push = async () => {
          try{
            if (coll==="config"){
              const { data } = await sb.from("config").select("*").eq("id",1).maybeSingle();
              if (!stopped) onNext({ id:"main", exists: !!data, data: () => data ? toApp(data, CONFIG_MAP) : null });
            } else if (coll==="sessions"){
              const { data } = await sb.from("sessions").select("*").eq("key", id).maybeSingle();
              if (!stopped) onNext({ id, exists: !!data, data: () => data ? toApp(data, SESSION_MAP) : null });
            }
          }catch(e){ if(!stopped) onErr?.(e); }
        };
        push();
        const table = coll==="config" ? "config" : "sessions";
        const filter = coll==="config" ? {} : { filter: `key=eq.${id}` };
        const channel = sb.channel(`doc:${path}:${rid()}`)
          .on("postgres_changes", { event:"*", schema:"public", table, ...filter }, push)
          .subscribe();
        return () => { stopped = true; sb.removeChannel(channel); };
      }
    };
  }

  /* ---------- tìm session theo order_token (link đơn của guest) ---------- */
  async function findSessionKeyByOrderToken(token){
    if (!token) return null;
    const { data } = await sb.from("sessions").select("key").eq("order_token", token).maybeSingle();
    return data?.key || null;
  }

  /* ---------- mutateOrder: đọc-sửa-ghi đè 1 order (session_key, doc_id) ---------- */
  async function mutateOrder(docId, sessionKey, fn){
    const { data:cur } = await sb.from("orders").select("*").eq("session_key", sessionKey).eq("doc_id", docId).maybeSingle();
    const curApp = cur ? toApp(cur, ORDER_MAP) : null;
    const next = fn(curApp);
    if (next === null || next === undefined){
      const { error } = await sb.from("orders").delete().eq("session_key", sessionKey).eq("doc_id", docId);
      if (error) throw error;
      return;
    }
    const row = { session_key: sessionKey, doc_id: docId, ...toDb(next, ORDER_MAP) };
    const { error } = await sb.from("orders").upsert(row, { onConflict: "session_key,doc_id" });
    if (error) throw error;
  }

  /* ---------- collection() ---------- */
  function coll(path){
    const parts = path.split("/");
    const name = parts[0];
    const q = { _orderBy:null, _limit:null };
    q.orderBy = (field, dir) => { q._orderBy = { field, dir }; return q; };
    q.limit = (n) => { q._limit = n; return q; };
    q.where = () => q; // không dùng trong app hiện tại
    q.onSnapshot = (onNext, onErr) => {
      let stopped = false;
      const push = async () => {
        try{
          if (name==="orders"){
            // Model cũ: orders/{docId}.days[sessionKey]. Bảng mới phẳng theo
            // (session_key, doc_id) — gộp lại đây thành đúng shape days{} cũ,
            // 1 doc_id có thể có nhiều session (nhiều ngày) nên phải gộp, không ghi đè.
            const { data, error } = await sb.from("orders").select("*");
            if (error) throw error;
            const byDoc = {};
            (data||[]).forEach(r => {
              if (!byDoc[r.doc_id]) byDoc[r.doc_id] = {};
              byDoc[r.doc_id][r.session_key] = toApp(r, ORDER_MAP);
            });
            const docs = Object.entries(byDoc).map(([docId, days]) => ({ id: docId, data: () => ({ days }) }));
            if (!stopped) onNext({ docs, size: docs.length, empty: !docs.length });
          } else if (name==="dishes"){
            const { data, error } = await sb.from("dishes").select("*").order("times_used",{ascending:false});
            if (error) throw error;
            const docs = (data||[]).map(r => ({ id: r.id, data: () => ({ nameVi:r.name_vi, nameEn:r.name_en, timesUsed:r.times_used, lastUsed:r.last_used }) }));
            if (!stopped) onNext({ docs, size: docs.length, empty: !docs.length });
          } else if (name==="sessions"){
            let query = sb.from("sessions").select("*").order("created_at",{ascending:false});
            if (q._limit) query = query.limit(q._limit);
            const { data, error } = await query;
            if (error) throw error;
            const docs = (data||[]).map(r => ({ id: r.key, data: () => toApp(r, SESSION_MAP) }));
            if (!stopped) onNext({ docs, size: docs.length, empty: !docs.length });
          }
        }catch(e){ if(!stopped) onErr?.(e); }
      };
      push();
      const channel = sb.channel(`coll:${name}:${rid()}`)
        .on("postgres_changes", { event:"*", schema:"public", table:name }, push)
        .subscribe();
      return () => { stopped = true; sb.removeChannel(channel); };
    };
    return q;
  }

  const db = { doc, collection: coll, mutateOrder, findSessionKeyByOrderToken };

  /* ---------- user ---------- */
  // canEdit/isOwner: true khi mở LINK GỐC (không có ?order=...), false khi
  // mở link đơn của guest. Không có xác thực nào khác — xem ghi chú đầu file.
  const user = {
    id: async () => getOrCreateUid(),
    canEdit: async () => !isGuestLink,
    isOwner: async () => !isGuestLink
  };

  /* ---------- sample (đọc ảnh AI) — CHƯA khả dụng trong bản Supabase ---------- */
  const sample = null; // giữ null để app tự tắt UI đọc ảnh (S.imagesOK=false)

  /* ---------- helpers lộ ra ngoài cho index.html gọi trực tiếp ---------- */
  window.upsertDish = async (id, nameVi, nameEn) => {
    const { data, error } = await sb.rpc("upsert_dish", { p_id:id, p_name_vi:nameVi, p_name_en:nameEn||"" });
    if (error) throw error;
    return data;
  };
  window.SupabaseOrderToken = orderToken; // để index.html đọc lại nếu cần (vd ghép link)

  window.SupabaseAdapter = { db, user, sample };
})();
