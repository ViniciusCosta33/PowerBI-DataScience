-- =============================================================================
-- 03_views.sql : visões prontas para o COLABORADOR e para o GESTOR
-- (também são as tabelas consumidas pelo Power BI)
-- =============================================================================
SET search_path TO escritorio, public;

-- -----------------------------------------------------------------------------
-- Pendências abertas, já "traduzidas": quem está esperando e por quem/o quê.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_pendencias_abertas AS
SELECT
    d.id                                    AS dependencia_id,
    d.tarefa_id,
    t.titulo                                AS tarefa,
    c.razao_social                          AS cliente_da_tarefa,
    ur.id                                   AS responsavel_id,
    ur.nome                                 AS responsavel,           -- quem está esperando
    ur.email                                AS responsavel_email,
    d.tipo,
    CASE d.tipo
        WHEN 'tarefa'  THEN 'Aguardando outra tarefa'
        WHEN 'pessoa'  THEN 'Aguardando colega'
        WHEN 'cliente' THEN 'Aguardando cliente'
        WHEN 'externo' THEN 'Aguardando terceiro/órgão'
    END                                     AS tipo_descricao,
    d.descricao                             AS o_que_falta,
    -- quem / o quê está travando
    CASE d.tipo
        WHEN 'tarefa'  THEN format('Tarefa #%s "%s" (%s - %s)', td.id, td.titulo, ub.nome, td.status)
        WHEN 'pessoa'  THEN ub.nome
        WHEN 'cliente' THEN cd.razao_social
        WHEN 'externo' THEN 'Externo'
    END                                     AS bloqueado_por,
    ub.id                                   AS bloqueador_usuario_id, -- colega que precisa agir
    ub.nome                                 AS bloqueador_usuario,
    ub.email                                AS bloqueador_email,
    cd.id                                   AS bloqueador_cliente_id,
    cd.contato_nome                         AS cliente_contato,
    cd.contato_email                        AS cliente_contato_email,
    cd.contato_telefone                     AS cliente_contato_telefone,
    td.status                               AS status_tarefa_bloqueadora,
    td.prazo                                AS prazo_tarefa_bloqueadora,
    d.criado_em                             AS pendente_desde,
    (CURRENT_DATE - d.criado_em::date)      AS dias_pendente,
    d.cobrado_em                            AS ultima_cobranca,
    t.prazo                                 AS prazo_tarefa
FROM tarefa_dependencias d
JOIN tarefas  t  ON t.id  = d.tarefa_id
JOIN usuarios ur ON ur.id = t.responsavel_id
LEFT JOIN clientes c  ON c.id  = t.cliente_id
LEFT JOIN tarefas  td ON td.id = d.depende_tarefa_id
LEFT JOIN usuarios ub ON ub.id = d.depende_usuario_id
LEFT JOIN clientes cd ON cd.id = d.depende_cliente_id
WHERE d.resolvido_em IS NULL
  AND t.status NOT IN ('concluida', 'cancelada');

