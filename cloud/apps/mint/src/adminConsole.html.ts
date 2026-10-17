/**
 * The owner admin console page — the port of mint.py's _ADMIN_HTML
 * (mint.py:2026-2276). Served BYTE-STABLE by GET /admin and /admin/ui on the
 * ADMIN listener only (localhost / SSH-tunnel rule; Caddy never routes
 * /admin — see app.ts: adminApp listens on its own port).
 *
 * It is a PURE CLIENT of the /admin JSON API in adminRoutes.ts: the master
 * key is pasted into the tab and kept in memory only; every number is
 * fetched live. No server-side interpolation ever touches this string.
 *
 * Port deltas from the Python page (all client-side only):
 *  - the audit table renders {before, after} (the TS audit entry carries no
 *    `result` field — the route responses own their results);
 *  - nothing else: sections, ids and the API call shapes match the README.
 */
export const ADMIN_CONSOLE_HTML = `<!doctype html><html><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<meta name=referrer content=no-referrer>
<title>Ovid Admin</title>
<style>
 body{font:14px/1.5 system-ui,sans-serif;max-width:1180px;margin:0 auto;padding:24px;background:#0d1117;color:#e6edf3}
 h1{font-size:20px}h2{font-size:14px;margin:26px 0 8px;color:#8b949e;text-transform:uppercase;letter-spacing:.08em}
 .card{background:#161b22;border:1px solid #30363d;border-radius:12px;padding:16px;margin:10px 0;overflow-x:auto}
 label{display:block;font-size:12px;color:#8b949e;margin:8px 0 4px}
 input,select{width:100%;box-sizing:border-box;padding:7px;border-radius:7px;border:1px solid #30363d;background:#0d1117;color:#e6edf3;font-size:13px}
 input[type=checkbox]{width:auto}
 button{margin:10px 8px 0 0;padding:8px 13px;border:0;border-radius:8px;background:#2f81f7;color:#fff;font-size:13px;font-weight:600;cursor:pointer}
 button.danger{background:#da3633}button.ghost{background:#30363d}button.sm{margin:0;padding:5px 9px}
 .row{display:flex;gap:10px;flex-wrap:wrap}.row>div{flex:1;min-width:130px}
 .out{margin-top:10px;font-size:12px;color:#7ee787;white-space:pre-wrap;font-family:ui-monospace,monospace}
 .err{color:#ff7b72}.muted{color:#8b949e;font-size:12px}
 table{width:100%;border-collapse:collapse;font-size:13px;margin-top:8px}
 th,td{text-align:left;padding:5px 6px;border-bottom:1px solid #30363d;vertical-align:top}
 th{color:#8b949e;font-weight:600}td.num{text-align:right;font-variant-numeric:tabular-nums}
 td input,td select{min-width:70px}
 .kv{display:grid;grid-template-columns:210px 1fr;gap:4px 12px;font-size:13px}.kv div:nth-child(odd){color:#8b949e}
</style></head><body>
<h1>Ovid Cloud — Admin</h1>
<div class=card>
 <label>Master key (stays in this tab only)</label>
 <input id=mk type=password placeholder="sk-..." autocomplete=off>
 <button onclick=loadAll()>Load</button>
 <div class=muted>Every number below is live: saving takes effect immediately (no restart), is re-applied to all affected keys (android + web) and is written to the audit log.</div>
</div>

<h2>Global limits</h2>
<div class=card>
 <div class=row>
  <div><label>Free allowance per user per 24h (USD)</label><input id=g_free_daily_usd type=number step=0.01 min=0></div>
  <div><label>Free monthly backstop per user (USD / 30 days)</label><input id=g_free_monthly_cap_usd type=number step=0.01 min=0></div>
  <div><label>Key ceiling for slow-mode plans (× allowance)</label><input id=g_hard_ceiling_mult type=number step=0.1 min=1></div>
 </div>
 <div class=muted>The monthly backstop is a second cap on free users across all their keys: with a high daily amount it stops a heavy user after a few days (e.g. $3/day with a $10 backstop: day 4). <span id=backstopNote></span></div>
 <div class=row>
  <div><label>Normal rpm</label><input id=g_normal_rpm type=number min=1></div>
  <div><label>Normal tpm</label><input id=g_normal_tpm type=number min=1></div>
  <div><label>Normal parallel</label><input id=g_normal_parallel type=number min=1></div>
  <div><label>Slow-mode rpm</label><input id=g_slow_rpm type=number min=1></div>
  <div><label>Slow-mode tpm</label><input id=g_slow_tpm type=number min=1></div>
  <div><label>Slow-mode parallel</label><input id=g_slow_parallel type=number min=1></div>
 </div>
 <div class=row>
  <div><label>Typical message: input tokens</label><input id=g_est_input_tokens type=number min=1></div>
  <div><label>Typical message: output tokens</label><input id=g_est_output_tokens type=number min=1></div>
  <div><label>Typical image: output tokens</label><input id=g_est_image_tokens type=number min=1></div>
 </div>
 <button onclick=saveGlobal()>Save global limits</button>
 <div class=out id=globalOut></div>
</div>

<h2>Plans</h2>
<div class=card>
 <div class=muted>Every plan is one allowance per window = the user's free allowance × mult (per 24h, scaled by the window: 720h = 30 days → ×30), consumed at each model's LiteLLM price. When it is used up: <b>daily_limit_reached</b> until the window resets — or, with <b>slow</b> ticked, requests continue with the slow-mode limits (up to the key ceiling). Price is admin/plan-screen metadata only. Disable = stop selling; users already on it keep it.</div>
 <table><thead><tr><th>id</th><th>name</th><th>price $</th><th>on</th><th>aliases</th><th>window h</th><th>mult</th><th>allowance / 24h</th><th>slow</th><th>auto uses auto-oss</th><th></th></tr></thead><tbody id=planRows></tbody></table>
 <button class=ghost onclick=addPlanRow()>Add plan</button>
 <div class=out id=planOut></div>
</div>

<h2>Auto-oss members (hidden auto routing)</h2>
<div class=card>
 <div class=muted>For plans with "auto uses auto-oss" ticked, a request for <b>auto</b> goes to one of these LiteLLM models (weighted random; the others are fallbacks). The app still sees "auto". Names are checked against LiteLLM; if none is usable, plain auto is used.</div>
 <table><thead><tr><th>Model</th><th>Weight</th><th></th></tr></thead><tbody id=memberRows></tbody></table>
 <div class=row><div><label>Add model</label><select id=memberAdd></select></div><div><label>Weight</label><input id=memberWeight type=number step=0.1 min=0.0001 value=1></div></div>
 <button class=ghost onclick=addMember()>Add</button>
 <button onclick=saveMembers()>Save members</button>
 <div class=out id=memberOut></div>
</div>

<h2>Model prices (from LiteLLM, admin only)</h2>
<div class=card>
 <div class=muted>Prices are set in LiteLLM. The app turns the remaining allowance into "messages left" per model using these prices and the typical message/image sizes above; users never see amounts. Auto is estimated at its most expensive member.</div>
 <table><thead><tr><th>Model</th><th>Kind</th><th class=num>In $/tok</th><th class=num>Out $/tok</th><th class=num>$/image</th><th class=num>Est. $/message or image</th></tr></thead><tbody id=priceRows></tbody></table>
 <div class=out id=priceOut></div>
</div>

<h2>User</h2>
<div class=card>
 <div class=row><div><label>uid or email</label><input id=q placeholder="firebase uid or user@gmail.com" onkeydown="if(event.key==='Enter')lookup()"></div></div>
 <button onclick=lookup()>Look up</button>
 <div class=out id=userOut></div>
 <div id=userBox style="display:none">
  <div class=kv id=userKv style="margin-top:12px"></div>
  <h2>Models as the app sees them</h2>
  <table><thead><tr><th>Model</th><th>Class / pool</th><th class=num>Remaining</th><th>Estimate</th><th class=num>Requests</th><th class=num>Tokens in / out</th><th class=num>Images</th></tr></thead><tbody id=modelRows></tbody></table>
  <h2>Change this user</h2>
  <div class=row>
   <div><label>Plan</label><select id=u_tier></select></div>
   <div><label>Custom free limit (USD / 24h)</label><input id=u_daily type=number step=0.01 min=0></div>
   <div><label>Custom monthly backstop (USD)</label><input id=u_cap type=number step=0.01 min=0></div>
  </div>
  <div class=row>
   <div><label>Custom plan: mult</label><input id=u_p_mult type=number step=0.1 min=0></div>
   <div><label>Custom plan: window hours</label><input id=u_p_window_hours type=number min=1></div>
   <div><label>Custom plan: slow mode</label><select id=u_p_slow_mode><option value="">(plan default)</option><option value=true>on</option><option value=false>off</option></select></div>
   <div><label>Custom plan: auto uses auto-oss</label><select id=u_p_auto_oss><option value="">(plan default)</option><option value=true>on</option><option value=false>off</option></select></div>
  </div>
  <button onclick=saveUser()>Save plan + overrides</button>
  <button class=ghost onclick="clearUser('clear_daily_usd')">Clear custom free limit</button>
  <button class=ghost onclick="clearUser('clear_monthly_cap_usd')">Clear custom backstop</button>
  <button class=ghost onclick="clearUser('clear_pools')">Clear custom plan</button>
  <br><button class=ghost onclick=resetUser()>Reset window now</button>
  <label style="display:inline"><input type=checkbox id=u_month> also reset monthly backstop</label>
  <button class=danger onclick=banUser(true)>Ban</button>
  <button class=ghost onclick=banUser(false)>Unban</button>
  <div class=out id=userActOut></div>
 </div>
</div>

<h2>All users</h2>
<div class=card>
 <button class=danger onclick=resetAll()>Reset window for ALL users now</button>
 <label style="display:inline"><input type=checkbox id=all_month> also reset monthly backstops</label>
 <div class=out id=resetStatus></div>
 <div class=row><div><label>IP</label><input id=banIp></div></div>
 <button class=danger onclick=ipBan(true)>Ban IP (30 days)</button>
 <button class=ghost onclick=ipBan(false)>Unban IP</button>
 <div class=out id=miscOut></div>
</div>

<h2>Audit log</h2>
<div class=card>
 <button class=ghost onclick=loadAudit()>Refresh</button>
 <table><thead><tr><th>When (UTC)</th><th>Action</th><th>Target</th><th>Change</th></tr></thead><tbody id=auditRows></tbody></table>
</div>

<script>
const $=id=>document.getElementById(id);
const GLOBAL=['free_daily_usd','free_monthly_cap_usd','hard_ceiling_mult','normal_rpm','normal_tpm','normal_parallel','slow_rpm','slow_tpm','slow_parallel','est_input_tokens','est_output_tokens','est_image_tokens'];
const PFIELDS=['mult','window_hours'];const PBOOLS=['slow_mode','auto_oss'];let members=[];
let current=null, settings=null, models=[];
function mk(){return $('mk').value.trim()}
async function api(method,path,body){
 const r=await fetch(path,{method,headers:{'Authorization':'Bearer '+mk(),'Content-Type':'application/json'},body:body?JSON.stringify(body):undefined});
 const t=await r.text(); let j=null; try{j=JSON.parse(t)}catch(e){}
 if(!r.ok) throw new Error(r.status+' '+(j&&j.detail?JSON.stringify(j.detail):t));
 return j;
}
function show(id,v,err){const o=$(id);o.className='out'+(err?' err':'');o.textContent=typeof v==='string'?v:JSON.stringify(v,null,1)}
function el(tag,attrs,text){const e=document.createElement(tag);for(const k in (attrs||{}))e[k]=attrs[k];if(text!==undefined)e.textContent=text;return e}
function cell(tr,v,cls){const td=el('td',{},(v===null||v===undefined)?'—':String(v));if(cls)td.className=cls;tr.appendChild(td);return td}
function num(v){v=String(v).trim();return v===''?null:Number(v)}
function money(v){return '$'+Number(v||0).toFixed(2)}
async function loadAll(){await loadSettings();await loadModels();await loadAudit();pollReset()}
async function loadSettings(){
 try{const j=await api('GET','/admin/settings');settings=j.settings;
  for(const k of GLOBAL)$('g_'+k).value=settings[k];
  const f=settings.free_daily_usd,c=settings.free_monthly_cap_usd;
  $('backstopNote').textContent=f>0&&c>0?'Now: '+money(f)+'/day and '+money(c)+'/30 days, so a user spending the full daily amount stops after about '+Math.ceil(c/f)+' day(s).':'';
  renderPlans();members=(settings.auto_oss_members||[]).map(m=>({...m}));renderMembers();
  const sel=$('u_tier');sel.textContent='';for(const p of settings.plans)sel.appendChild(el('option',{value:p.id},p.name+' ('+p.id+(p.aliases.length?' / '+p.aliases.join(','):'')+')'+(p.enabled?'':' [disabled]')));
  show('globalOut',j.users+' known users');
 }catch(e){show('globalOut',String(e),true)}
}
async function saveGlobal(){
 const b={reapply:true};for(const k of GLOBAL){const v=$('g_'+k).value;b[k]=num(v)}
 try{const j=await api('POST','/admin/settings',b);show('globalOut',{saved:true,reapplied:j.reapplied});loadSettings();loadAudit()}catch(e){show('globalOut',String(e),true)}
}
function planRow(p,isNew){
 const tr=el('tr');const inp=(k,type,v)=>{const td=el('td');const i=el('input',{type:type||'text',value:v??''});i.dataset.k=k;if(type==='number')i.step='any';td.appendChild(i);tr.appendChild(td);return i};
 const id=inp('id','text',p.id);if(!isNew)id.readOnly=true;
 inp('name','text',p.name);inp('price_usd','number',p.price_usd);
 const td=el('td');const cb=el('input',{type:'checkbox',checked:p.enabled!==false});cb.dataset.k='enabled';td.appendChild(cb);tr.appendChild(td);
 inp('aliases','text',(p.aliases||[]).join(','));
 inp('window_hours','number',p.window_hours);inp('mult','number',p.mult);
 cell(tr,isNew?'—':money((settings.free_daily_usd||0)*(p.mult||0)));
 for(const k of ['slow_mode','auto_oss']){const tsl=el('td');const sl=el('input',{type:'checkbox',checked:!!p[k]});sl.dataset.k=k;tsl.appendChild(sl);tr.appendChild(tsl)}
 const ts=el('td');const b=el('button',{className:'sm'},'Save');b.onclick=()=>savePlan(tr);ts.appendChild(b);tr.appendChild(ts);
 return tr;
}
function renderPlans(){const tb=$('planRows');tb.textContent='';for(const p of settings.plans)tb.appendChild(planRow(p,false))}
function addPlanRow(){$('planRows').appendChild(planRow({window_hours:24,mult:1,enabled:false,slow_mode:false,auto_oss:false,aliases:[]},true))}
async function savePlan(tr){
 const b={reapply:true};for(const i of tr.querySelectorAll('[data-k]')){const k=i.dataset.k;
  if(['enabled','slow_mode','auto_oss'].includes(k))b[k]=i.checked;else if(k==='aliases')b[k]=i.value.split(',').map(x=>x.trim()).filter(Boolean);
  else if(['id','name'].includes(k))b[k]=i.value.trim();else{const v=num(i.value);if(v!==null)b[k]=v}}
 try{const j=await api('POST','/admin/plans',b);show('planOut',{saved:b.id,reapplied:j.reapplied});loadSettings();loadAudit()}catch(e){show('planOut',String(e),true)}
}
function renderMembers(){const tb=$('memberRows');tb.textContent='';
 members.forEach((m,i)=>{const tr=el('tr');cell(tr,m.model);const tw=el('td');const w=el('input',{type:'number',step:'any',value:m.weight});w.onchange=()=>{m.weight=num(w.value)};tw.appendChild(w);tr.appendChild(tw);
  const td=el('td');const b=el('button',{className:'sm danger'},'Remove');b.onclick=()=>{members.splice(i,1);renderMembers()};td.appendChild(b);tr.appendChild(td);tb.appendChild(tr)})}
function addMember(){const m=$('memberAdd').value;if(!m||members.some(x=>x.model===m))return;members.push({model:m,weight:num($('memberWeight').value)||1});renderMembers()}
async function saveMembers(){try{await api('POST','/admin/settings',{auto_oss_members:members,reapply:false});show('memberOut','saved');loadSettings();loadAudit()}catch(e){show('memberOut',String(e),true)}}
async function loadModels(){
 try{const j=await api('GET','/admin/models');const tb=$('priceRows');tb.textContent='';
  const sel=$('memberAdd');sel.textContent='';for(const m of j.models)if(!m.members&&m.kind==='chat')sel.appendChild(el('option',{value:m.id},m.id));
  for(const m of j.models){const tr=el('tr');cell(tr,m.name+(m.members?' (auto: '+m.members.join(', ')+')':''));cell(tr,m.kind);
   cell(tr,m.input_cost_per_token,'num');cell(tr,m.output_cost_per_token,'num');cell(tr,m.output_cost_per_image,'num');
   cell(tr,m.est_unit_cost_usd==null?'unpriced':'$'+Number(m.est_unit_cost_usd).toFixed(5),'num');tb.appendChild(tr)}
 }catch(e){show('priceOut',String(e),true)}
}
async function lookup(){
 const q=$('q').value.trim();if(!q)return;
 try{current=await api('GET','/admin/user?q='+encodeURIComponent(q));renderUser();show('userOut','')}
 catch(e){$('userBox').style.display='none';show('userOut',String(e),true)}
}
function renderUser(){
 const u=current,t=u.today,kv=$('userKv');kv.textContent='';const a=u.pool_state_usd.all;
 const rows=[['uid',u.uid],['email',u.email],['plan',u.plan.name+' ('+u.plan.id+', stored as '+u.tier+', ×'+u.plan.mult+(u.plan.slow_mode?', slow mode':'')+')'],['banned',u.banned||'no'],
  ['free allowance / 24h',money(u.free_daily_usd)+(u.override_daily_usd!==null?' (custom)':' (global)')],
  ['custom plan',u.override_pools?JSON.stringify(u.override_pools):'none'],
  ['window',u.window+': '+u.window_start+' → '+u.resets_at],
  ['allowance',money(a.spent)+' of '+money(a.cap)+' · left '+money(a.remaining)+' ('+Math.round(u.remaining_fraction*100)+'%)'+(u.slow_mode?' · SLOW MODE':'')],
  ['window usage',t.requests+' requests · '+t.input_tokens+' in / '+t.output_tokens+' out tokens · '+t.images+' images · '+t.auto_requests+' via auto · spend '+money(t.spend_usd)],
  ['monthly backstop',money(u.month_spent_usd)+' of '+money(u.month_cap_usd)+(u.override_monthly_cap_usd!==null?' (custom)':'')],
  ['app view',Math.round(u.app_view.remaining_fraction*100)+'% left'+(u.app_view.pools[0]&&u.app_view.pools[0].slow_mode?' · slow':'')+' · auto '+(u.plan.auto_oss||(u.override_pools||{}).auto_oss?'uses auto-oss members (hidden)':'plain')],
  ['keys',u.keys.map(k=>k.platform+': spend '+money(k.spend_usd)+' / '+(k.max_budget_usd??'?')+' per '+(k.budget_duration||'?')+' · rpm '+(k.rpm_limit??'?')+(k.blocked?' BLOCKED':'')).join(' · ')||'none']];
 for(const [k,v] of rows){kv.appendChild(el('div',{},k));kv.appendChild(el('div',{},v==null?'—':String(v)))}
 const tb=$('modelRows');tb.textContent='';
 for(const m of u.app_view.models){const tr=el('tr');const bm=t.by_model[m.id]||{};
  cell(tr,m.name+(m.auto?' (auto: '+(m.members||[]).join(', ')+')':''));cell(tr,m.kind+(m.slow_mode?' (slow)':''));
  cell(tr,!m.priced?'unpriced':(m.kind==='image'?m.remaining_images+' images':m.remaining_messages+' messages'),'num');
  cell(tr,m.estimate);cell(tr,bm.requests||0,'num');cell(tr,(bm.input_tokens||0)+' / '+(bm.output_tokens||0),'num');cell(tr,bm.images||0,'num');tb.appendChild(tr)}
 $('u_tier').value=u.plan.id;$('u_daily').value=u.override_daily_usd??'';$('u_cap').value=u.override_monthly_cap_usd??'';
 for(const f of PFIELDS)$('u_p_'+f).value=(u.override_pools||{})[f]??'';
 for(const f of PBOOLS){const v=(u.override_pools||{})[f];$('u_p_'+f).value=v===undefined||v===null?'':String(v)}
 $('userBox').style.display='block';
}
async function userCall(b){try{show('userActOut',await api('POST','/admin/user/update',b));await lookup();loadAudit()}catch(e){show('userActOut',String(e),true)}}
function saveUser(){
 if(!current)return;const b={uid:current.uid,tier:$('u_tier').value};
 const d=num($('u_daily').value),c=num($('u_cap').value);if(d!==null)b.daily_usd=d;if(c!==null)b.monthly_cap_usd=c;
 const p={};for(const f of PFIELDS){const v=num($('u_p_'+f).value);if(v!==null)p[f]=v}
 for(const f of PBOOLS){const v=$('u_p_'+f).value;if(v!=='')p[f]=v==='true'}if(Object.keys(p).length)b.pools=p;
 userCall(b)
}
function clearUser(flag){if(current)userCall({uid:current.uid,[flag]:true})}
async function resetUser(){if(!current||!confirm('Restart the window now for '+current.uid+'?'))return;
 try{show('userActOut',await api('POST','/admin/reset-window',{uid:current.uid,reset_month_free:$('u_month').checked}));await lookup();loadAudit()}catch(e){show('userActOut',String(e),true)}}
async function banUser(on){if(!current)return;
 try{show('userActOut',await api('POST',on?'/admin/ban':'/admin/unban',{uid:current.uid}));await lookup();loadAudit()}catch(e){show('userActOut',String(e),true)}}
async function resetAll(){if(!confirm('Restart the window now for ALL users?'))return;
 try{show('resetStatus',await api('POST','/admin/reset-window',{all:true,reset_month_free:$('all_month').checked}));loadAudit();pollReset()}catch(e){show('resetStatus',String(e),true)}}
async function pollReset(){
 try{const s=await api('GET','/admin/reset-status');if(s.state==='never')return;
  show('resetStatus','Last global reset: '+s.state+' · '+s.done+'/'+s.total+' users'+(s.errors?' · '+s.errors+' errors':'')+' · '+(s.at||''));
  if(s.state==='running')setTimeout(pollReset,2000)}catch(e){}
}
async function ipBan(on){const ip=$('banIp').value.trim();if(!ip)return;
 try{show('miscOut',await api('POST',on?'/admin/ban':'/admin/unban',{ip}));loadAudit()}catch(e){show('miscOut',String(e),true)}}
async function loadAudit(){
 try{const j=await api('GET','/admin/audit?limit=200');const tb=$('auditRows');tb.textContent='';
  for(const e of j.entries){const tr=el('tr');cell(tr,e.ts);cell(tr,e.action);cell(tr,typeof e.target==='string'?e.target:JSON.stringify(e.target));
   cell(tr,JSON.stringify({before:e.before,after:e.after}));tb.appendChild(tr)}
 }catch(e){}
}
</script></body></html>`;
