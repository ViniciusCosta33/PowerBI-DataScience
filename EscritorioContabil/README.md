# Escritório Contábil: arquivos, dados e tarefas (presencial + home office)

Estrutura completa para um escritório contábil em que parte da equipe trabalha
**presencialmente na mesma rede** e parte trabalha **em home office**, com:

1. **Arquivos**: um único lugar oficial para cada documento, com a mesma estrutura de pastas para todos.
2. **Tarefas**: cada colaborador vê **as suas tarefas, o status e do que (ou de quem) cada uma depende**.
3. **Gestão**: o gestor acompanha **cada tarefa, quem fez, quando concluiu e se foi no prazo**.

```
EscritorioContabil/
├── README.md                         <- este guia
├── estrutura_arquivos/
│   ├── criar_estrutura.py            <- cria as pastas padrão (rede ou nuvem)
│   └── clientes_exemplo.csv
├── banco_tarefas/
│   ├── 01_schema.sql                 <- tabelas
│   ├── 02_regras_automaticas.sql     <- triggers: datas, histórico, bloqueios
│   ├── 03_views.sql                  <- visões do colaborador e do gestor
│   ├── 04_seguranca_rls.sql          <- (opcional) cada um vê só o que é seu
│   ├── 05_dados_exemplo.sql          <- dados fictícios para testar
│   └── testes/testes_regras.sql      <- testes automáticos das regras
└── powerbi/
    └── PAINEL_TAREFAS.md             <- modelo, medidas DAX e páginas do painel
```

---

## 1. Arquitetura: como presencial e home office trabalham juntos

```
              ESCRITÓRIO (rede local)                          HOME OFFICE
 ┌─────────────────────────────────────────────┐      ┌──────────────────────────┐
 │  Estações  ──LAN──┐                         │      │  Notebook do escritório  │
 │  Scanner   ───────┤                         │      │  (disco criptografado)   │
 │                   ▼                         │      └────────────┬─────────────┘
 │        NAS / Servidor de arquivos           │                   │ HTTPS + MFA
 │   (cópia local + backup de versões)         │                   │
 └──────────────┬──────────────────────────────┘                   │
                │ sincronização                                    │
                ▼                                                  ▼
     ┌──────────────────────────────────────────────────────────────────┐
     │  NUVEM = FONTE OFICIAL                                           │
     │  • Arquivos: SharePoint/OneDrive (M365) ou Google Drive compart. │
     │  • Tarefas: PostgreSQL gerenciado (ex.: Supabase) + Power BI     │
     └──────────────────────────────────────────────────────────────────┘
                │ backup diário independente (outra conta/provedor)
                ▼
          Backup externo imutável
```

**Recomendação: a nuvem é a fonte oficial; o servidor local é cache e backup.**

| Opção | Presencial | Home office | Quando usar |
|---|---|---|---|
| **A. Nuvem como oficial** (SharePoint / Google Drive compartilhado) + NAS sincronizado | Rápido (sincronizado) | Igual ao presencial, sem VPN | **Recomendado** para a maioria dos escritórios |
| B. Servidor local como oficial + VPN | Rápido | Depende da internet do escritório; VPN lenta para arquivos grandes | Quando há sistema contábil instalado só no servidor |
| C. Híbrida: sistema contábil em servidor/nuvem do fornecedor + arquivos na nuvem | Rápido | Acesso remoto (RDP/VPN) só para o sistema | Comum em escritórios com sistemas Domínio, Alterdata, Questor etc. |

Regras que valem em qualquer opção:

- **Nada de arquivo de cliente salvo só no computador** (Área de Trabalho, Downloads, pen drive, WhatsApp Web).
- **Pastas sincronizam, e-mail não é arquivo**: anexo recebido vai para `01_RECEBIDOS_DO_CLIENTE` no mesmo dia.
- **Certificados digitais A1 e senhas ficam em cofre de senhas** (ex.: Bitwarden/1Password Teams), nunca em pasta.
- Home office usa **equipamento do escritório**, com disco criptografado (BitLocker/FileVault), antivírus e MFA no login da nuvem.

---

## 2. Estrutura de pastas

Criada automaticamente pelo script (veja a seção 7). Raiz do compartilhamento:

