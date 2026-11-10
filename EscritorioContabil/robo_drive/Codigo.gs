/**
 * Robô de documentos do escritório (Google Drive + Apps Script)
 *
 * A cada 10 minutos, lê os PDFs da pasta 00_ENTRADA no Google Drive, reconhece
 * o documento, descobre o cliente pelo CNPJ, move o arquivo para a pasta do
 * cliente e dá a baixa na tarefa correspondente da Mesa de Tarefas.
 *
 * Documentos reconhecidos hoje: CND federal (negativa, positiva com efeitos
 * de negativa e positiva). O que não for reconhecido vai para 00_A_CONFERIR.
 *
 * Instalação: veja README.md. Em resumo:
 *   1. Preencha PASTA_RAIZ_ID abaixo.
 *   2. Em "Configurações do projeto > Propriedades do script", crie TOKEN_ROBO
 *      com a chave gerada no app (Equipe e clientes > Robô de documentos).
 *   3. Rode a função instalar() uma vez e autorize.
 */

// ----------------------------------------------------------------- configuração
const CONFIG = {
  // ID da pasta principal do escritório no Drive (o trecho depois de /folders/ no link da pasta)
  PASTA_RAIZ_ID: 'COLE_AQUI_O_ID_DA_PASTA',
  ENTRADA: '00_ENTRADA',
  A_CONFERIR: '00_A_CONFERIR',
  CLIENTES: '01_CLIENTES',
  SUBPASTA_CERTIDOES: '07_CERTIDOES',
  STATUS_BAIXA: 'em_revisao',          // 'em_revisao' (você confere) ou 'concluida'
  SUPABASE_URL: 'https://llrxrqjegckuiexahqyx.supabase.co',
  CHAVE_PUBLICA: 'sb_publishable_wlgUEupsge0nlMG-Q2RQfQ_wP_tBUnz',
  MAX_POR_EXECUCAO: 20,
};

const SITUACAO_ARQ = {
  negativa: 'NEGATIVA',
  positiva_efeito_negativa: 'POSITIVA-EFEITO-NEGATIVA',
  positiva: 'POSITIVA',
};

// ----------------------------------------------------------------- funções para rodar no editor
/** Rode uma vez: cria as pastas e agenda o robô a cada 10 minutos. */
function instalar() {
  const raiz = DriveApp.getFolderById(CONFIG.PASTA_RAIZ_ID);
  [CONFIG.ENTRADA, CONFIG.A_CONFERIR, CONFIG.CLIENTES].forEach(n => pastaPorCaminho_(raiz, n));
  ScriptApp.getProjectTriggers()
    .filter(t => t.getHandlerFunction() === 'processarEntrada')
    .forEach(t => ScriptApp.deleteTrigger(t));
  ScriptApp.newTrigger('processarEntrada').timeBased().everyMinutes(10).create();
  if (!token_()) throw new Error('Falta a propriedade TOKEN_ROBO (Configurações do projeto > Propriedades do script).');
  Logger.log('Instalado. Pastas prontas em "%s" e robô agendado a cada 10 minutos.', raiz.getName());
}

/** Mostra o que o robô faria, sem mover nada nem dar baixa. */
function simular() { processar_(true); }

/** Execução normal (é esta que o agendamento chama). */
function processarEntrada() { processar_(false); }

/** Remove o agendamento. */
function desinstalar() {
  ScriptApp.getProjectTriggers()
    .filter(t => t.getHandlerFunction() === 'processarEntrada')
    .forEach(t => ScriptApp.deleteTrigger(t));
  Logger.log('Agendamento removido.');
}

