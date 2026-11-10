# Painel Power BI: Tarefas do Escritório

Um único arquivo `.pbix`, publicado no Power BI Service, atende os dois públicos:

- **Colaborador**: abre o painel e vê **só as tarefas dele** (segurança em nível de linha pelo e-mail de login).
- **Gestor**: vê todos, acompanha conclusões por pessoa, prazos e gargalos.

Presencial e home office acessam o mesmo link (navegador, app desktop ou celular), sem VPN.

## 1. Conexão

**Obter dados → Banco de dados PostgreSQL**

- Servidor: endereço do banco (no Supabase: *Project Settings → Database → Connection pooling*, porta 6543)
- Banco: `postgres` (Supabase) ou `escritorio`
- Modo: **Importar** com atualização agendada (a cada 1 h, por exemplo), ou **DirectQuery** para tempo real
- Usuário de leitura dedicado ao Power BI (somente `SELECT` no schema `escritorio`):

```sql
CREATE ROLE powerbi_leitura LOGIN PASSWORD '<defina-uma-senha-forte>' BYPASSRLS;
GRANT USAGE ON SCHEMA escritorio TO powerbi_leitura;
GRANT SELECT ON ALL TABLES IN SCHEMA escritorio TO powerbi_leitura;
```

> O usuário do Power BI lê tudo (`BYPASSRLS`); quem filtra por pessoa é o RLS do **Power BI** (seção 3).

Tabelas/visões a importar:

| Consulta | Uso |
|---|---|
| `escritorio.vw_tarefas` | Fato principal (todas as tarefas com situação calculada) |
| `escritorio.vw_pendencias_abertas` | Pendências e "quem está esperando por mim" |
| `escritorio.vw_gestor_linha_tempo` | Histórico / auditoria |
| `escritorio.usuarios` | Dimensão de pessoas (e RLS) |
| `escritorio.clientes` | Dimensão de clientes |
| `dCalendario` | Tabela de datas (DAX abaixo) |

## 2. Modelo (relacionamentos)

```
usuarios[id] 1 ──* vw_tarefas[responsavel_id]
clientes[id] 1 ──* vw_tarefas[cliente_id]
vw_tarefas[tarefa_id] 1 ──* vw_gestor_linha_tempo[tarefa_id]
dCalendario[Date] 1 ──* vw_tarefas[DataConclusao]  (coluna: = DATEVALUE(vw_tarefas[concluido_em]))
dCalendario[Date] 1 ──* vw_tarefas[prazo]          (inativa; use USERELATIONSHIP)
```

`vw_pendencias_abertas` fica **sem relacionamento** com `vw_tarefas` (tabela independente). Assim o RLS de
`vw_tarefas` não esconde as pendências de colegas que estão esperando por você (seção 3).

```dax
dCalendario =
ADDCOLUMNS (
    CALENDAR ( DATE ( 2025, 1, 1 ), DATE ( YEAR ( TODAY () ) + 1, 12, 31 ) ),
    "Ano", YEAR ( [Date] ),
    "Mes", FORMAT ( [Date], "MM/YYYY" ),
    "MesNum", YEAR ( [Date] ) * 100 + MONTH ( [Date] ),
    "Semana", WEEKNUM ( [Date], 2 )
)
```

## 3. Segurança: cada colaborador vê só o que é dele

**Modelagem → Gerenciar funções**

| Função | Tabela | Filtro DAX |
|---|---|---|
| `Colaborador` | `vw_tarefas` | `[responsavel_email] = USERPRINCIPALNAME()` |
| `Colaborador` | `vw_pendencias_abertas` | `[responsavel_email] = USERPRINCIPALNAME() \|\| [bloqueador_email] = USERPRINCIPALNAME()` |
| `Gestor` | (nenhum filtro) | |

No Power BI Service: *Conjunto de dados → Segurança*, coloque cada pessoa (ou grupo) na função certa.
O e-mail de `usuarios.email` deve ser **igual** ao login Microsoft 365 da pessoa.

> O filtro de RLS se propaga pelos relacionamentos. Por isso `vw_pendencias_abertas` não se relaciona com
> `vw_tarefas` e tem o próprio filtro: o colaborador vê as pendências das tarefas dele **e** as de colegas que
> aguardam por ele.

## 4. Medidas DAX