```
ESCRITORIO/
├── 00_ADMINISTRATIVO_ESCRITORIO/      (restrito à gestão)
│   ├── 01_FINANCEIRO
│   ├── 02_RH_INTERNO
│   ├── 03_CONTRATOS_DE_HONORARIOS
│   └── 04_TI_E_ACESSOS                (inventário, nunca senhas)
├── 01_CLIENTES/
│   └── C0001_PADARIA_PAO_QUENTE_LTDA/ (código + nome, ver abaixo)
├── 02_MODELOS_E_PROCEDIMENTOS/        (POPs, planilhas modelo, legislação)
├── 03_ENTRADA_DOCUMENTOS/             (scanner e triagem; esvaziar diariamente)
├── 04_TRANSFERENCIA_TEMPORARIA/       (limpa toda semana, nada oficial aqui)
├── 05_ARQUIVO_MORTO/                  (clientes inativos, somente leitura)
└── 06_RELATORIOS_GESTAO/POWERBI
```

Dentro de **cada cliente** (`{AAAA-MM}` = competência):

```
C0001_PADARIA_PAO_QUENTE_LTDA/
├── 00_CADASTRO/                 atos societários, documentos dos sócios, procurações, alvarás, contrato
├── 01_RECEBIDOS_DO_CLIENTE/AAAA/AAAA-MM      tudo que o cliente envia, como chegou
├── 02_CONTABIL/AAAA/AAAA-MM/    01_EXTRATOS_E_CONCILIACAO, 02_LANCAMENTOS, 03_BALANCETE
│              AAAA/00_ANUAL/    BALANCO_DRE, SPED_ECD, SPED_ECF
├── 03_FISCAL/AAAA/AAAA-MM/      01_NOTAS_ENTRADA, 02_NOTAS_SAIDA, 03_APURACAO, 04_GUIAS, 05_OBRIGACOES_ACESSORIAS
├── 04_DEPARTAMENTO_PESSOAL/AAAA/AAAA-MM/  01_FOLHA, 02_GUIAS_FGTS_INSS, 03_ESOCIAL
│                          00_ADMISSOES_E_DEMISSOES, 00_FUNCIONARIOS
├── 05_SOCIETARIO_E_LEGALIZACAO/
├── 06_ENTREGUES_AO_CLIENTE/AAAA/AAAA-MM      cópia do que foi enviado (comprovante)
├── 07_CERTIDOES/
└── 08_FISCALIZACOES_E_PROCESSOS/
```

### Padrão de nome de arquivo

```
AAAA-MM_CODIGO_AREA_DOCUMENTO_vNN.ext
2026-10_C0002_FISCAL_APURACAO-DAS_v01.pdf
2026-10_C0001_CONTABIL_BALANCETE_v02.xlsx
2026-10_C0003_DP_FOLHA-ANALITICA_v01.pdf
```

- Competência no início, para a ordem alfabética ficar cronológica.
- Sem acentos, espaços ou caracteres especiais (evita erro de sincronização).
- `vNN` só quando há versões; a versão final enviada ao cliente vai também para `06_ENTREGUES_AO_CLIENTE`.
- **Nunca** `final`, `final2` ou `novo` no nome.

### Permissões (grupos, nunca pessoas individualmente)

| Grupo | 00_ADMINISTRATIVO | 01_CLIENTES | 02_MODELOS | 03/04 Entrada/Temp | 05_ARQUIVO_MORTO |
|---|---|---|---|---|---|
| Gestores | Total | Total | Total | Total | Total |
| Contábil / Fiscal / DP | Sem acesso | Editar | Leitura | Editar | Leitura |
| Estagiários | Sem acesso | Editar só nas pastas mensais | Leitura | Editar | Sem acesso |

Desligamento de colaborador: remover dos grupos **no mesmo dia** e revogar sessões da nuvem.

### Backup (regra 3-2-1)

- **3 cópias**: nuvem (oficial) + NAS local + backup externo.
- **2 mídias/locais diferentes**: nuvem e NAS.
- **1 cópia fora e imutável**: backup externo com retenção (proteção contra ransomware e exclusão acidental).
- Banco de tarefas: backup automático diário do provedor + `pg_dump` semanal guardado no backup externo.
- **Teste de restauração mensal** (restaurar uma pasta de cliente e conferir). Backup não testado não conta.
- Retenção: documentos fiscais e trabalhistas conforme prazo legal (no mínimo 5 anos; FGTS e documentos de pessoal por prazos maiores). Na dúvida, não exclua: mova para `05_ARQUIVO_MORTO`.

