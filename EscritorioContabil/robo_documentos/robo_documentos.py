#!/usr/bin/env python3
"""
Robô de documentos do escritório.

Lê os PDFs da pasta de entrada (00_ENTRADA), reconhece o documento,
descobre o cliente pelo CNPJ, move o arquivo para a pasta do cliente e dá a
baixa na tarefa correspondente da Mesa de Tarefas.

Documentos reconhecidos hoje:
  * CND federal (Certidão de Débitos Relativos a Tributos Federais e à Dívida
    Ativa da União): negativa, positiva com efeitos de negativa e positiva.

O que não for reconhecido, ou não tiver cliente/tarefa, vai para 00_A_CONFERIR
(ou para a pasta do cliente, quando só a tarefa não foi encontrada).

Uso:
  python robo_documentos.py            # processa a pasta de entrada
  python robo_documentos.py --simular  # mostra o que faria, sem mover nem dar baixa
  python robo_documentos.py --ler arquivo.pdf   # só mostra o que foi lido do PDF

Requer Python 3.9+ e o pacote pypdf (pip install pypdf).
"""
from __future__ import annotations

import argparse
import configparser
import datetime as dt
import json
import logging
import re
import shutil
import sys
import time
import unicodedata
import urllib.error
import urllib.request
from pathlib import Path

try:
    from pypdf import PdfReader
except ImportError:  # pragma: no cover
    sys.exit("Falta o pacote pypdf. Rode: pip install pypdf")

AQUI = Path(__file__).resolve().parent
log = logging.getLogger("robo")

SITUACAO_ARQ = {
    "negativa": "NEGATIVA",
    "positiva_efeito_negativa": "POSITIVA-EFEITO-NEGATIVA",
    "positiva": "POSITIVA",
}


# --------------------------------------------------------------------------- leitura do PDF
def normalizar(txt: str) -> str:
    txt = unicodedata.normalize("NFKD", txt).encode("ascii", "ignore").decode()
    return re.sub(r"\s+", " ", txt).upper()


def texto_do_pdf(caminho: Path) -> str:
    leitor = PdfReader(str(caminho))
    return "\n".join((p.extract_text() or "") for p in leitor.pages[:5])


def data_br(s: str | None) -> dt.date | None:
    if not s:
        return None
    try:
        return dt.datetime.strptime(s, "%d/%m/%Y").date()
    except ValueError:
        return None


def ler_documento(texto: str) -> dict:
    """Reconhece o documento e extrai os dados. Retorna {'tipo': None} se não reconhecer."""
    n = normalizar(texto)
    doc: dict = {"tipo": None}

    if "CERTIDAO" in n and "TRIBUTOS FEDERAIS" in n and "DIVIDA ATIVA DA UNIAO" in n:
        doc["tipo"] = "cnd_federal"
        if "POSITIVA COM EFEITOS DE NEGATIVA" in n:
            doc["situacao"] = "positiva_efeito_negativa"
        elif "CERTIDAO NEGATIVA" in n:
            doc["situacao"] = "negativa"
        elif "CERTIDAO POSITIVA" in n:
            doc["situacao"] = "positiva"
        else:
            doc["situacao"] = None

        m = re.search(r"CNPJ\s*:?\s*(\d{2}\.?\d{3}\.?\d{3}(?:/?\d{4}-?\d{2})?)", n)
        doc["cnpj"] = m.group(1) if m else None
        m = re.search(r"VALIDA ATE\s*(\d{2}/\d{2}/\d{4})", n)
        doc["validade"] = data_br(m.group(1) if m else None)
        m = re.search(r"DO DIA\s*(\d{2}/\d{2}/\d{4})", n) or re.search(r"EMITIDA .*?(\d{2}/\d{2}/\d{4})", n)
        doc["emissao"] = data_br(m.group(1) if m else None)
        m = re.search(r"CODIGO DE CONTROLE DA CERTIDAO\s*:?\s*([0-9A-F]{4}\.[0-9A-F]{4}\.[0-9A-F]{4}\.[0-9A-F]{4})", n)
        doc["codigo"] = m.group(1) if m else None
    return doc


# --------------------------------------------------------------------------- API (Supabase)
class Api:
    def __init__(self, url: str, chave_publica: str, token: str):
        self.base = url.rstrip("/") + "/rest/v1/rpc/"
        self.chave = chave_publica
        self.token = token

    def chamar(self, funcao: str, dados: dict) -> dict:
        corpo = json.dumps({"p_token": self.token, **dados}, default=str).encode()
        req = urllib.request.Request(
            self.base + funcao, data=corpo, method="POST",
            headers={"apikey": self.chave, "Content-Type": "application/json",
                     "Content-Profile": "robo", "Accept-Profile": "robo"})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.loads(r.read() or b"null")
        except urllib.error.HTTPError as e:
            msg = e.read().decode(errors="replace")
            raise RuntimeError(f"API recusou ({e.code}): {msg}") from None


# --------------------------------------------------------------------------- arquivos
def destino_livre(pasta: Path, nome: str) -> Path:
    alvo = pasta / nome
    i = 2
    while alvo.exists():
        alvo = pasta / f"{Path(nome).stem}_{i}{Path(nome).suffix}"
        i += 1
    return alvo