```dax
// ---------- Contagens ----------
Tarefas Abertas =
CALCULATE ( COUNTROWS ( vw_tarefas ),
    NOT vw_tarefas[status] IN { "concluida", "cancelada" } )

Tarefas Bloqueadas =
CALCULATE ( COUNTROWS ( vw_tarefas ), vw_tarefas[situacao] = "Bloqueada" )

Tarefas Atrasadas =
CALCULATE ( COUNTROWS ( vw_tarefas ), vw_tarefas[atrasada] = TRUE () )

Tarefas Concluidas =
CALCULATE ( COUNTROWS ( vw_tarefas ), vw_tarefas[status] = "concluida" )

Concluidas no Prazo =
CALCULATE ( [Tarefas Concluidas], vw_tarefas[concluida_no_prazo] = TRUE () )

% No Prazo =
DIVIDE ( [Concluidas no Prazo],
         CALCULATE ( [Tarefas Concluidas], NOT ISBLANK ( vw_tarefas[prazo] ) ) )

Vencem em 3 dias =
CALCULATE ( [Tarefas Abertas], vw_tarefas[dias_para_prazo] >= 0, vw_tarefas[dias_para_prazo] <= 3 )

// ---------- Tempo ----------
Horas Medias de Execucao =
AVERAGEX (
    FILTER ( vw_tarefas, vw_tarefas[status] = "concluida" && NOT ISBLANK ( vw_tarefas[iniciado_em] ) ),
    DATEDIFF ( vw_tarefas[iniciado_em], vw_tarefas[concluido_em], MINUTE ) / 60
)

Dias Medios Criacao ate Conclusao =
AVERAGEX (
    FILTER ( vw_tarefas, vw_tarefas[status] = "concluida" ),
    DATEDIFF ( vw_tarefas[criado_em], vw_tarefas[concluido_em], DAY )
)

Concluidas Mes Atual =
CALCULATE ( [Tarefas Concluidas],
    DATESMTD ( dCalendario[Date] ) )   // relação ativa por DataConclusao

// ---------- Pendências ----------
Pendencias Abertas = COUNTROWS ( vw_pendencias_abertas )

Pendencias com Cliente =
CALCULATE ( [Pendencias Abertas], vw_pendencias_abertas[tipo] = "cliente" )

Maior Espera (dias) = MAX ( vw_pendencias_abertas[dias_pendente] )

Esperando por Mim =
CALCULATE ( [Pendencias Abertas],
    vw_pendencias_abertas[bloqueador_email] = USERPRINCIPALNAME () )

// ---------- Visual ----------
Cor Situacao =
SWITCH ( SELECTEDVALUE ( vw_tarefas[situacao] ),
    "Bloqueada", "#C62828",
    "Em andamento", "#1565C0",
    "Em revisão", "#6A1B9A",
    "Liberada para iniciar", "#2E7D32",
    "Concluída", "#9E9E9E",
    "#616161" )

Texto Prazo =
VAR d = SELECTEDVALUE ( vw_tarefas[dias_para_prazo] )
RETURN SWITCH ( TRUE (),
    ISBLANK ( d ), "",
    d < 0, "Atrasada " & ABS ( d ) & " dia(s)",
    d = 0, "Vence hoje",
    "Vence em " & d & " dia(s)" )
```

## 5. Páginas do relatório

### Colaborador

1. **Minhas tarefas**: tabela com Cliente, Tarefa, Competência, Prioridade, `Texto Prazo`, Situação
   (formatação condicional com `Cor Situacao`), *Aguardando* e Pasta do cliente.
   Cartões: Abertas, Bloqueadas, Atrasadas, Vencem em 3 dias.
   Segmentação por Situação e Cliente. Ordenar por `ordem_prioridade` e `prazo`.
2. **Esperando por mim**: tabela de `vw_pendencias_abertas` com `bloqueador_email = USERPRINCIPALNAME()`:
   quem está esperando, qual tarefa, há quantos dias.
3. **Minhas pendências com clientes**: o que falta de cada cliente, contato e última cobrança.

### Gestor

1. **Visão geral**: cartões (Abertas, Bloqueadas, Atrasadas, % No Prazo, Concluídas no mês);
   colunas empilhadas *Tarefas por colaborador × situação*; segmentação por modalidade
   (presencial / home office / híbrido) e área.
2. **Conclusões**: tabela de `vw_tarefas` filtrada em `status = concluida`: Tarefa, Cliente,
   Responsável, **Concluído por**, **Data/hora de conclusão**, Prazo, No prazo? (ícone), Horas de execução.
   Linha: Concluídas por dia, por colaborador.
3. **Produtividade por colaborador**: matriz Colaborador × Mês com Concluídas, % No Prazo,
   Horas médias de execução; última atividade (máx. de `vw_gestor_linha_tempo[ocorrido_em]`).
4. **Gargalos**: barras de `Pendencias Abertas` por *tipo* e por *bloqueado_por*; tabela das
   pendências com mais dias abertas; destaque para clientes que mais atrasam envio de documentos.
5. **Auditoria**: `vw_gestor_linha_tempo` com filtros de data, colaborador, cliente e evento.

## 6. Publicação

1. Publicar no workspace do escritório.
2. Configurar o **gateway** apenas se o banco estiver na rede local (banco na nuvem dispensa gateway).
3. Atualização agendada (Importar) ou DirectQuery.
4. Atribuir as funções de RLS (Colaborador / Gestor).
5. Criar um **Aplicativo** do workspace e compartilhar com a equipe; fixar no Teams se o escritório usa.
6. Alertas: no cartão *Tarefas Atrasadas* do gestor, criar alerta para valor > 0.