// ----------------------------------------------------------------- processamento
function processar_(simulacao) {
  const trava = LockService.getScriptLock();
  if (!trava.tryLock(1000)) return;           // já tem uma execução rodando
  try {
    const raiz = DriveApp.getFolderById(CONFIG.PASTA_RAIZ_ID);
    const entrada = pastaPorCaminho_(raiz, CONFIG.ENTRADA);
    const arquivos = entrada.getFilesByType(MimeType.PDF);
    let n = 0;
    while (arquivos.hasNext() && n < CONFIG.MAX_POR_EXECUCAO) {
      const arq = arquivos.next();
      if (Date.now() - arq.getLastUpdated().getTime() < 60 * 1000) continue;   // ainda subindo
      n++;
      try {
        Logger.log(processarArquivo_(arq, raiz, simulacao));
      } catch (e) {
        Logger.log('ERRO em %s: %s', arq.getName(), e.message);
      }
    }
    if (!n) Logger.log('Nenhum PDF novo em %s.', CONFIG.ENTRADA);
  } finally {
    trava.releaseLock();
  }
}

function processarArquivo_(arq, raiz, simulacao) {
  const nomeOriginal = arq.getName();
  let doc = { tipo: null };
  try {
    doc = lerDocumento(textoDoPdf_(arq));
  } catch (e) {
    Logger.log('Não consegui ler %s: %s', nomeOriginal, e.message);
  }

  let info = { ok: false, motivo: 'documento não reconhecido' };
  if (doc.tipo) info = api_('identificar', { p_cnpj: doc.cnpj, p_tipo: doc.tipo });

  let destino, novoNome, motivo = null;
  if (info.ok) {
    const pastaCli = info.pasta_cliente || (CONFIG.CLIENTES + '/' + info.cliente_codigo);
    destino = pastaCli + '/' + CONFIG.SUBPASTA_CERTIDOES;
    novoNome = nomePadrao(doc, info.cliente_codigo);
    if (!info.tarefa_id) motivo = 'nenhuma tarefa de CND aberta para o cliente';
  } else {
    destino = CONFIG.A_CONFERIR;
    novoNome = nomeOriginal;
    motivo = info.motivo;
  }

  const resumo = nomeOriginal + ': ' + (doc.tipo || 'não reconhecido') + ' ' + (doc.situacao || '') +
    ' | CNPJ ' + (doc.cnpj || '-') + ' | cliente ' + (info.cliente_codigo || 'A CONFERIR') +
    ' | tarefa #' + (info.tarefa_id || '-') + ' | ' + destino + '/' + novoNome;
  if (simulacao) return '[simulação] ' + resumo + (motivo ? ' (' + motivo + ')' : '');

  const pasta = pastaPorCaminho_(raiz, destino);
  arq.setName(nomeLivre_(pasta, novoNome));
  arq.moveTo(pasta);

  const res = api_('registrar', {
    p_arquivo: nomeOriginal, p_tipo: doc.tipo, p_cnpj: doc.cnpj || null,
    p_cliente_id: info.cliente_id || null, p_tarefa_id: info.tarefa_id || null,
    p_caminho: arq.getUrl(), p_situacao: doc.situacao || null,
    p_validade: doc.validade || null, p_codigo: doc.codigo || null, p_emissao: doc.emissao || null,
    p_status_baixa: CONFIG.STATUS_BAIXA, p_motivo: motivo,
  });
  return res.resultado + ': ' + resumo;
}

// ----------------------------------------------------------------- leitura do PDF
/** Converte o PDF em Google Docs (o Google extrai o texto, inclusive de PDF escaneado) e apaga o temporário. */
function textoDoPdf_(arq) {
  const temp = Drive.Files.create(
    { name: 'tmp-robo-' + arq.getId(), mimeType: MimeType.GOOGLE_DOCS },
    arq.getBlob(),
    { ocrLanguage: 'pt', supportsAllDrives: true });
  try {
    return DocumentApp.openById(temp.id).getBody().getText();
  } finally {
    Drive.Files.remove(temp.id, { supportsAllDrives: true });
  }
}

function normalizar(txt) {
  return String(txt || '').normalize('NFKD').replace(/[̀-ͯ]/g, '')
    .replace(/\s+/g, ' ').toUpperCase();
}

function dataIso_(br) {
  if (!br) return null;
  const m = br.match(/^(\d{2})\/(\d{2})\/(\d{4})$/);
  return m ? m[3] + '-' + m[2] + '-' + m[1] : null;
}