def nome_padrao(doc: dict, cliente_codigo: str) -> str:
    emissao = (doc.get("emissao") or dt.date.today()).isoformat()
    sit = SITUACAO_ARQ.get(doc.get("situacao") or "", "SITUACAO-INDEFINIDA")
    val = f"_valida-{doc['validade'].isoformat()}" if doc.get("validade") else ""
    return f"{emissao}_{cliente_codigo}_CND-FEDERAL_{sit}{val}.pdf"


def processar(arq: Path, cfg: dict, api: Api | None, simular: bool) -> str:
    raiz: Path = cfg["raiz"]
    conferir = raiz / cfg["a_conferir"]
    try:
        doc = ler_documento(texto_do_pdf(arq))
    except Exception as e:  # PDF corrompido, protegido etc.
        doc = {"tipo": None}
        log.warning("Não consegui ler %s: %s", arq.name, e)

    info: dict = {"ok": False, "motivo": "documento não reconhecido"}
    if doc["tipo"] and api:
        info = api.chamar("identificar", {"p_cnpj": doc.get("cnpj"), "p_tipo": doc["tipo"]})

    if info.get("ok"):
        pasta_cli = raiz / (info.get("pasta_cliente") or f"01_CLIENTES/{info['cliente_codigo']}")
        pasta = pasta_cli / cfg["subpasta_certidoes"]
        alvo = destino_livre(pasta, nome_padrao(doc, info["cliente_codigo"]))
        motivo = None if info.get("tarefa_id") else "nenhuma tarefa de CND aberta para o cliente"
    else:
        alvo = destino_livre(conferir, arq.name)
        motivo = info.get("motivo")

    resumo = (f"{arq.name}: {doc['tipo'] or 'não reconhecido'} {doc.get('situacao') or ''} "
              f"CNPJ {doc.get('cnpj') or '-'} -> {info.get('cliente_codigo') or 'A CONFERIR'} "
              f"tarefa #{info.get('tarefa_id') or '-'} -> {alvo.relative_to(raiz)}")
    if simular:
        return "[simulação] " + resumo + (f" ({motivo})" if motivo else "")

    alvo.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(arq), str(alvo))

    res = {"resultado": "local"}
    if api:
        res = api.chamar("registrar", {
            "p_arquivo": arq.name, "p_tipo": doc["tipo"], "p_cnpj": doc.get("cnpj"),
            "p_cliente_id": info.get("cliente_id"), "p_tarefa_id": info.get("tarefa_id"),
            "p_caminho": str(alvo.relative_to(raiz)).replace("\\", "/"),
            "p_situacao": doc.get("situacao"), "p_validade": doc.get("validade"),
            "p_codigo": doc.get("codigo"), "p_emissao": doc.get("emissao"),
            "p_status_baixa": cfg["status_baixa"], "p_motivo": motivo})
    return f"{res.get('resultado')}: {resumo}"


# --------------------------------------------------------------------------- principal
def carregar_config(caminho: Path) -> dict:
    if not caminho.exists():
        sys.exit(f"Arquivo de configuração não encontrado: {caminho}\n"
                 f"Copie robo_config.exemplo.ini para robo_config.ini e preencha.")
    c = configparser.ConfigParser()
    c.read(caminho, encoding="utf-8")
    g = c["geral"]
    status = g.get("status_baixa", "em_revisao").strip()
    if status not in ("em_revisao", "concluida"):
        sys.exit("status_baixa deve ser em_revisao ou concluida")
    return {
        "raiz": Path(g["raiz"]),
        "entrada": g.get("entrada", "00_ENTRADA"),
        "a_conferir": g.get("a_conferir", "00_A_CONFERIR"),
        "subpasta_certidoes": g.get("subpasta_certidoes", "07_CERTIDOES"),
        "status_baixa": status,
        "url": c["supabase"]["url"],
        "chave_publica": c["supabase"]["chave_publica"],
        "token": c["supabase"]["token_robo"].strip(),
    }


def main() -> None:
    ap = argparse.ArgumentParser(description="Robô de documentos do escritório")
    ap.add_argument("--config", type=Path, default=AQUI / "robo_config.ini")
    ap.add_argument("--simular", action="store_true", help="não move arquivos nem dá baixa")
    ap.add_argument("--ler", type=Path, help="só mostra o que foi lido de um PDF")
    a = ap.parse_args()

    if a.ler:
        print(json.dumps(ler_documento(texto_do_pdf(a.ler)), default=str, ensure_ascii=False, indent=2))
        return

    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s",
        handlers=[logging.FileHandler(AQUI / "robo.log", encoding="utf-8"), logging.StreamHandler()])
    cfg = carregar_config(a.config)
    entrada = cfg["raiz"] / cfg["entrada"]
    if not entrada.is_dir():
        sys.exit(f"Pasta de entrada não existe: {entrada}")
    api = Api(cfg["url"], cfg["chave_publica"], cfg["token"]) if cfg["token"] else None
    if not api:
        log.warning("Sem token_robo na configuração: os arquivos vão para %s e nenhuma baixa é dada.", cfg["a_conferir"])

    agora = time.time()
    pdfs = sorted(p for p in entrada.iterdir() if p.is_file() and p.suffix.lower() == ".pdf")
    for arq in pdfs:
        if agora - arq.stat().st_mtime < 60:      # ainda pode estar sendo copiado
            continue
        try:
            log.info(processar(arq, cfg, api, a.simular))
        except Exception as e:
            log.error("Falha em %s: %s", arq.name, e)
    if not pdfs:
        log.info("Nenhum PDF novo em %s", entrada)


if __name__ == "__main__":
    main()
