// ============================================================
// Supabase adapter (bản RPC) — giả lập API kiểu Claude Artifact (db.doc/
// collection/onSnapshot, user, sample) trên Supabase, để index.html gần như
// không phải đổi phần UI/event logic.
//
// KHÁC BẢN CŨ: không còn đọc/ghi thẳng bảng bằng anon key. Mọi thao tác đi qua
// hàm máy chủ lunch_* (SECURITY DEFINER, xem lunch-rpc-schema.sql) kiểm tra
// token trên URL. Hệ quả:
//   - Chỉ tải dữ liệu của ĐÚNG session mà token trỏ tới (bản cũ tải mọi session,
//     kể cả manage_token của người khác).
//   - Không còn Supabase Realtime (anon không còn quyền SELECT) → thăm dò
//     (polling) lunch_get_state mỗi POLL_MS khi tab đang hiện, và ngay sau mỗi lần ghi.
//
// Mô hình link (không đổi):
//   - Link gốc  index.html                           → màn "Tạo đơn nhóm mới", chưa gắn session.
//   - Link quản lý  index.html?manage=<manage_token> → toàn quyền ĐÚNG session đó.
//   - Link đơn (guest)  index.html?order=<order_token> → xem/đặt món ĐÚNG session đó.
//
// Cần nạp @supabase/supabase-js (UMD) TRƯỚC file này, và định nghĩa
// window.SUPABASE_URL, window.SUPABASE_ANON_KEY trước khi load file này.
// ============================================================
(function(){
  if (!window.supabase?.createClient){ console.error("supabase-js chưa được nạp"); return; }
  if (!window.SUPABASE_URL || !window.SUPABASE_ANON_KEY){ console.error("Thiếu SUPABASE_URL/SUPABASE_ANON_KEY"); return; }
  const sb = window.supabase.createClient(window.SUPABASE_URL, window.SUPABASE_ANON_KEY);

  const POLL_MS = 5000;          // chu kỳ thăm dò state khi tab đang hiện
  const DISHES_POLL_MS = 30000;  // thư viện món đổi chậm hơn nhiều
  const CONFIG_POLL_MS = 60000;

  function lsGet(k){ try{ return localStorage.getItem(k); }catch{ return null; } }
  function lsSet(k,v){ try{ localStorage.setItem(k,v); }catch{} }
  const rid = () => Math.random().toString(36).slice(2, 10);

  /* ---------- uid ẩn danh của trình duyệt này ---------- */
  function getOrCreateUid(){
    let id = lsGet("comtrua:uid");
    if (!id){ id = "u" + rid() + rid(); lsSet("comtrua:uid", id); }
    return id;
  }

  /* ---------- link trên URL ---------- */
  const qs = new URLSearchParams(location.search);
  const manageToken = qs.get("manage") || null;
  const orderToken = qs.get("order") || null;
  const token = manageToken || orderToken || null;

  /* ---------- map field: snake_case (DB) <-> camelCase (app) ---------- */
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

  /* ---------- gọi RPC: ném lỗi khi {ok:false} ---------- */
  async function rpc(fn, args){
    const { data, error } = await sb.rpc(fn, args || {});
    if (error) throw error;
    if (data && typeof data === "object" && data.ok === false){
      const e = new Error("Không thực hiện được: " + (data.reason || "lỗi không rõ"));
      e.reason = data.reason; throw e;
    }
    return data;
  }

  /* ---------- Poller dùng chung: một trạng thái cho cả trang ---------- */
  function makePoller(fetchFn, intervalMs){
    const subs = new Set(); let timer = null, last = null, lastJson = null, busy = false;
    async function tick(force){
      if (busy) return; busy = true;
      try{
        const v = await fetchFn();
        const j = JSON.stringify(v);
        if (force || j !== lastJson){ last = v; lastJson = j; subs.forEach(s => { try{ s.onNext(v); }catch(e){ console.error(e); } }); }
      }catch(e){ subs.forEach(s => { try{ s.onErr?.(e); }catch{} }); }
      finally{ busy = false; }
    }
    function start(){
      if (timer) return;
      timer = setInterval(() => { if (document.visibilityState !== "hidden") tick(false); }, intervalMs);
    }
    function stop(){ clearInterval(timer); timer = null; }
    document.addEventListener("visibilitychange", () => { if (document.visibilityState === "visible" && subs.size) tick(false); });
    return {
      subscribe(onNext, onErr){
        const s = { onNext, onErr }; subs.add(s);
        if (lastJson !== null) { try{ onNext(last); }catch(e){ console.error(e); } } else tick(true);
        start();
        return () => { subs.delete(s); if (!subs.size) stop(); };
      },
      refresh: () => tick(false),
      get last(){ return last; }
    };
  }

  const statePoller = makePoller(async () => {
    if (!token) return { ok:true, role:null, session:null, orders:[], drafting:[] }; // link gốc: chưa có session
    const { data, error } = await sb.rpc("lunch_get_state", { p_token: token });
    if (error) throw error;
    return data; // {ok:false, reason:'not_found'} nếu token sai/đã xoá
  }, POLL_MS);
  const configPoller = makePoller(async () => (await rpc("lunch_get_config")) || {}, CONFIG_POLL_MS);
  const dishesPoller = makePoller(async () => (await rpc("lunch_list_dishes")) || [], DISHES_POLL_MS);

  const stateSession = () => { const s = statePoller.last; return s?.ok ? s.session : null; };
  const requireManage = () => { if (!manageToken) throw new Error("Cần mở bằng link quản lý (?manage=...) để thực hiện thao tác này"); return manageToken; };

  /* ---------- session vừa tạo trong phiên trang này (để lấy token sau khi tạo) ---------- */
  const createdCache = {};

  /* ---------- doc() ---------- */
  function doc(path){
    const [coll, id] = path.split("/");
    return {
      path, id,
      async get(){
        if (coll==="config"){
          const data = await rpc("lunch_get_config");
          const has = data && Object.keys(data).length > 0;
          return { id:"main", exists: has, data: () => has ? toApp(data, CONFIG_MAP) : null };
        }
        if (coll==="sessions"){
          if (createdCache[id]){ const row = createdCache[id]; return { id, exists:true, data: () => toApp(row, SESSION_MAP) }; }
          if (token){
            await statePoller.refresh();
            const s = stateSession();
            if (s && s.key === id) return { id, exists:true, data: () => toApp(s, SESSION_MAP) };
          }
          // Không có token cho session này: chỉ biết có tồn tại hay không (kiểm tra trùng key lúc tạo đơn).
          const exists = !!(await rpc("lunch_session_exists", { p_key: id }));
          return { id, exists, data: () => null };
        }
        if (coll==="orders") throw new Error("orders.doc().get() không hỗ trợ trực tiếp — dùng mutateOrder");
        throw new Error("Không rõ collection: " + coll);
      },
      async set(obj){
        if (coll==="config"){
          await rpc("lunch_set_config", { p_manage_token: requireManage(), p_patch: toDb(obj, CONFIG_MAP) });
          configPoller.refresh(); return;
        }
        if (coll==="sessions"){
          // Chỉ dùng để TẠO session mới (sửa đơn đi qua update()).
          const fields = toDb(obj, SESSION_MAP);
          delete fields.order_token; delete fields.manage_token; delete fields.created_at;
          const res = await rpc("lunch_create_session", { p_key: id, p_fields: fields });
          createdCache[id] = { key:id, ...fields, order_token:res.order_token, manage_token:res.manage_token, created_at:res.created_at };
          return;
        }
        throw new Error("set() không hỗ trợ cho " + coll);
      },
      async update(patch){
        if (coll==="config"){
          await rpc("lunch_set_config", { p_manage_token: requireManage(), p_patch: toDb(patch, CONFIG_MAP) });
          configPoller.refresh(); return;
        }
        if (coll==="sessions"){
          await rpc("lunch_update_session", { p_manage_token: requireManage(), p_patch: toDb(patch, SESSION_MAP) });
          statePoller.refresh(); return;
        }
        throw new Error("update() không hỗ trợ cho " + coll);
      },
      async delete(){
        if (coll==="sessions"){
          await rpc("lunch_delete_session", { p_manage_token: requireManage() });
          statePoller.refresh(); return;
        }
        throw new Error("delete() không hỗ trợ cho " + coll);
      },
      onSnapshot(onNext, onErr){
        if (coll==="config"){
          return configPoller.subscribe(data => {
            const has = data && Object.keys(data).length > 0;
            onNext({ id:"main", exists: has, data: () => has ? toApp(data, CONFIG_MAP) : null });
          }, onErr);
        }
        if (coll==="sessions"){
          return statePoller.subscribe(st => {
            const s = st?.ok ? st.session : null;
            const hit = s && s.key === id;
            onNext({ id, exists: !!hit, data: () => hit ? toApp(s, SESSION_MAP) : null });
          }, onErr);
        }
        throw new Error("onSnapshot không hỗ trợ cho " + coll);
      }
    };
  }

  /* ---------- tìm session theo token (xác định session mà link trỏ tới) ---------- */
  async function resolveKey(expectRole, tk){
    if (!tk) return null;
    const { data, error } = await sb.rpc("lunch_get_state", { p_token: tk });
    if (error || !data?.ok) return null;
    if (expectRole && data.role !== expectRole) return null;
    return data.session?.key || null;
  }
  const findSessionKeyByOrderToken  = (tk) => resolveKey("order", tk);
  const findSessionKeyByManageToken = (tk) => resolveKey("manage", tk);

  /* ---------- mutateOrder: đọc-sửa-ghi 1 order ---------- */
  async function mutateOrder(docId, sessionKey, fn){
    if (!token) throw new Error("Thiếu link đơn (?order=... hoặc ?manage=...)");
    const cur = await rpc("lunch_get_order", { p_token: token, p_doc_id: docId });
    const curApp = cur?.order ? toApp(cur.order, ORDER_MAP) : null;
    const next = fn(curApp);
    const p_order = (next === null || next === undefined) ? null : toDb(next, ORDER_MAP);
    await rpc("lunch_put_order", { p_token: token, p_doc_id: docId, p_order });
    statePoller.refresh();
  }

  /* ---------- drafting: "X đang đặt..." ---------- */
  async function setDrafting(sessionKey, docId, name){
    if (!token) return;
    await rpc("lunch_set_drafting", { p_token: token, p_doc_id: docId, p_name: name || "" });
  }
  async function clearDrafting(sessionKey, docId){
    if (!token) return;
    await rpc("lunch_clear_drafting", { p_token: token, p_doc_id: docId });
    statePoller.refresh();
  }
  function watchDrafting(sessionKey, onNext, onErr){
    // Chỉ link quản lý nhận được danh sách drafting (server trả [] cho link đơn).
    return statePoller.subscribe(st => onNext(st?.ok ? (st.drafting || []) : []), onErr);
  }

  /* ---------- collection() ---------- */
  function coll(path){
    const name = path.split("/")[0];
    const q = {};
    q.orderBy = () => q; q.limit = () => q; q.where = () => q;
    q.onSnapshot = (onNext, onErr) => {
      if (name === "orders"){
        // App cũ mong shape orders/{docId}.days[sessionKey]; state chỉ chứa đúng 1 session.
        return statePoller.subscribe(st => {
          const rows = st?.ok ? (st.orders || []) : [];
          const docs = rows.map(r => ({ id: r.doc_id, data: () => ({ days: { [r.session_key]: toApp(r, ORDER_MAP) } }) }));
          onNext({ docs, size: docs.length, empty: !docs.length });
        }, onErr);
      }
      if (name === "dishes"){
        return dishesPoller.subscribe(rows => {
          const docs = (rows || []).map(r => ({ id: r.id, data: () => ({ nameVi:r.name_vi, nameEn:r.name_en, timesUsed:r.times_used, lastUsed:r.last_used }) }));
          onNext({ docs, size: docs.length, empty: !docs.length });
        }, onErr);
      }
      throw new Error("collection không hỗ trợ: " + name);
    };
    return q;
  }

  const db = { doc, collection: coll, mutateOrder, findSessionKeyByOrderToken, findSessionKeyByManageToken, setDrafting, clearDrafting, watchDrafting };

  /* ---------- user ---------- */
  // canEdit/isOwner: true khi ?manage=... khớp một session đang tồn tại (xác minh
  // 1 lần ở boot() qua resolveManageAccess()).
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

  /* ---------- sample (đọc ảnh AI) — chưa khả dụng ---------- */
  const sample = null; // giữ null để app tự tắt UI đọc ảnh (S.imagesOK=false)

  /* ---------- helpers cho index.html ---------- */
  window.upsertDish = async (id, nameVi, nameEn) => {
    const { data, error } = await sb.rpc("upsert_dish", { p_id:id, p_name_vi:nameVi, p_name_en:nameEn||"" });
    if (error) throw error;
    dishesPoller.refresh();
    return data;
  };
  window.deleteDish = async (id) => {
    await rpc("lunch_delete_dish", { p_manage_token: requireManage(), p_id: id });
    dishesPoller.refresh();
  };
  window.SupabaseOrderToken = orderToken;
  window.SupabaseManageToken = manageToken;
  window.SupabaseResolveManageAccess = resolveManageAccess; // PHẢI await trong boot() TRƯỚC user.canEdit()/isOwner()

  window.SupabaseAdapter = { db, user, sample };
})();