-- -----------------------------------------------------------------------------
-- Visão completa de cada tarefa com situação calculada
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_tarefas AS
WITH dep AS (
    SELECT
        tarefa_id,
        count(*)                                           AS pendencias_abertas,
        count(*) FILTER (WHERE tipo = 'tarefa')            AS pend_tarefa,
        count(*) FILTER (WHERE tipo = 'pessoa')            AS pend_pessoa,
        count(*) FILTER (WHERE tipo = 'cliente')           AS pend_cliente,
        count(*) FILTER (WHERE tipo = 'externo')           AS pend_externo,
        string_agg(tipo_descricao || ': ' || bloqueado_por || ' - ' || o_que_falta,
                   ' | ' ORDER BY pendente_desde)          AS aguardando
    FROM vw_pendencias_abertas
    GROUP BY tarefa_id
)
SELECT
    t.id                                    AS tarefa_id,
    t.titulo,
    t.descricao,
    t.area,
    t.competencia,
    to_char(t.competencia, 'MM/YYYY')       AS competencia_txt,
    c.id                                    AS cliente_id,
    c.codigo                                AS cliente_codigo,
    COALESCE(c.razao_social, '(interna)')   AS cliente,
    u.id                                    AS responsavel_id,
    u.nome                                  AS responsavel,
    u.email                                 AS responsavel_email,
    u.modalidade                            AS responsavel_modalidade,
    rv.nome                                 AS revisor,
    t.prioridade,
    t.status,
    CASE
        WHEN t.status = 'concluida'                 THEN 'Concluída'
        WHEN t.status = 'cancelada'                 THEN 'Cancelada'
        WHEN COALESCE(dep.pendencias_abertas,0) > 0 THEN 'Bloqueada'
        WHEN t.status = 'em_revisao'                THEN 'Em revisão'
        WHEN t.status = 'em_andamento'              THEN 'Em andamento'
        ELSE 'Liberada para iniciar'
    END                                     AS situacao,
    COALESCE(dep.pendencias_abertas, 0)     AS pendencias_abertas,
    COALESCE(dep.pend_tarefa, 0)            AS pend_outra_tarefa,
    COALESCE(dep.pend_pessoa, 0)            AS pend_colega,
    COALESCE(dep.pend_cliente, 0)           AS pend_cliente,
    COALESCE(dep.pend_externo, 0)           AS pend_externo,
    dep.aguardando,
    t.prazo,
    CASE WHEN t.status NOT IN ('concluida','cancelada') THEN t.prazo - CURRENT_DATE END
                                            AS dias_para_prazo,
    (t.status NOT IN ('concluida','cancelada') AND t.prazo < CURRENT_DATE)
                                            AS atrasada,
    t.criado_em,
    cr.nome                                 AS criado_por,
    t.iniciado_em,
    t.concluido_em,
    cp.nome                                 AS concluido_por,
    CASE WHEN t.status = 'concluida' AND t.prazo IS NOT NULL
         THEN t.concluido_em::date <= t.prazo END
                                            AS concluida_no_prazo,
    t.atualizado_em,
    t.caminho_arquivos,
    c.pasta_arquivos                        AS pasta_cliente,
    CASE t.prioridade WHEN 'urgente' THEN 1 WHEN 'alta' THEN 2
                      WHEN 'media' THEN 3 ELSE 4 END
                                            AS ordem_prioridade
FROM tarefas t
JOIN usuarios u       ON u.id  = t.responsavel_id
JOIN usuarios cr      ON cr.id = t.criado_por
LEFT JOIN usuarios rv ON rv.id = t.revisor_id
LEFT JOIN usuarios cp ON cp.id = t.concluido_por
LEFT JOIN clientes c  ON c.id  = t.cliente_id
LEFT JOIN dep         ON dep.tarefa_id = t.id;

-- =============================================================================
-- VISÕES DO COLABORADOR
-- =============================================================================

-- "Minhas tarefas": tudo que está em aberto, na ordem em que deve ser feito.
-- Filtre por responsavel_email (ou use fn_minhas_tarefas / RLS).
CREATE OR REPLACE VIEW vw_minhas_tarefas AS
SELECT tarefa_id, responsavel_email, responsavel, cliente, titulo, competencia_txt,
       area, prioridade, status, situacao, prazo, dias_para_prazo, atrasada,
       pendencias_abertas, aguardando, pasta_cliente, caminho_arquivos
FROM vw_tarefas
WHERE status NOT IN ('concluida', 'cancelada')
ORDER BY responsavel_email,
         (situacao = 'Bloqueada'),       -- primeiro o que pode ser feito agora
         atrasada DESC,
         ordem_prioridade,
         prazo NULLS LAST;

CREATE OR REPLACE FUNCTION fn_minhas_tarefas(p_email TEXT)
RETURNS SETOF vw_minhas_tarefas LANGUAGE sql STABLE AS $$
    SELECT * FROM vw_minhas_tarefas WHERE lower(responsavel_email) = lower(p_email);
$$;

-- "Quem está esperando por mim": tarefas de colegas travadas por minha causa.
CREATE OR REPLACE FUNCTION fn_aguardando_por_mim(p_email TEXT)
RETURNS SETOF vw_pendencias_abertas LANGUAGE sql STABLE AS $$
    SELECT * FROM vw_pendencias_abertas
     WHERE lower(bloqueador_email) = lower(p_email)
     ORDER BY prazo_tarefa NULLS LAST, pendente_desde;
$$;

-- =============================================================================
-- VISÕES DO GESTOR
-- =============================================================================

