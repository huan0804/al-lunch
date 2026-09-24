// in-memory mock of claude.use for smoke testing
(function(){
 const store={}; const subs=[];
 const notify=()=>subs.forEach(f=>f());
 function docSnap(path){const d=store[path];return {id:path.split('/').pop(),exists:!!d,data:()=>d&&JSON.parse(JSON.stringify(d)),metadata:{}};}
 function doc(path){return {path,id:path.split('/').pop(),
  get:async()=>docSnap(path), set:async d=>{store[path]=JSON.parse(JSON.stringify(d));notify()},
  update:async d=>{store[path]={...store[path],...d};notify()}, delete:async()=>{delete store[path];notify()},
  onSnapshot:(n)=>{const f=()=>n(docSnap(path));subs.push(f);setTimeout(f,0);return()=>{}}}}
 function coll(path){const q={orderBy:()=>q,limit:()=>q,where:()=>q,
  onSnapshot:(n)=>{const f=()=>{const docs=Object.keys(store).filter(k=>k.startsWith(path+'/')&&k.split('/').length===path.split('/').length+1).map(docSnap);n({docs,size:docs.length,empty:!docs.length})};subs.push(f);setTimeout(f,0);return()=>{}}};return q;}
 const db={doc,collection:coll};
 const user={id:async()=>"u1",canEdit:async()=>true,isOwner:async()=>true};
 const sample=Object.assign(async()=>({text:""}),{json:async()=>[{nameVi:"Gà kho gừng",nameEn:"Ginger chicken"},{nameVi:"Thịt kho trứng",nameEn:""}],limits:async()=>({images:{}})});
 window.claude={use:async n=>({db,user,sample})[n]||null};
 window.__store=store;
})();