### LGPD

Pastas de cliente contêm dados pessoais (sócios e funcionários). Acesso só por grupo, MFA obrigatório,
proibido enviar documentos por canais pessoais, e o histórico de acesso do SharePoint/Drive deve ficar ativo.

---

## 3. Tarefas: o que cada colaborador vê

Cada pessoa abre **"Minhas tarefas"** (página do Power BI filtrada pelo seu e-mail, ou `fn_minhas_tarefas`):

| Cliente | Tarefa | Competência | Prioridade | Prazo | Situação | Aguardando |
|---|---|---|---|---|---|---|
| Clínica Sorriso | Classificação das despesas | 10/2026 | alta | **atrasada 2 dias** | Liberada para iniciar | |
| Padaria Pão Quente | Balancete mensal | 10/2026 | média | em 10 dias | **Bloqueada** | Tarefa #2 "Conciliação bancária" (Carla) · Tarefa #5 "Apuração PIS/COFINS" (Bruno) |

A ordem já é a de execução: primeiro o que **pode ser feito agora**, depois atrasadas e prioridade.

**Situação** de cada tarefa:

| Situação | Significado |
|---|---|
| Liberada para iniciar | Sem pendências, pode começar |
| Em andamento | Alguém está trabalhando |
| **Bloqueada** | Tem dependência em aberto (coluna *Aguardando* diz de quem/o quê) |
| Em revisão | Feita, aguardando conferência do revisor |
| Concluída / Cancelada | Encerrada |

**Tipos de dependência** (o motivo do bloqueio):

| Tipo | Exemplo | Quem resolve |
|---|---|---|
| `tarefa` | Balancete depende da Conciliação | **Automático** quando a outra tarefa é concluída |
| `pessoa` | Folha aguarda a gestora aprovar o reajuste | O colega marca como resolvido |
| `cliente` | Aguardando extrato bancário do cliente | Quem recebeu o documento marca como resolvido |
| `externo` | Aguardando análise da Junta Comercial | Responsável marca como resolvido |

E a outra ponta: **"Quem está esperando por mim"** (`fn_aguardando_por_mim`) mostra as tarefas de colegas
travadas por uma tarefa sua. É o que evita que o pessoal de casa e o do escritório fiquem esperando um pelo outro sem saber.

### Regras automáticas (o banco garante, ninguém precisa lembrar)

1. Iniciou → grava **data/hora de início**.
2. Concluiu → grava **data/hora de conclusão e quem concluiu**.
3. **Não deixa concluir** tarefa com pendência em aberto.
4. Abriu pendência → tarefa vai para **aguardando**.
5. Concluiu uma tarefa → **libera sozinho** as tarefas que dependiam dela (em cadeia).
6. Bloqueia **dependência circular** (A espera B que espera A).
7. Reatribuiu a tarefa → quem estava esperando passa a esperar o novo responsável.
8. **Toda** mudança de status, responsável, prazo, pendência e cobrança vai para o **histórico**.
9. Com a segurança ativada (04), a ação é sempre registrada no **usuário logado**: ninguém conclui "em nome" de outro.

---

## 4. O que o gestor acompanha

| Visão | Responde |
|---|---|
| `vw_gestor_conclusoes` | Cada tarefa concluída: **quem concluiu, data/hora, prazo, se foi no prazo, dias de atraso, horas de execução** |
| `vw_gestor_resumo_usuario` | Por colaborador (e modalidade presencial/home office): em aberto, bloqueadas, atrasadas, concluídas no mês, % no prazo, **última atividade**, quantos colegas aguardam por ele |
| `vw_gestor_linha_tempo` | Auditoria: tudo que aconteceu, por quem e quando |
| `vw_gestor_gargalos` | O que mais trava o escritório: qual cliente, qual colega, há quantos dias |
| `vw_pendencias_abertas` | Lista de cobrança: o que falta, de quem, desde quando, última cobrança, contato do cliente |

Todas viram páginas do painel Power BI: veja [`powerbi/PAINEL_TAREFAS.md`](powerbi/PAINEL_TAREFAS.md).