-- Toda tarefa concluída: quem concluiu, quando, se foi no prazo, quanto demorou.
CREATE OR REPLACE VIEW vw_gestor_conclusoes AS
SELECT
    t.tarefa_id, t.titulo, t.cliente, t.area, t.competencia_txt,
    t.responsavel, t.responsavel_modalidade, t.concluido_por,
    t.criado_em, t.iniciado_em, t.concluido_em,
    t.concluido_em::date                                          AS data_conclusao,
    t.prazo,
    t.concluida_no_prazo,
    GREATEST(t.concluido_em::date - t.prazo, 0)                   AS dias_atraso_na_entrega,
    round(EXTRACT(EPOCH FROM (t.concluido_em - t.iniciado_em)) / 3600.0, 1)
                                                                  AS horas_inicio_a_conclusao,
    (t.concluido_em::date - t.criado_em::date)                    AS dias_criacao_a_conclusao,
    (SELECT count(*) FROM tarefa_dependencias d WHERE d.tarefa_id = t.tarefa_id)
                                                                  AS qtd_pendencias_que_teve,
    t.caminho_arquivos
FROM vw_tarefas t
WHERE t.status = 'concluida';

-- Painel por colaborador
CREATE OR REPLACE VIEW vw_gestor_resumo_usuario AS
SELECT
    u.id                                                                   AS usuario_id,
    u.nome, u.email, u.area, u.modalidade,
    count(*) FILTER (WHERE t.status NOT IN ('concluida','cancelada'))      AS em_aberto,
    count(*) FILTER (WHERE t.status = 'em_andamento')                      AS em_andamento,
    count(*) FILTER (WHERE t.situacao = 'Bloqueada')                       AS bloqueadas,
    count(*) FILTER (WHERE t.atrasada)                                     AS atrasadas,
    count(*) FILTER (WHERE t.status = 'concluida'
                       AND date_trunc('month', t.concluido_em) = date_trunc('month', now()))
                                                                           AS concluidas_mes,
    count(*) FILTER (WHERE t.status = 'concluida'
                       AND date_trunc('month', t.concluido_em) = date_trunc('month', now())
                       AND t.concluida_no_prazo)                           AS concluidas_mes_no_prazo,
    round(100.0 * count(*) FILTER (WHERE t.concluida_no_prazo)
          / NULLIF(count(*) FILTER (WHERE t.concluida_no_prazo IS NOT NULL), 0), 1)
                                                                           AS pct_no_prazo_geral,
    max(t.concluido_em)                                                    AS ultima_conclusao,
    (SELECT max(h.ocorrido_em) FROM tarefa_historico h WHERE h.usuario_id = u.id)
                                                                           AS ultima_atividade,
    (SELECT count(*) FROM vw_pendencias_abertas p WHERE p.bloqueador_usuario_id = u.id)
                                                                           AS colegas_aguardando_ele
FROM usuarios u
LEFT JOIN vw_tarefas t ON t.responsavel_id = u.id
WHERE u.ativo
GROUP BY u.id, u.nome, u.email, u.area, u.modalidade;

-- Linha do tempo (auditoria): tudo o que aconteceu, por quem e quando
CREATE OR REPLACE VIEW vw_gestor_linha_tempo AS
SELECT
    h.id, h.ocorrido_em, h.ocorrido_em::date AS data,
    u.nome AS usuario, u.modalidade,
    h.tarefa_id, t.titulo, c.razao_social AS cliente,
    h.evento, h.status_anterior, h.status_novo, h.detalhe
FROM tarefa_historico h
JOIN tarefas t       ON t.id = h.tarefa_id
LEFT JOIN usuarios u ON u.id = h.usuario_id
LEFT JOIN clientes c ON c.id = t.cliente_id;

-- Gargalos: o que mais trava o escritório (por tipo e por quem/qual cliente)
CREATE OR REPLACE VIEW vw_gestor_gargalos AS
SELECT
    tipo_descricao,
    COALESCE(bloqueador_usuario,
             (SELECT razao_social FROM clientes WHERE id = bloqueador_cliente_id),
             'Externo')                       AS bloqueador,
    count(*)                                  AS tarefas_travadas,
    max(dias_pendente)                        AS maior_espera_dias,
    round(avg(dias_pendente), 1)              AS media_espera_dias,
    count(*) FILTER (WHERE prazo_tarefa < CURRENT_DATE) AS travadas_e_atrasadas
FROM vw_pendencias_abertas
GROUP BY 1, 2
ORDER BY tarefas_travadas DESC, maior_espera_dias DESC;
