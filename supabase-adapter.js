// ============================================================
// Supabase adapter — giả lập API kiểu Claude Artifact (db.doc/
// collection/onSnapshot, user, sample) chạy trên Supabase, để
// index.html gần như không phải đổi phần UI/event logic.
//
// Mô hình quyền (theo yêu cầu người dùng — nhiều đơn nhóm tồn tại SONG
// SONG, mỗi đơn do 1 người tạo và quản lý riêng; xem supabase-schema.sql
// để biết đầy đủ lý do và đánh đổi):
//   - Link gốc  index.html                          → LUÔN là màn "Tạo
//     đơn nhóm mới" trống, không gắn session nào. Ai mở cũng tạo được.
//   - Link quản lý  index.html?manage=<manage_token>  → sau khi tạo đơn,
//     app tự chuyển sang link này. Toàn quyền quản lý ĐÚNG session đó
//     (S.canEdit=true CHỈ cho session này, không phải toàn cục).
//   - Link đơn (guest)  index.html?order=<order_token> → chỉ xem/đặt món
//     cho ĐÚNG session đó, không có quyền quản lý (S.canEdit=false).
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

  /* ---------- link trên URL: ?manage=<manage_token> hoặc ?order=<order_token> ---------- */
  const qs = new URLSearchParams(location.search);
  const manageToken = qs.get("manage") || null;
  const orderToken = qs.get("order") || null;
  const isGuestLink = !!orderToken && !manageToken;

  /* ---------- map field: snake_case (DB) <-> camelCase (app) ---------- */
  // CONFIG: cấu hình CHUNG toàn hệ thống. Bank KHÔNG còn ở đây — mỗi
  // session tự có bank riêng của người tạo (xem SESSION_MAP).
  const CONFIG_MAP = {
    pricePerSet:"price_per_set", hostPays:"host_pays", showPaymentToTeam:"show_payment_to_team",
    shareUrl:"share_url"
  };
  const SESSION_MAP = {
    date:"date", status:"status", pricePerSet:"price_per_set", deadlineAt:"deadline_at",
    deadline:"deadline", autoClose:"auto_close", hostName:"host_name", shopName:"shop_name",
    menu:"menu", createdAt:"created_at", orderToken:"order_token", manageToken:"manage_token",
    bankBin:"bank_bin", bankName:"bank_name", accountNo:"account_no", accountName:"account_name"
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
          // order_token/manage_token: cột NOT NULL với DEFAULT ở DB, nhưng
          // upsert() của PostgREST gửi tường minh mọi key của object — kể cả
          // khi thiếu key này, một số đường upsert vẫn insert NULL thay vì để
          // DEFAULT chạy. Sinh token ở client cho chắc. set() trong app chỉ
          // dùng để TẠO session mới (bản sửa đơn cũ đi qua update(), không
          // qua đây) nên không có rủi ro ghi đè token của session đã tồn tại.
          const row = { key: id, order_token: rid()+rid()+rid(), manage_token: rid()+rid()+rid(), ...toDb(obj, SESSION_MAP) };
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
  /* ---------- tìm session theo manage_token (link quản lý của người tạo đơn) ---------- */
  async function findSessionKeyByManageToken(token){
    if (!token) return null;
    const { data } = await sb.from("sessions").select("key").eq("manage_token", token).maybeSingle();
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

  const db = { doc, collection: coll, mutateOrder, findSessionKeyByOrderToken, findSessionKeyByManageToken };

  /* ---------- user ---------- */
  // canEdit/isOwner: chỉ true khi có ?manage=... trên URL VÀ nó khớp đúng
  // 1 session đang tồn tại (verify async, xem resolveManageAccess() —
  // index.html gọi 1 lần trong boot() trước khi đọc canEdit()/isOwner()).
  // Link gốc không có ?manage= => canEdit=false (không phải true như bản
  // thiết kế trước) vì link gốc giờ CHỈ dùng để tạo đơn mới, không quản
  // lý bất kỳ session nào cho tới khi đơn được tạo và redirect sang
  // ?manage=... của chính nó.
  let manageOk = false;
  async function resolveManageAccess(){
    if (!manageToken){ manageOk = false; return false; }
    const key = await findSessionKeyByManageToken(manageToken).catch(()=>null);
    manageOk = !!key;
    return manageOk;
  }
  const user = {
    id: async () => getOrCreateUid(),
    canEdit: async () => manageOk,
    isOwner: async () => manageOk
  };

  /* ---------- sample (đọc ảnh AI) — CHƯA khả dụng trong bản Supabase ---------- */
  const sample = null; // giữ null để app tự tắt UI đọc ảnh (S.imagesOK=false)

  /* ---------- helpers lộ ra ngoài cho index.html gọi trực tiếp ---------- */
  window.upsertDish = async (id, nameVi, nameEn) => {
    const { data, error } = await sb.rpc("upsert_dish", { p_id:id, p_name_vi:nameVi, p_name_en:nameEn||"" });
    if (error) throw error;
    return data;
  };
  window.deleteDish = async (id) => {
    const { error } = await sb.from("dishes").delete().eq("id", id);
    if (error) throw error;
  };
  window.SupabaseOrderToken = orderToken; // để index.html đọc lại nếu cần (vd ghép link)
  window.SupabaseManageToken = manageToken;
  window.SupabaseResolveManageAccess = resolveManageAccess; // PHẢI gọi (await) trong boot() TRƯỚC user.canEdit()/isOwner()

  window.SupabaseAdapter = { db, user, sample };
})();