/** Reconhece o documento e extrai os dados. Retorna {tipo: null} se não reconhecer. */
function lerDocumento(texto) {
  const n = normalizar(texto);
  const doc = { tipo: null };
  if (n.indexOf('CERTIDAO') >= 0 && n.indexOf('TRIBUTOS FEDERAIS') >= 0 && n.indexOf('DIVIDA ATIVA DA UNIAO') >= 0) {
    doc.tipo = 'cnd_federal';
    if (n.indexOf('POSITIVA COM EFEITOS DE NEGATIVA') >= 0) doc.situacao = 'positiva_efeito_negativa';
    else if (n.indexOf('CERTIDAO NEGATIVA') >= 0) doc.situacao = 'negativa';
    else if (n.indexOf('CERTIDAO POSITIVA') >= 0) doc.situacao = 'positiva';
    else doc.situacao = null;
    let m = n.match(/CNPJ\s*:?\s*(\d{2}\.?\d{3}\.?\d{3}(?:\/?\d{4}-?\d{2})?)/);
    doc.cnpj = m ? m[1] : null;
    m = n.match(/VALIDA ATE\s*(\d{2}\/\d{2}\/\d{4})/);
    doc.validade = dataIso_(m && m[1]);
    m = n.match(/DO DIA\s*(\d{2}\/\d{2}\/\d{4})/) || n.match(/EMITIDA .*?(\d{2}\/\d{2}\/\d{4})/);
    doc.emissao = dataIso_(m && m[1]);
    m = n.match(/CODIGO DE CONTROLE DA CERTIDAO\s*:?\s*([0-9A-F]{4}\.[0-9A-F]{4}\.[0-9A-F]{4}\.[0-9A-F]{4})/);
    doc.codigo = m ? m[1] : null;
  }
  return doc;
}

function nomePadrao(doc, codigoCliente) {
  const emissao = doc.emissao || Utilities.formatDate(new Date(), 'America/Sao_Paulo', 'yyyy-MM-dd');
  const sit = SITUACAO_ARQ[doc.situacao] || 'SITUACAO-INDEFINIDA';
  const val = doc.validade ? '_valida-' + doc.validade : '';
  return emissao + '_' + codigoCliente + '_CND-FEDERAL_' + sit + val + '.pdf';
}

// ----------------------------------------------------------------- Drive
function pastaPorCaminho_(raiz, caminho) {
  return String(caminho).split('/').filter(Boolean).reduce((pasta, nome) => {
    const it = pasta.getFoldersByName(nome);
    return it.hasNext() ? it.next() : pasta.createFolder(nome);
  }, raiz);
}

function nomeLivre_(pasta, nome) {
  let alvo = nome, i = 2;
  const base = nome.replace(/\.pdf$/i, '');
  while (pasta.getFilesByName(alvo).hasNext()) alvo = base + '_' + (i++) + '.pdf';
  return alvo;
}

// ----------------------------------------------------------------- API (Supabase)
function token_() {
  return (PropertiesService.getScriptProperties().getProperty('TOKEN_ROBO') || '').trim();
}

function api_(funcao, dados) {
  const t = token_();
  if (!t) throw new Error('Falta a propriedade TOKEN_ROBO.');
  const resp = UrlFetchApp.fetch(CONFIG.SUPABASE_URL + '/rest/v1/rpc/' + funcao, {
    method: 'post',
    contentType: 'application/json',
    headers: { apikey: CONFIG.CHAVE_PUBLICA, 'Content-Profile': 'robo', 'Accept-Profile': 'robo' },
    payload: JSON.stringify(Object.assign({ p_token: t }, dados)),
    muteHttpExceptions: true,
  });
  const corpo = resp.getContentText();
  if (resp.getResponseCode() >= 300) throw new Error('API recusou (' + resp.getResponseCode() + '): ' + corpo);
  return corpo ? JSON.parse(corpo) : null;
}
