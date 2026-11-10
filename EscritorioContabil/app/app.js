/* Mesa de Tarefas - app do escritório (Supabase + RLS)
 * Toda regra de negócio e de segurança está no banco (triggers + RLS).
 * Este arquivo só mostra os dados e chama as funções do banco.
 */
(() => {
"use strict";

const sb = window.supabase.createClient(APP_CONFIG.supabaseUrl, APP_CONFIG.supabaseKey, {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true },
});
const db = sb.schema("escritorio");

// ------------------------------------------------------------------ estado
let me = null;              // linha de escritorio.usuarios do usuário logado
let D = { tarefas: [], pend: [], usuarios: [], clientes: [], resumo: [], hist: [], garg: [] };
let tab = "minhas";         // gestor: painel | todas | nova | cadastros | minhas
let openDep = null, openConc = null, authMode = "login", timer = null;

// ------------------------------------------------------------------ util
const $ = s => document.querySelector(s);
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const fDate = iso => { if (!iso) return ""; const [y, m, d] = iso.slice(0, 10).split("-"); return `${d}/${m}/${y}`; };
const fDT = ts => ts ? new Date(ts).toLocaleString("pt-BR", { day: "2-digit", month: "2-digit", year: "2-digit", hour: "2-digit", minute: "2-digit" }) : "";
const STATUS = { a_fazer: "A fazer", em_andamento: "Em andamento", aguardando: "Aguardando", em_revisao: "Em revisão", concluida: "Concluída", cancelada: "Cancelada" };
const AREA = { contabil: "Contábil", fiscal: "Fiscal", departamento_pessoal: "Depto. Pessoal", societario: "Societário", financeiro: "Financeiro", administrativo: "Administrativo" };
const MOD = { presencial: "Presencial", home_office: "Home office", hibrido: "Híbrido" };
const PRIO = { baixa: "baixa", media: "média", alta: "alta", urgente: "urgente" };
const TIPO = { tarefa: "Outra tarefa", pessoa: "Colega", cliente: "Cliente", externo: "Externo" };
const SIT = {
  "Liberada para iniciar": ["--ok", "--ok-bg"], "Em andamento": ["--info", "--info-bg"], "Bloqueada": ["--bad", "--bad-bg"],
  "Em revisão": ["--review", "--review-bg"], "Concluída": ["--idle", "--idle-bg"], "Cancelada": ["--idle", "--idle-bg"],
};
const pill = (txt, key = txt) => { const [fg, bg] = SIT[key] || SIT["Concluída"]; return `<span class="pill" style="--pfg:var(${fg});--pbg:var(${bg})">${esc(txt)}</span>`; };
const aberta = t => !["concluida", "cancelada"].includes(t.status);
const nomeU = id => (D.usuarios.find(u => u.id === id) || {}).nome || "";
function prazoTxt(t) {
  if (!t.prazo) return "";
  if (!aberta(t)) return `<span class="prazo">prazo ${fDate(t.prazo)}</span>`;
  const d = t.dias_para_prazo;
  if (d < 0) return `<span class="prazo late">atrasada ${-d} dia${d === -1 ? "" : "s"}</span>`;
  if (d === 0) return `<span class="prazo soon">vence hoje</span>`;
  return `<span class="prazo${d <= 2 ? " soon" : ""}">vence ${fDate(t.prazo)} (${d}d)</span>`;
}
const ordem = (a, b) => (a.situacao === "Bloqueada") - (b.situacao === "Bloqueada") || (b.atrasada ? 1 : 0) - (a.atrasada ? 1 : 0)
  || a.ordem_prioridade - b.ordem_prioridade || String(a.prazo || "9").localeCompare(String(b.prazo || "9"));

let tt;
function toast(msg) { const el = $("#toast"); el.textContent = msg; el.hidden = false; clearTimeout(tt); tt = setTimeout(() => (el.hidden = true), 4000); }
function errMsg(e) {
  const m = (e && (e.message || e.error_description)) || String(e);
  if (/Invalid login credentials/i.test(m)) return "E-mail ou senha incorretos.";
  if (/Email not confirmed/i.test(m)) return "Confirme seu e-mail: abra o link que enviamos e depois entre de novo.";
  if (/não autorizado|Database error saving new user/i.test(m)) return "Este e-mail não está cadastrado. Peça ao gestor para cadastrar você.";
  if (/already registered/i.test(m)) return "Este e-mail já tem senha. Use \"Entrar\" ou \"Esqueci minha senha\".";
  if (/rate limit/i.test(m)) return "Muitas tentativas. Aguarde alguns minutos e tente de novo.";
  return m;
}

// ------------------------------------------------------------------ autenticação
function setAuthMode(m) {
  authMode = m;
  $("#auth-title").textContent = { login: "Entrar", signup: "Primeiro acesso", reset: "Recuperar senha" }[m];
  $("#auth-sub").textContent = {
    login: "Use o e-mail cadastrado pelo gestor do escritório.",
    signup: "Crie sua senha. Só funciona para e-mails já cadastrados pelo gestor. Você vai receber um e-mail de confirmação.",
    reset: "Enviaremos um link para você definir uma nova senha.",
  }[m];
  $("#pw-wrap").hidden = m === "reset";
  $("#auth-pw").required = m !== "reset";
  $("#auth-pw").autocomplete = m === "signup" ? "new-password" : "current-password";
  $("#auth-submit").textContent = { login: "Entrar", signup: "Criar senha", reset: "Enviar link" }[m];
  $("#mode-signup").hidden = m !== "login"; $("#mode-reset").hidden = m !== "login"; $("#mode-login").hidden = m === "login";
  const msg = $("#auth-msg"); msg.textContent = ""; msg.className = "msg";
}
$("#mode-signup").onclick = () => setAuthMode("signup");
$("#mode-reset").onclick = () => setAuthMode("reset");
$("#mode-login").onclick = () => setAuthMode("login");

$("#auth-form").addEventListener("submit", async e => {
  e.preventDefault();
  const email = $("#auth-email").value.trim().toLowerCase(), pw = $("#auth-pw").value;
  const msg = $("#auth-msg"); msg.className = "msg"; msg.textContent = "Aguarde…";
  try {
    if (authMode === "login") {
      const { error } = await sb.auth.signInWithPassword({ email, password: pw }); if (error) throw error;
      msg.textContent = "";
    } else if (authMode === "signup") {
      if (pw.length < 8) throw new Error("A senha precisa ter pelo menos 8 caracteres.");
      const { data, error } = await sb.auth.signUp({ email, password: pw, options: { emailRedirectTo: location.origin } });
      if (error) throw error;
      if (data.session) { msg.textContent = ""; return; }
      msg.className = "msg ok"; msg.textContent = "Pronto. Abra o e-mail de confirmação que enviamos e depois entre com sua senha.";
    } else {
      const { error } = await sb.auth.resetPasswordForEmail(email, { redirectTo: location.origin }); if (error) throw error;
      msg.className = "msg ok"; msg.textContent = "Se o e-mail estiver cadastrado, você vai receber o link em instantes.";
    }
  } catch (err) { msg.className = "msg err"; msg.textContent = errMsg(err); }
});

$("#newpw-form").addEventListener("submit", async e => {
  e.preventDefault();
  const msg = $("#newpw-msg");
  const { error } = await sb.auth.updateUser({ password: $("#newpw-input").value });
  if (error) { msg.className = "msg err"; msg.textContent = errMsg(error); return; }
  msg.className = "msg ok"; msg.textContent = "Senha alterada.";
  setTimeout(() => boot(), 800);
});
$("#btn-logout").onclick = async () => { await sb.auth.signOut(); location.hash = ""; };
$("#btn-refresh").onclick = () => load().then(render);

let recovering = false;
let currentUid; // undefined até o primeiro evento (INITIAL_SESSION)
sb.auth.onAuthStateChange((ev, session) => {
  if (ev === "PASSWORD_RECOVERY") { recovering = true; show("newpw"); return; }
  if (recovering) return;
  const uid = session ? session.user.id : null;
  // o Supabase repete SIGNED_IN (ex.: ao voltar para a aba); só recarrega se o usuário mudou
  if (uid !== currentUid) { currentUid = uid; setTimeout(boot, 0); }
});

function show(which) {
  $("#login").hidden = which !== "login"; $("#newpw").hidden = which !== "newpw";
  $("#app").hidden = which !== "app"; $("#session").hidden = which !== "app";
}

async function boot() {
  const { data: { session } } = await sb.auth.getSession();
  clearInterval(timer);
  if (!session) { me = null; setAuthMode("login"); show("login"); return; }
  const { data, error } = await db.from("usuarios").select("*").eq("auth_user_id", session.user.id).maybeSingle();
  if (error || !data || !data.ativo) {
    show("app");
    $("#app").innerHTML = `<div class="empty">Seu login (${esc(session.user.email)}) ainda não está ligado a um cadastro ativo do escritório. Fale com o gestor.</div>`;
    return;
  }
  me = data;
  $("#who-top").textContent = `${me.nome} · ${MOD[me.modalidade]}`;
  tab = me.perfil === "gestor" ? (tab === "minhas" ? "painel" : tab) : "minhas";
  show("app");
  $("#app").innerHTML = `<p class="loading">Carregando…</p>`;
  await load(); render();
  timer = setInterval(() => { if (!openDep && !openConc && !document.querySelector("#app form:focus-within")) load().then(render); }, 60000);
}

// ------------------------------------------------------------------ dados
async function q(p) { const { data, error } = await p; if (error) throw error; return data || []; }
async function load() {
  try {
    const gest = me.perfil === "gestor";
    const [tarefas, pend, usuarios, clientes, resumo, hist, garg] = await Promise.all([
      q(db.from("vw_tarefas").select("*")),
      q(db.from("vw_pendencias_abertas").select("*")),
      q(db.from("usuarios").select("id,nome,email,cargo,area,perfil,modalidade,ativo,auth_user_id").order("nome")),
      q(db.from("clientes").select("*").order("codigo")),
      gest ? q(db.from("vw_gestor_resumo_usuario").select("*")) : [],
      gest ? q(db.from("vw_gestor_linha_tempo").select("*").order("ocorrido_em", { ascending: false }).limit(60)) : [],
      gest ? q(db.from("vw_gestor_gargalos").select("*")) : [],
    ]);
    D = { tarefas, pend, usuarios, clientes, resumo, hist, garg };
  } catch (e) { toast("Erro ao carregar: " + errMsg(e)); }
}
async function rpc(fn, args, okMsg) {
  const { error } = await db.rpc(fn, args);
  if (error) { toast(errMsg(error)); return false; }
  if (okMsg) toast(okMsg);
  await load(); render(); return true;
}

// ------------------------------------------------------------------ render
function render() {
  if (!me) return;
  const gest = me.perfil === "gestor";
  let h = `<div class="who"><h2>${esc(me.nome)}</h2><span class="muted">${esc(me.cargo || "")} · ${MOD[me.modalidade]}${gest ? " · gestor" : ""}</span></div>`;
  if (gest) {
    const tabs = [["painel", "Painel do gestor"], ["todas", "Todas as tarefas"], ["nova", "Nova tarefa"], ["cadastros", "Equipe e clientes"], ["minhas", "Minhas tarefas"]];
    h += `<div class="tabs" role="tablist">${tabs.map(([k, l]) => `<button class="tab" role="tab" type="button" data-tab="${k}" aria-selected="${tab === k}">${l}</button>`).join("")}</div>`;
  }
  const v = { painel: viewPainel, todas: viewTodas, nova: viewNova, cadastros: viewCadastros, minhas: viewMinhas }[tab]();
  $("#app").innerHTML = `<div style="display:flex;flex-direction:column;gap:22px">${h}${v}</div>`;
}

const kpi = (v, l, cls = "") => `<div class="kpi ${cls}"><div class="v">${v}</div><div class="k">${l}</div></div>`;

function taskCard(t) {
  const pode = t.responsavel_id === me.id || me.perfil === "gestor";
  const deps = D.pend.filter(p => p.tarefa_id === t.tarefa_id);
  let h = `<article class="task" style="--st:var(${(SIT[t.situacao] || SIT["Concluída"])[0]})">
    <div class="task-top"><div class="task-title"><span class="small muted mono">#${t.tarefa_id}</span><h3>${esc(t.titulo)}</h3>
      <span class="task-meta">${esc(t.cliente_codigo || "")} ${esc(t.cliente)} · ${AREA[t.area]}${t.competencia_txt ? ` · competência <span class="mono">${t.competencia_txt}</span>` : ""}${t.responsavel_id !== me.id ? " · resp. " + esc(t.responsavel) : ""}</span>
      ${t.descricao ? `<span class="small">${esc(t.descricao)}</span>` : ""}</div>
    <div class="task-right">${prazoTxt(t)} ${pill(t.situacao)} <span class="small muted">prioridade ${PRIO[t.prioridade]}</span></div></div>`;
  if (deps.length) {
    h += `<div class="deps"><span class="small muted">Aguardando:</span>` + deps.map(d => {
      const pessoa = d.bloqueador_usuario_id === me.id;
      const acoes = d.tipo === "tarefa" ? `<span class="small muted">libera sozinha quando essa tarefa for concluída</span>`
        : (pode || pessoa) ? `<button class="btn" data-act="cobrar" data-id="${d.dependencia_id}" type="button">Cobrar</button>
           <button class="btn" data-act="resolver" data-id="${d.dependencia_id}" type="button">Marcar como resolvida</button>` : "";
      const contato = d.tipo === "cliente" && (d.cliente_contato || d.cliente_contato_telefone)
        ? ` · contato: <span class="mono">${esc([d.cliente_contato, d.cliente_contato_telefone, d.cliente_contato_email].filter(Boolean).join(" · "))}</span>` : "";
      return `<div class="dep"><span class="t">${TIPO[d.tipo]}</span><span class="txt"><b>${esc(d.bloqueado_por)}</b>: ${esc(d.o_que_falta)}
        <span class="small muted"> · há ${d.dias_pendente} dia(s)${d.ultima_cobranca ? " · cobrado " + fDT(d.ultima_cobranca) : ""}${contato}</span></span>${acoes}</div>`;
    }).join("") + `</div>`;
  }
  if (pode && aberta(t)) {
    const b = [];
    if (t.status === "a_fazer") b.push(`<button class="btn primary" data-act="iniciar" data-id="${t.tarefa_id}" type="button">Iniciar</button>`);
    if (t.status === "em_andamento") b.push(`<button class="btn" data-act="revisao" data-id="${t.tarefa_id}" type="button">Enviar para revisão</button>`);
    if (["em_andamento", "em_revisao"].includes(t.status)) b.push(`<button class="btn primary" data-act="concluir" data-id="${t.tarefa_id}" type="button">Concluir</button>`);
    if (t.status === "aguardando") b.push(`<button class="btn" disabled type="button">Concluir</button><span class="why">Resolva as pendências antes de concluir</span>`);
    b.push(`<button class="btn link" data-act="dep" data-id="${t.tarefa_id}" type="button">${openDep === t.tarefa_id ? "Fechar" : "+ Registrar pendência"}</button>`);
    h += `<div class="actions">${b.join("")}</div>`;
    if (openConc === t.tarefa_id) h += `<form class="form" data-conc="${t.tarefa_id}">
      <label style="grid-column:1/-1">Onde está o arquivo entregue? (opcional)
        <input id="conc-path-${t.tarefa_id}" placeholder="01_CLIENTES/C0001_.../03_FISCAL/2026/2026-10/04_GUIAS/..."></label>
      <div class="full"><button class="btn primary" type="submit">Confirmar conclusão</button>
      <button class="btn" type="button" data-act="cancel-conc">Cancelar</button></div></form>`;
    if (openDep === t.tarefa_id) h += depForm(t);
  } else if (t.status === "concluida") {
    h += `<div class="small muted">Concluída por <b>${esc(t.concluido_por)}</b> em <span class="mono">${fDT(t.concluido_em)}</span>${t.concluida_no_prazo === false ? " · com atraso" : t.concluida_no_prazo ? " · no prazo" : ""}${t.caminho_arquivos ? ` · arquivo: <span class="mono">${esc(t.caminho_arquivos)}</span>` : ""}</div>`;
  }
  return h + `</article>`;
}

function refOptions(tipo, t) {
  if (tipo === "cliente") return D.clientes.map(c => `<option value="${c.id}"${c.id === t.cliente_id ? " selected" : ""}>${esc(c.razao_social)}</option>`).join("");
  if (tipo === "pessoa") return D.usuarios.filter(u => u.id !== t.responsavel_id && u.ativo).map(u => `<option value="${u.id}">${esc(u.nome)}</option>`).join("");
  if (tipo === "tarefa") return D.tarefas.filter(o => o.tarefa_id !== t.tarefa_id && aberta(o)).map(o => `<option value="${o.tarefa_id}">#${o.tarefa_id} ${esc(o.titulo)} (${esc(o.responsavel)})</option>`).join("");
  return `<option value="">—</option>`;
}
function depForm(t) {
  return `<form class="form" data-depform="${t.tarefa_id}">
    <label>Depende de <select id="dep-tipo-${t.tarefa_id}" data-tipo>
      <option value="cliente">Cliente</option><option value="pessoa">Colega</option>
      <option value="tarefa">Outra tarefa</option><option value="externo">Externo (órgão, banco…)</option></select></label>
    <label>Quem / qual <select id="dep-ref-${t.tarefa_id}" data-ref>${refOptions("cliente", t)}</select></label>
    <label style="grid-column:1/-1">O que falta <input id="dep-desc-${t.tarefa_id}" data-desc maxlength="300" required placeholder="Ex.: enviar extrato bancário de outubro"></label>
    <div class="full"><button class="btn primary" type="submit">Registrar pendência</button>
    <span class="small muted">Não escreva senhas, CPF ou salários aqui.</span></div></form>`;
}

function tabelaConcluidas(lista, comResp) {
  if (!lista.length) return '<div class="empty">Nada concluído ainda.</div>';
  return `<div class="tbl"><table><thead><tr><th>Tarefa</th><th>Cliente</th>${comResp ? "<th>Concluída por</th>" : ""}<th>Data e hora</th><th>Prazo</th><th></th><th>Execução</th></tr></thead><tbody>` +
    lista.sort((a, b) => String(b.concluido_em).localeCompare(String(a.concluido_em))).map(t => {
      const h = t.iniciado_em ? (new Date(t.concluido_em) - new Date(t.iniciado_em)) / 3600000 : null;
      return `<tr><td>#${t.tarefa_id} ${esc(t.titulo)}</td><td>${esc(t.cliente)}</td>${comResp ? `<td>${esc(t.concluido_por)}</td>` : ""}
        <td class="mono">${fDT(t.concluido_em)}</td><td class="mono">${fDate(t.prazo)}</td>
        <td>${t.concluida_no_prazo === false ? pill("Atrasou", "Bloqueada") : t.concluida_no_prazo ? pill("No prazo", "Liberada para iniciar") : ""}</td>
        <td class="n">${h == null ? "" : h < 1 ? Math.round(h * 60) + " min" : h.toFixed(1).replace(".", ",") + " h"}</td></tr>`;
    }).join("") + `</tbody></table></div>`;
}

function viewMinhas() {
  const minhas = D.tarefas.filter(t => t.responsavel_id === me.id && aberta(t)).sort(ordem);
  const esperam = D.pend.filter(p => p.bloqueador_usuario_id === me.id && p.responsavel_id !== me.id);
  const feitas = D.tarefas.filter(t => t.responsavel_id === me.id && t.status === "concluida");
  const livres = minhas.filter(t => t.situacao !== "Bloqueada").length;
  return `<div class="kpis">${kpi(livres, "posso fazer agora", livres ? "ok" : "")}${kpi(minhas.filter(t => t.situacao === "Bloqueada").length, "bloqueadas")}
    ${kpi(minhas.filter(t => t.atrasada).length, "atrasadas", minhas.some(t => t.atrasada) ? "bad" : "")}${kpi(esperam.length, "colegas esperando por mim", esperam.length ? "warn" : "")}</div>
  <section><div class="sec-head"><h2>Minhas tarefas</h2><span class="small muted">ordem: o que dá para fazer agora, atrasadas, prioridade, prazo</span></div>
    <div class="list">${minhas.map(taskCard).join("") || '<div class="empty">Nenhuma tarefa em aberto.</div>'}</div></section>
  <section><div class="sec-head"><h2>Quem está esperando por mim</h2></div>
    ${esperam.length ? `<div class="tbl"><table><thead><tr><th>Colega</th><th>Tarefa</th><th>O que precisa de mim</th><th>Desde</th><th></th></tr></thead><tbody>` +
      esperam.map(d => `<tr><td>${esc(d.responsavel)}</td><td>#${d.tarefa_id} ${esc(d.tarefa)}<br><span class="small muted">${esc(d.cliente_da_tarefa || "")}</span></td>
        <td class="wrapc">${esc(d.o_que_falta)}${d.tipo === "tarefa" ? `<br><span class="small muted">${esc(d.bloqueado_por)}</span>` : ""}</td><td class="mono">${fDT(d.pendente_desde)}</td>
        <td>${d.tipo === "pessoa" ? `<button class="btn" data-act="resolver" data-id="${d.dependencia_id}" type="button">Feito</button>` : ""}</td></tr>`).join("") + `</tbody></table></div>`
      : '<div class="empty">Ninguém está esperando por você agora.</div>'}</section>
  <section><div class="sec-head"><h2>Concluídas por mim</h2></div>${tabelaConcluidas(feitas, false)}</section>`;
}

function viewPainel() {
  const ab = D.tarefas.filter(aberta), conc = D.tarefas.filter(t => t.status === "concluida");
  const comPrazo = conc.filter(t => t.concluida_no_prazo !== null);
  const pct = comPrazo.length ? Math.round(100 * comPrazo.filter(t => t.concluida_no_prazo).length / comPrazo.length) + "%" : "—";
  const mes = new Date().toISOString().slice(0, 7);
  return `<div class="kpis">${kpi(ab.length, "tarefas em aberto")}${kpi(ab.filter(t => t.situacao === "Bloqueada").length, "bloqueadas", "warn")}
    ${kpi(ab.filter(t => t.atrasada).length, "atrasadas", ab.some(t => t.atrasada) ? "bad" : "")}${kpi(conc.filter(t => String(t.concluido_em).slice(0, 7) === mes).length, "concluídas no mês", "ok")}${kpi(pct, "concluídas no prazo")}</div>
  <section><div class="sec-head"><h2>Por colaborador</h2></div><div class="tbl"><table><thead><tr><th>Colaborador</th><th>Modalidade</th><th>Em aberto</th><th>Bloqueadas</th><th>Atrasadas</th><th>Concluídas no mês</th><th>% no prazo</th><th>Colegas esperando</th><th>Última atividade</th></tr></thead><tbody>` +
    D.resumo.map(r => `<tr><td>${esc(r.nome)}</td><td>${MOD[r.modalidade]}</td><td class="n">${r.em_aberto}</td><td class="n">${r.bloqueadas}</td><td class="n">${r.atrasadas}</td>
      <td class="n">${r.concluidas_mes}</td><td class="n">${r.pct_no_prazo_geral == null ? "—" : r.pct_no_prazo_geral + "%"}</td><td class="n">${r.colegas_aguardando_ele}</td><td class="mono">${fDT(r.ultima_atividade) || "—"}</td></tr>`).join("") +
    `</tbody></table></div></section>
  <section><div class="sec-head"><h2>Tarefas concluídas</h2><span class="small muted">quem concluiu, quando e se foi no prazo</span></div>${tabelaConcluidas(conc, true)}</section>
  <section><div class="sec-head"><h2>Gargalos</h2></div><div class="tbl"><table><thead><tr><th>Tipo</th><th>Travado por</th><th>Tarefas</th><th>Maior espera</th></tr></thead><tbody>` +
    (D.garg.map(g => `<tr><td>${esc(g.tipo_descricao)}</td><td>${esc(g.bloqueador)}</td><td class="n">${g.tarefas_travadas}</td><td class="n">${g.maior_espera_dias} dia(s)</td></tr>`).join("") || '<tr><td colspan="4" class="muted">Nada travado.</td></tr>') +
    `</tbody></table></div></section>
  <section><div class="sec-head"><h2>Histórico</h2><span class="small muted">últimos 60 eventos</span></div><div class="tbl"><table><thead><tr><th>Quando</th><th>Quem</th><th>Tarefa</th><th>O que aconteceu</th></tr></thead><tbody>` +
    (D.hist.map(h => `<tr><td class="mono">${fDT(h.ocorrido_em)}</td><td>${esc(h.usuario)}</td><td>#${h.tarefa_id} ${esc(h.titulo)}</td>
      <td class="ev">${h.evento === "status" ? `${STATUS[h.status_anterior] || ""} → <b>${STATUS[h.status_novo]}</b>` : esc(h.evento.replace(/_/g, " ")) + (h.detalhe ? ": " + esc(h.detalhe) : "")}</td></tr>`).join("") || '<tr><td colspan="4" class="muted">Sem eventos.</td></tr>') +
    `</tbody></table></div></section>`;
}

function viewTodas() {
  const ab = D.tarefas.filter(aberta).sort(ordem);
  return `<section><div class="sec-head"><h2>Tarefas em aberto</h2><span class="small muted">${ab.length} tarefa(s)</span></div>
    <div class="list">${ab.map(taskCard).join("") || '<div class="empty">Nenhuma tarefa em aberto. Crie uma em "Nova tarefa".</div>'}</div></section>`;
}

function viewNova() {
  const ativos = D.usuarios.filter(u => u.ativo);
  const opt = (arr, sel) => arr.map(([v, l]) => `<option value="${esc(v)}"${v === sel ? " selected" : ""}>${esc(l)}</option>`).join("");
  const mesAnt = (() => { const d = new Date(); d.setDate(1); d.setMonth(d.getMonth() - 1); return d.toISOString().slice(0, 7); })();
  if (!D.clientes.length) return `<div class="empty">Cadastre primeiro um cliente em "Equipe e clientes".</div>`;
  return `<form class="grid-form" id="form-tarefa">
    <label class="wide">Título <input id="nt-titulo" required maxlength="200" placeholder="Ex.: Apuração do Simples Nacional (DAS)"></label>
    <label>Cliente <select id="nt-cliente">${opt(D.clientes.map(c => [String(c.id), c.codigo + " · " + c.razao_social]))}</select></label>
    <label>Área <select id="nt-area">${opt(Object.entries(AREA))}</select></label>
    <label>Competência <input id="nt-comp" type="month" value="${mesAnt}"></label>
    <label>Responsável <select id="nt-resp">${opt(ativos.map(u => [String(u.id), u.nome]))}</select></label>
    <label>Revisor (opcional) <select id="nt-rev"><option value="">—</option>${opt(ativos.map(u => [String(u.id), u.nome]))}</select></label>
    <label>Prioridade <select id="nt-prio">${opt([["baixa", "Baixa"], ["media", "Média"], ["alta", "Alta"], ["urgente", "Urgente"]], "media")}</select></label>
    <label>Prazo <input id="nt-prazo" type="date" required></label>
    <label class="wide">Descrição (opcional) <textarea id="nt-desc" maxlength="2000"></textarea></label>
    <div class="full"><button class="btn primary" type="submit">Criar tarefa</button></div></form>`;
}

function viewCadastros() {
  const opt = arr => arr.map(([v, l]) => `<option value="${esc(v)}">${esc(l)}</option>`).join("");
  return `<section><div class="sec-head"><h2>Equipe</h2><span class="small muted">depois de cadastrar, a pessoa entra no app e clica em "Primeiro acesso"</span></div>
    <div class="tbl"><table><thead><tr><th>Nome</th><th>E-mail</th><th>Cargo</th><th>Perfil</th><th>Modalidade</th><th>Login</th><th></th></tr></thead><tbody>` +
    D.usuarios.map(u => `<tr><td>${esc(u.nome)}</td><td class="mono small">${esc(u.email)}</td><td>${esc(u.cargo || "")}</td><td>${u.perfil}</td><td>${MOD[u.modalidade]}</td>
      <td>${u.auth_user_id ? pill("Ativo", "Liberada para iniciar") : pill("Aguardando 1º acesso", "Em revisão")}</td>
      <td>${u.id !== me.id ? `<button class="btn" data-act="ativo" data-id="${u.id}" data-v="${!u.ativo}" type="button">${u.ativo ? "Desativar acesso" : "Reativar"}</button>` : ""}</td></tr>`).join("") +
    `</tbody></table></div>
    <form class="grid-form" id="form-usuario">
      <label>Nome <input id="nu-nome" required maxlength="120"></label>
      <label>E-mail <input id="nu-email" type="email" required maxlength="160"></label>
      <label>Cargo <input id="nu-cargo" maxlength="80"></label>
      <label>Área <select id="nu-area">${opt(Object.entries(AREA))}</select></label>
      <label>Perfil <select id="nu-perfil">${opt([["colaborador", "Colaborador"], ["gestor", "Gestor"]])}</select></label>
      <label>Modalidade <select id="nu-mod">${opt(Object.entries(MOD))}</select></label>
      <div class="full"><button class="btn primary" type="submit">Cadastrar pessoa</button></div></form></section>
  <section><div class="sec-head"><h2>Clientes</h2></div>
    <div class="tbl"><table><thead><tr><th>Código</th><th>Razão social</th><th>CNPJ/CPF</th><th>Regime</th><th>Contato</th><th>Pasta</th></tr></thead><tbody>` +
    (D.clientes.map(c => `<tr><td class="mono">${esc(c.codigo)}</td><td>${esc(c.razao_social)}</td><td class="mono">${esc(c.cnpj_cpf)}</td><td>${esc(c.regime_tributario || "")}</td>
      <td>${esc([c.contato_nome, c.contato_telefone, c.contato_email].filter(Boolean).join(" · "))}</td><td class="mono small">${esc(c.pasta_arquivos || "")}</td></tr>`).join("") || '<tr><td colspan="6" class="muted">Nenhum cliente.</td></tr>') +
    `</tbody></table></div>
    <form class="grid-form" id="form-cliente">
      <label>Código <input id="nc-cod" required maxlength="10" placeholder="C0001"></label>
      <label class="wide">Razão social <input id="nc-razao" required maxlength="200"></label>
      <label>CNPJ/CPF <input id="nc-cnpj" required maxlength="18"></label>
      <label>Regime <select id="nc-regime">${opt([["Simples Nacional", "Simples Nacional"], ["Lucro Presumido", "Lucro Presumido"], ["Lucro Real", "Lucro Real"], ["MEI", "MEI"], ["Pessoa Física", "Pessoa Física"]])}</select></label>
      <label>Responsável <select id="nc-resp">${opt(D.usuarios.filter(u => u.ativo).map(u => [String(u.id), u.nome]))}</select></label>
      <label>Contato (nome) <input id="nc-cnome" maxlength="120"></label>
      <label>Contato (telefone) <input id="nc-ctel" maxlength="20"></label>
      <label>Contato (e-mail) <input id="nc-cemail" type="email" maxlength="160"></label>
      <label class="wide">Pasta dos arquivos <input id="nc-pasta" maxlength="300" placeholder="01_CLIENTES/C0001_RAZAO_SOCIAL"></label>
      <div class="full"><button class="btn primary" type="submit">Cadastrar cliente</button></div></form></section>`;
}

// ------------------------------------------------------------------ eventos do app
$("#app").addEventListener("click", async e => {
  const tb = e.target.closest("[data-tab]");
  if (tb) { tab = tb.dataset.tab; openDep = openConc = null; render(); return; }
  const a = e.target.closest("[data-act]"); if (!a) return;
  const id = +a.dataset.id;
  switch (a.dataset.act) {
    case "iniciar": return rpc("fn_alterar_status", { p_tarefa_id: id, p_usuario_id: me.id, p_status: "em_andamento" }, `Tarefa #${id} iniciada.`);
    case "revisao": return rpc("fn_alterar_status", { p_tarefa_id: id, p_usuario_id: me.id, p_status: "em_revisao" }, `Tarefa #${id} enviada para revisão.`);
    case "concluir": openConc = id; openDep = null; return render();
    case "cancel-conc": openConc = null; return render();
    case "dep": openDep = openDep === id ? null : id; openConc = null; return render();
    case "cobrar": return rpc("fn_registrar_cobranca", { p_dependencia_id: id, p_usuario_id: me.id }, "Cobrança registrada no histórico.");
    case "resolver": return rpc("fn_resolver_dependencia", { p_dependencia_id: id, p_usuario_id: me.id }, "Pendência resolvida.");
    case "ativo": {
      const { error } = await db.from("usuarios").update({ ativo: a.dataset.v === "true" }).eq("id", id);
      if (error) return toast(errMsg(error));
      toast(a.dataset.v === "true" ? "Acesso reativado." : "Acesso desativado. A pessoa não vê mais nenhum dado.");
      await load(); return render();
    }
  }
});
$("#app").addEventListener("change", e => {
  if (!e.target.matches("[data-tipo]")) return;
  const f = e.target.closest("form"); const t = D.tarefas.find(x => x.tarefa_id === +f.dataset.depform);
  const ref = f.querySelector("[data-ref]"); ref.innerHTML = refOptions(e.target.value, t); ref.disabled = e.target.value === "externo";
});
$("#app").addEventListener("submit", async e => {
  e.preventDefault();
  const f = e.target;
  const btn = f.querySelector('button[type="submit"]'); if (btn) btn.disabled = true;
  try {
    if (f.dataset.conc) {
      const id = +f.dataset.conc; const path = f.querySelector("input").value.trim() || null;
      const ok = await rpc("fn_concluir_tarefa", { p_tarefa_id: id, p_usuario_id: me.id, p_caminho_arquivos: path }, `Tarefa #${id} concluída.`);
      if (ok) { openConc = null; render(); }
    } else if (f.dataset.depform) {
      const tid = +f.dataset.depform, tipo = f.querySelector("[data-tipo]").value;
      const ref = tipo === "externo" ? null : +f.querySelector("[data-ref]").value;
      const desc = f.querySelector("[data-desc]").value.trim();
      if (!desc) return toast("Descreva o que está faltando.");
      const ok = await rpc("fn_adicionar_dependencia", { p_tarefa_id: tid, p_usuario_id: me.id, p_tipo: tipo, p_referencia_id: ref, p_descricao: desc }, `Pendência registrada. Tarefa #${tid} está aguardando.`);
      if (ok) { openDep = null; render(); }
    } else if (f.id === "form-tarefa") {
      const v = id => $(id).value;
      const comp = v("#nt-comp");
      const { error } = await db.from("tarefas").insert({
        titulo: v("#nt-titulo").trim(), cliente_id: +v("#nt-cliente"), area: v("#nt-area"),
        competencia: comp ? comp + "-01" : null, responsavel_id: +v("#nt-resp"), revisor_id: v("#nt-rev") ? +v("#nt-rev") : null,
        criado_por: me.id, prioridade: v("#nt-prio"), prazo: v("#nt-prazo"), descricao: v("#nt-desc").trim() || null,
      });
      if (error) return toast(errMsg(error));
      toast("Tarefa criada."); await load(); tab = "todas"; render();
    } else if (f.id === "form-usuario") {
      const v = id => $(id).value.trim();
      const { error } = await db.from("usuarios").insert({ nome: v("#nu-nome"), email: v("#nu-email").toLowerCase(), cargo: v("#nu-cargo") || null,
        area: v("#nu-area"), perfil: v("#nu-perfil"), modalidade: v("#nu-mod") });
      if (error) return toast(/duplicate/i.test(error.message) ? "Esse e-mail já está cadastrado." : errMsg(error));
      toast("Pessoa cadastrada. Peça para ela abrir o app e clicar em \"Primeiro acesso\"."); await load(); render();
    } else if (f.id === "form-cliente") {
      const v = id => $(id).value.trim();
      const { error } = await db.from("clientes").insert({ codigo: v("#nc-cod").toUpperCase(), razao_social: v("#nc-razao"), cnpj_cpf: v("#nc-cnpj"),
        regime_tributario: v("#nc-regime"), responsavel_id: +v("#nc-resp"), contato_nome: v("#nc-cnome") || null,
        contato_telefone: v("#nc-ctel") || null, contato_email: v("#nc-cemail") || null, pasta_arquivos: v("#nc-pasta") || null });
      if (error) return toast(/duplicate/i.test(error.message) ? "Já existe cliente com esse código ou CNPJ." : errMsg(error));
      toast("Cliente cadastrado."); await load(); render();
    }
  } finally { if (btn && document.body.contains(btn)) btn.disabled = false; }
});


})();
