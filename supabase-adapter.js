// ============================================================
// Supabase adapter — giả lập API kiểu Claude Artifact (db.doc/
// collection/onSnapshot, user, sample) chạy trên Supabase, để
// index.html gần như không phải đổi phần UI/event logic.
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

  /* ---------- map field: snake_case (DB) <-> camelCase (app) ---------- */
  const CONFIG_MAP = {
    bankBin:"bank_bin", bankName:"bank_name", accountNo:"account_no", accountName:"account_name",
    pricePerSet:"price_per_set", hostPays:"host_pays", showPaymentToTeam:"show_payment_to_team",
    shareUrl:"share_url", current:"current_session_key"
  };
  const SESSION_MAP = {
    date:"date", status:"status", pricePerSet:"price_per_set", deadlineAt:"deadline_at",
    deadline:"deadline", autoClose:"auto_close", hostName:"host_name", shopName:"shop_name",
    menu:"menu", createdAt:"created_at"
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

  /* ---------- host token state ----------
     2 link: index.html (thành viên) và index.html?manage=<token> (host).
     Token trong URL được lưu lại vào localStorage lần đầu mở link host,
     nên các lần mở sau không cần ?manage=... trên URL nữa. */
  const HostAuth = {
    get token(){
      const fromUrl = new URLSearchParams(location.search).get("manage");
      if (fromUrl){ lsSet("comtrua:hosttoken", fromUrl); return fromUrl; }
      return lsGet("comtrua:hosttoken") || null;
    },
    clear(){ try{ localStorage.removeItem("comtrua:hosttoken"); }catch{} }
  };
  async function verifyToken(token){
    if (!token) return false;
    const { data, error } = await sb.rpc("verify_host_token", { token_try: token });
    if (error) throw error;
    return !!data;
  }
  async function rpc(name, params){
    const { data, error } = await sb.rpc(name, params);
    if (error){ const e = new Error(error.message); e.code = error.code==="P0001" && /invalid_token/.test(error.message) ? "invalid_token" : "write_failed"; throw e; }
    return data;
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
          // order doc gộp nhiều session vào field "days" ở bản cũ; ở đây ta chỉ
          // hỗ trợ đọc/ghi 1 session cụ thể qua mutateOrder (xem adapter riêng bên dưới).
          throw new Error("orders.doc().get() không hỗ trợ trực tiếp — dùng mutateOrder");
        }
        throw new Error("Không rõ collection: " + coll);
      },
      async set(obj){
        if (coll==="config"){
          // set() cho config chỉ dùng ở save-settings, đã có host token xác thực trước đó.
          const tk = HostAuth.token; if(!tk) { const e=new Error("no token"); e.code="invalid_argument"; throw e; }
          const merged = { ...obj };
          await rpc("update_config", {
            token_try: tk,
            p_bank_bin: merged.bankBin ?? null, p_bank_name: merged.bankName ?? null,
            p_account_no: merged.accountNo ?? null, p_account_name: merged.accountName ?? null,
            p_price_per_set: Number(merged.pricePerSet)||35000, p_host_pays: !!merged.hostPays,
            p_show_payment_to_team: !!merged.showPaymentToTeam, p_share_url: merged.shareUrl ?? null,
            p_current_session_key: merged.current ?? null
          });
          return;
        }
        throw new Error("set() không hỗ trợ cho " + coll);
      },
      async update(patch){
        if (coll==="config"){
          const tk = HostAuth.token; if(!tk){ const e=new Error("no token"); e.code="invalid_argument"; throw e; }
          const { data:cur } = await sb.from("config").select("*").eq("id",1).maybeSingle();
          const curApp = cur ? toApp(cur, CONFIG_MAP) : {};
          const merged = { ...curApp, ...patch };
          await rpc("update_config", {
            token_try: tk,
            p_bank_bin: merged.bankBin ?? null, p_bank_name: merged.bankName ?? null,
            p_account_no: merged.accountNo ?? null, p_account_name: merged.accountName ?? null,
            p_price_per_set: Number(merged.pricePerSet)||35000, p_host_pays: !!merged.hostPays,
            p_show_payment_to_team: !!merged.showPaymentToTeam, p_share_url: merged.shareUrl ?? null,
            p_current_session_key: merged.current ?? null
          });
          return;
        }
        if (coll==="sessions"){
          const tk = HostAuth.token; if(!tk){ const e=new Error("no token"); e.code="invalid_argument"; throw e; }
          const { data:cur } = await sb.from("sessions").select("*").eq("key", id).maybeSingle();
          if (!cur) throw new Error("session không tồn tại");
          const curApp = toApp(cur, SESSION_MAP);
          const merged = { ...curApp, ...patch };
          await rpc("upsert_session", {
            token_try: tk, p_key: id, p_date: merged.date, p_status: merged.status,
            p_price_per_set: Number(merged.pricePerSet)||35000, p_deadline_at: merged.deadlineAt||0,
            p_deadline: merged.deadline||null, p_auto_close: merged.autoClose!==false,
            p_host_name: merged.hostName||null, p_shop_name: merged.shopName||null, p_menu: merged.menu||[]
          });
          return;
        }
        throw new Error("update() không hỗ trợ cho " + coll);
      },
      async delete(){
        if (coll==="sessions"){
          const tk = HostAuth.token; if(!tk){ const e=new Error("no token"); e.code="invalid_argument"; throw e; }
          await rpc("delete_session", { token_try: tk, p_key: id });
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

  const db = { doc, collection: coll, mutateOrder };

  /* ---------- user ---------- */
  const user = {
    id: async () => getOrCreateUid(),
    canEdit: async () => verifyToken(HostAuth.token).catch(()=>false),
    isOwner: async () => verifyToken(HostAuth.token).catch(()=>false)
  };

  /* ---------- sample (đọc ảnh AI) — CHƯA khả dụng trong bản Supabase ---------- */
  const sample = null; // giữ null để app tự tắt UI đọc ảnh (S.imagesOK=false)

  function requireToken(){
    const tk = HostAuth.token;
    if (!tk){ const e = new Error("no token"); e.code = "invalid_argument"; throw e; }
    return tk;
  }

  /* ---------- host auth helpers lộ ra ngoài cho index.html gọi trực tiếp ---------- */
  window.HostAuth = { ...HostAuth, verifyToken };
  window.upsertDish = async (id, nameVi, nameEn) => rpc("upsert_dish", { p_id:id, p_name_vi:nameVi, p_name_en:nameEn||"" });
  window.hostSetOrderPay = async (sessionKey, docId, payStatus) => rpc("host_set_order_pay", { token_try:requireToken(), p_session_key:sessionKey, p_doc_id:docId, p_pay_status:payStatus });
  window.hostDeleteOrder = async (sessionKey, docId) => rpc("host_delete_order", { token_try:requireToken(), p_session_key:sessionKey, p_doc_id:docId });
  window.hostSetSessionStatus = async (key, status) => rpc("set_session_status", { token_try:requireToken(), p_key:key, p_status:status });
  window.hostUpsertSession = async (fields) => rpc("upsert_session", { token_try:requireToken(), p_key:fields.key, p_date:fields.date, p_status:fields.status||"open",
    p_price_per_set:Number(fields.pricePerSet)||35000, p_deadline_at:fields.deadlineAt||0, p_deadline:fields.deadline||null,
    p_auto_close:fields.autoClose!==false, p_host_name:fields.hostName||null, p_shop_name:fields.shopName||null, p_menu:fields.menu||[] });

  window.SupabaseAdapter = { db, user, sample };
})();
