#!/usr/bin/env python3
"""
Cria a estrutura padrão de pastas do escritório contábil.

Funciona em qualquer destino que apareça como pasta no computador:
  * Servidor/NAS da rede local   ->  \\\\SERVIDOR\\Escritorio   ou  Z:\\
  * SharePoint/OneDrive sincronizado (acesso home office)
  * Google Drive compartilhado (Drive para computador)

Uso:
  python criar_estrutura.py --raiz "Z:\\" --clientes clientes.csv --anos 2025 2026
  python criar_estrutura.py --raiz ./teste --clientes clientes_exemplo.csv --simular

O script é idempotente: pode ser rodado de novo sempre que entrar cliente
novo ou virar o ano; pastas que já existem não são tocadas.
"""
from __future__ import annotations

import argparse
import csv
import re
import sys
import unicodedata
from datetime import date
from pathlib import Path

# ---------------------------------------------------------------------------
# Estrutura geral (raiz do compartilhamento)
# ---------------------------------------------------------------------------
ESTRUTURA_RAIZ = [
    "00_ADMINISTRATIVO_ESCRITORIO/01_FINANCEIRO",          # restrito: gestão
    "00_ADMINISTRATIVO_ESCRITORIO/02_RH_INTERNO",          # restrito: gestão
    "00_ADMINISTRATIVO_ESCRITORIO/03_CONTRATOS_DE_HONORARIOS",
    "00_ADMINISTRATIVO_ESCRITORIO/04_TI_E_ACESSOS",        # inventário, nunca senhas
    "01_CLIENTES",
    "02_MODELOS_E_PROCEDIMENTOS/01_POPS",                   # procedimentos operacionais
    "02_MODELOS_E_PROCEDIMENTOS/02_PLANILHAS_MODELO",
    "02_MODELOS_E_PROCEDIMENTOS/03_MODELOS_DE_DOCUMENTOS",
    "02_MODELOS_E_PROCEDIMENTOS/04_LEGISLACAO_E_CONSULTAS",
    "03_ENTRADA_DOCUMENTOS/01_DIGITALIZADOS_SCANNER",       # scanner do escritório cai aqui
    "03_ENTRADA_DOCUMENTOS/02_RECEBIDOS_EMAIL_PORTAL",      # triagem antes de arquivar
    "04_TRANSFERENCIA_TEMPORARIA",                          # limpa toda semana
    "05_ARQUIVO_MORTO",                                     # clientes inativos (só leitura)
    "06_RELATORIOS_GESTAO/POWERBI",                         # painéis e extrações
]

# ---------------------------------------------------------------------------
# Estrutura de cada cliente
#   {ANO} e {MES} são expandidos; pastas sem marcador são criadas uma vez.
# ---------------------------------------------------------------------------
ESTRUTURA_CLIENTE = [
    "00_CADASTRO/01_ATOS_SOCIETARIOS",       # contrato social, alterações
    "00_CADASTRO/02_DOCUMENTOS_SOCIOS",
    "00_CADASTRO/03_PROCURACOES_E_ACESSOS",  # procurações e-CAC (certificado fica no cofre!)
    "00_CADASTRO/04_ALVARAS_E_LICENCAS",
    "00_CADASTRO/05_CONTRATO_COM_ESCRITORIO",
    "01_RECEBIDOS_DO_CLIENTE/{ANO}/{MES}",   # tudo que o cliente envia, sem tratar
    "02_CONTABIL/{ANO}/{MES}/01_EXTRATOS_E_CONCILIACAO",
    "02_CONTABIL/{ANO}/{MES}/02_LANCAMENTOS",
    "02_CONTABIL/{ANO}/{MES}/03_BALANCETE",
    "02_CONTABIL/{ANO}/00_ANUAL/BALANCO_DRE",
    "02_CONTABIL/{ANO}/00_ANUAL/SPED_ECD",
    "02_CONTABIL/{ANO}/00_ANUAL/SPED_ECF",
    "03_FISCAL/{ANO}/{MES}/01_NOTAS_ENTRADA",
    "03_FISCAL/{ANO}/{MES}/02_NOTAS_SAIDA",
    "03_FISCAL/{ANO}/{MES}/03_APURACAO",
    "03_FISCAL/{ANO}/{MES}/04_GUIAS",
    "03_FISCAL/{ANO}/{MES}/05_OBRIGACOES_ACESSORIAS",
    "04_DEPARTAMENTO_PESSOAL/{ANO}/{MES}/01_FOLHA",
    "04_DEPARTAMENTO_PESSOAL/{ANO}/{MES}/02_GUIAS_FGTS_INSS",
    "04_DEPARTAMENTO_PESSOAL/{ANO}/{MES}/03_ESOCIAL",
    "04_DEPARTAMENTO_PESSOAL/00_ADMISSOES_E_DEMISSOES",
    "04_DEPARTAMENTO_PESSOAL/00_FUNCIONARIOS",
    "05_SOCIETARIO_E_LEGALIZACAO",
    "06_ENTREGUES_AO_CLIENTE/{ANO}/{MES}",   # cópia do que foi enviado (comprovante)
    "07_CERTIDOES",
    "08_FISCALIZACOES_E_PROCESSOS",
]