---

## 5. Operação do dia a dia (funções do banco)

Qualquer tela (Power Apps, AppSheet, sistema próprio ou o editor do Supabase) usa estas funções:

```sql
SET search_path TO escritorio;

-- criar tarefa
INSERT INTO tarefas (titulo, cliente_id, area, competencia, responsavel_id, criado_por, prioridade, prazo)
VALUES ('Apuração do Simples (DAS)', 2, 'fiscal', '2026-10-01', 2, 1, 'urgente', '2026-11-20');

SELECT fn_alterar_status(10, 5, 'em_andamento');                       -- iniciar
SELECT fn_adicionar_dependencia(10, 5, 'cliente', 4, 'Enviar notas de despesas');  -- registrar pendência (retorna o id, ex.: 12)
SELECT fn_registrar_cobranca(12, 5);                                   -- cobrei o cliente
SELECT fn_resolver_dependencia(12, 5, 'Notas recebidas por e-mail');   -- cliente respondeu
SELECT fn_alterar_status(10, 5, 'em_revisao');                         -- mandar para revisão
SELECT fn_concluir_tarefa(10, 1, '01_CLIENTES/C0004_.../03_APURACAO/2026-10_C0004_FISCAL_APURACAO-DAS_v01.pdf');

SELECT * FROM fn_minhas_tarefas('elisa@escritorio.com.br');            -- minhas tarefas
SELECT * FROM fn_aguardando_por_mim('carla@escritorio.com.br');         -- quem espera por mim
```

Ao concluir, informe o caminho do arquivo entregue: a tarefa fica ligada ao documento na estrutura de pastas.

---

## 6. Rotina recomendada

| Quando | Quem | O quê |
|---|---|---|
| Início do dia | Todos | Abrir "Minhas tarefas" e "Quem está esperando por mim" |
| Ao receber documento | Quem recebeu | Salvar em `01_RECEBIDOS_DO_CLIENTE/AAAA/AAAA-MM` e resolver a pendência |
| Ao travar | Responsável | Registrar a dependência **na hora** (não só avisar no WhatsApp) |
| Fim do dia | Todos | Atualizar status; `03_ENTRADA_DOCUMENTOS` vazia |
| Diário | Gestor | Painel: atrasadas, bloqueadas há mais de 3 dias, gargalos |
| Semanal | Gestor | Limpar `04_TRANSFERENCIA_TEMPORARIA`; revisar % no prazo por pessoa |
| Mensal | Gestor / TI | Teste de restauração do backup; criar tarefas da nova competência |
| Anual | TI | Rodar o script com o novo ano; mover clientes inativos para o arquivo morto |

---

## 7. Instalação

### Pastas

```bash
# simular primeiro
python estrutura_arquivos/criar_estrutura.py --raiz "Z:\\" --clientes estrutura_arquivos/clientes_exemplo.csv --anos 2026 --simular
# criar de verdade (rode de novo quando entrar cliente novo ou virar o ano)
python estrutura_arquivos/criar_estrutura.py --raiz "Z:\\" --clientes clientes.csv --anos 2026 2027
```

`--raiz` pode ser a unidade de rede, a pasta sincronizada do SharePoint/OneDrive ou do Google Drive.
Clientes com `ativo = N` no CSV vão para `05_ARQUIVO_MORTO`.

### Banco de tarefas

```bash
psql -d escritorio -f banco_tarefas/01_schema.sql
psql -d escritorio -f banco_tarefas/02_regras_automaticas.sql
psql -d escritorio -f banco_tarefas/03_views.sql
psql -d escritorio -f banco_tarefas/04_seguranca_rls.sql   # se usar login individual (Supabase)
psql -d escritorio -f banco_tarefas/05_dados_exemplo.sql   # só para testar, em banco vazio
psql -d escritorio -f banco_tarefas/testes/testes_regras.sql   # roda e desfaz (ROLLBACK)
```

PostgreSQL 15+ (o RLS usa `security_invoker` nas views). No **Supabase**: cole cada arquivo no SQL Editor,
na ordem, e preencha `usuarios.auth_user_id` com o id de login de cada colaborador. O banco na nuvem é o que
permite que presencial e home office vejam a mesma informação em tempo real, sem VPN.