MESES = [f"{m:02d}" for m in range(1, 13)]


def normalizar(texto: str) -> str:
    """'Padaria Pão Quente Ltda.' -> 'PADARIA_PAO_QUENTE_LTDA'"""
    texto = unicodedata.normalize("NFKD", texto).encode("ascii", "ignore").decode()
    texto = re.sub(r"[^A-Za-z0-9]+", "_", texto).strip("_").upper()
    return texto[:40].rstrip("_")


def pasta_do_cliente(codigo: str, nome: str) -> str:
    return f"{codigo.strip().upper()}_{normalizar(nome)}"


def pastas_do_cliente(anos: list[int]) -> list[str]:
    resultado: list[str] = []
    for modelo in ESTRUTURA_CLIENTE:
        if "{ANO}" not in modelo:
            resultado.append(modelo)
            continue
        for ano in anos:
            if "{MES}" in modelo:
                resultado += [modelo.format(ANO=ano, MES=f"{ano}-{m}") for m in MESES]
            else:
                resultado.append(modelo.format(ANO=ano))
    return resultado


def ler_clientes(caminho: Path) -> list[dict]:
    with caminho.open(encoding="utf-8-sig", newline="") as f:
        amostra = f.read(2048)
        f.seek(0)
        dialeto = csv.Sniffer().sniff(amostra, delimiters=";,")
        leitor = csv.DictReader(f, dialect=dialeto)
        clientes = [linha for linha in leitor if (linha.get("codigo") or "").strip()]
    obrigatorias = {"codigo", "razao_social"}
    if clientes and not obrigatorias.issubset(clientes[0].keys()):
        sys.exit(f"CSV precisa das colunas: {', '.join(sorted(obrigatorias))}")
    return clientes


def criar(raiz: Path, relativas: list[str], simular: bool) -> int:
    criadas = 0
    for rel in relativas:
        destino = raiz / rel
        if destino.exists():
            continue
        criadas += 1
        if simular:
            print(f"[simulação] {destino}")
        else:
            destino.mkdir(parents=True, exist_ok=True)
    return criadas


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--raiz", required=True, type=Path, help="pasta raiz do compartilhamento")
    p.add_argument("--clientes", type=Path, help="CSV com colunas codigo;razao_social[;ativo]")
    p.add_argument("--anos", type=int, nargs="+", default=[date.today().year],
                   help="anos de competência a criar (padrão: ano atual)")
    p.add_argument("--simular", action="store_true", help="só mostra o que seria criado")
    args = p.parse_args()

    total = criar(args.raiz, ESTRUTURA_RAIZ, args.simular)

    if args.clientes:
        modelo = pastas_do_cliente(args.anos)
        for cli in ler_clientes(args.clientes):
            ativo = (cli.get("ativo") or "S").strip().upper() not in {"N", "NAO", "NÃO", "0", "FALSE"}
            base = "01_CLIENTES" if ativo else "05_ARQUIVO_MORTO"
            nome = pasta_do_cliente(cli["codigo"], cli["razao_social"])
            n = criar(args.raiz / base / nome, modelo if ativo else [""], args.simular)
            total += n
            print(f"{'ATIVO  ' if ativo else 'INATIVO'} {base}/{nome}: {n} pasta(s) nova(s)")

    print(f"\nConcluído. {total} pasta(s) {'seriam criadas' if args.simular else 'criadas'}.")


if __name__ == "__main__":
    main()
