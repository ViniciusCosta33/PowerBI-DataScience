-- =============================================================================
-- 07_tarefas_recorrentes.sql : tarefas que se repetem (agenda regular)
--   Um "modelo" (tarefas_recorrentes) gera uma tarefa normal a cada vencimento,
--   N dias antes. Roda todo dia via pg_cron (Supabase) e na hora em que o
--   modelo é criado ou retomado. Rodar após 01-06.
-- =============================================================================
SET search_path TO escritorio, public;

CREATE TYPE periodicidade_tarefa AS ENUM ('semanal','quinzenal','mensal','bimestral','trimestral','semestral','anual');
CREATE TYPE regra_competencia   AS ENUM ('mes_anterior','mesmo_mes','sem_competencia');
CREATE TYPE ajuste_fim_semana   AS ENUM ('manter','antecipar','adiar');

CREATE TABLE tarefas_recorrentes (
    id                  SERIAL PRIMARY KEY,
    titulo              VARCHAR(200) NOT NULL,
    descricao           TEXT,
    cliente_id          INT REFERENCES clientes(id),
    area                area_escritorio NOT NULL,
    responsavel_id      INT NOT NULL REFERENCES usuarios(id),
    revisor_id          INT REFERENCES usuarios(id),
    prioridade          prioridade_tarefa NOT NULL DEFAULT 'media',
    periodicidade       periodicidade_tarefa NOT NULL,
    primeiro_vencimento DATE NOT NULL,                       -- define o dia (ex.: todo dia 20)
    antecedencia_dias   INT NOT NULL DEFAULT 10 CHECK (antecedencia_dias BETWEEN 0 AND 90),
    competencia_regra   regra_competencia NOT NULL DEFAULT 'mes_anterior',
    fim_de_semana       ajuste_fim_semana NOT NULL DEFAULT 'manter',
    data_fim            DATE,
    ativo               BOOLEAN NOT NULL DEFAULT TRUE,
    proxima_ocorrencia  INT NOT NULL DEFAULT 0,
    ultima_geracao      TIMESTAMPTZ,
    criado_por          INT REFERENCES usuarios(id),
    criado_em           TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE tarefas ADD COLUMN recorrencia_id INT REFERENCES tarefas_recorrentes(id) ON DELETE SET NULL;
CREATE UNIQUE INDEX ux_tarefas_recorrencia_prazo ON tarefas (recorrencia_id, prazo) WHERE recorrencia_id IS NOT NULL;

-- Vencimento da n-ésima ocorrência, sempre calculado a partir do primeiro
-- (dia 31 não "escorrega" para 30/28 de vez)
CREATE OR REPLACE FUNCTION fn_vencimento_recorrencia(p_inicio DATE, p_per periodicidade_tarefa, p_n INT, p_aj ajuste_fim_semana)
RETURNS DATE LANGUAGE plpgsql IMMUTABLE SET search_path = escritorio, public AS $$
DECLARE v DATE; dow INT;
BEGIN
    v := CASE p_per
        WHEN 'semanal'    THEN p_inicio + 7 * p_n
        WHEN 'quinzenal'  THEN p_inicio + 14 * p_n
        WHEN 'mensal'     THEN (p_inicio + make_interval(months => p_n))::date
        WHEN 'bimestral'  THEN (p_inicio + make_interval(months => 2 * p_n))::date
        WHEN 'trimestral' THEN (p_inicio + make_interval(months => 3 * p_n))::date
        WHEN 'semestral'  THEN (p_inicio + make_interval(months => 6 * p_n))::date
        WHEN 'anual'      THEN (p_inicio + make_interval(years => p_n))::date
    END;
    dow := EXTRACT(ISODOW FROM v);   -- 6 = sábado, 7 = domingo
    IF dow >= 6 AND p_aj = 'antecipar' THEN v := v - (dow - 5);
    ELSIF dow >= 6 AND p_aj = 'adiar' THEN v := v + (8 - dow);
    END IF;
    RETURN v;
END $$;

CREATE OR REPLACE FUNCTION fn_gerar_tarefas_recorrentes(p_id INT DEFAULT NULL)
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER SET search_path = escritorio, public AS $$
DECLARE
    r tarefas_recorrentes%ROWTYPE; v DATE; comp DATE; n INT := 0; guarda INT;
BEGIN
    PERFORM set_config('escritorio.gerador', 'on', true);   -- só o gerador avança o contador
    FOR r IN SELECT * FROM tarefas_recorrentes
              WHERE ativo AND (p_id IS NULL OR id = p_id)
              ORDER BY id FOR UPDATE SKIP LOCKED
    LOOP
        guarda := 0;
        LOOP
            v := fn_vencimento_recorrencia(r.primeiro_vencimento, r.periodicidade, r.proxima_ocorrencia, r.fim_de_semana);
            EXIT WHEN v - r.antecedencia_dias > current_date;      -- ainda não é hora
            IF r.data_fim IS NOT NULL AND v > r.data_fim THEN
                UPDATE tarefas_recorrentes SET ativo = FALSE WHERE id = r.id;
                EXIT;
            END IF;
            comp := CASE r.competencia_regra
                        WHEN 'mes_anterior' THEN (date_trunc('month', v) - interval '1 month')::date
                        WHEN 'mesmo_mes'    THEN date_trunc('month', v)::date
                    END;
            INSERT INTO tarefas (titulo, descricao, cliente_id, area, competencia, responsavel_id, revisor_id,
                                 criado_por, prioridade, prazo, recorrencia_id)
            VALUES (r.titulo, r.descricao, r.cliente_id, r.area, comp, r.responsavel_id, r.revisor_id,
                    COALESCE(r.criado_por, r.responsavel_id), r.prioridade, v, r.id)
            ON CONFLICT (recorrencia_id, prazo) WHERE recorrencia_id IS NOT NULL DO NOTHING;
            IF FOUND THEN n := n + 1; END IF;
            r.proxima_ocorrencia := r.proxima_ocorrencia + 1;
            UPDATE tarefas_recorrentes SET proxima_ocorrencia = r.proxima_ocorrencia, ultima_geracao = now() WHERE id = r.id;
            guarda := guarda + 1;
            EXIT WHEN guarda >= 60;
        END LOOP;
    END LOOP;
    PERFORM set_config('escritorio.gerador', 'off', true);
    RETURN n;
END $$;

CREATE OR REPLACE FUNCTION fn_recorrente_after()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = escritorio, public AS $$
BEGIN
    PERFORM fn_gerar_tarefas_recorrentes(NEW.id);
    RETURN NEW;
END $$;
CREATE TRIGGER trg_recorrente_insert AFTER INSERT ON tarefas_recorrentes
FOR EACH ROW EXECUTE FUNCTION fn_recorrente_after();
CREATE TRIGGER trg_recorrente_retomar AFTER UPDATE OF ativo ON tarefas_recorrentes
FOR EACH ROW WHEN (NEW.ativo AND NOT OLD.ativo) EXECUTE FUNCTION fn_recorrente_after();

CREATE OR REPLACE FUNCTION fn_carimbar_recorrente()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = escritorio, public AS $$
BEGIN
    IF auth.uid() IS NOT NULL AND COALESCE(current_setting('escritorio.gerador', true), '') <> 'on' THEN
        IF TG_OP = 'INSERT' THEN
            NEW.criado_por := fn_usuario_atual(); NEW.criado_em := now();
            NEW.proxima_ocorrencia := 0; NEW.ultima_geracao := NULL;
        ELSE
            NEW.id := OLD.id; NEW.criado_por := OLD.criado_por; NEW.criado_em := OLD.criado_em;
            NEW.primeiro_vencimento := OLD.primeiro_vencimento; NEW.periodicidade := OLD.periodicidade;
            NEW.proxima_ocorrencia := OLD.proxima_ocorrencia; NEW.ultima_geracao := OLD.ultima_geracao;
        END IF;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER a_trg_carimbar_recorrente BEFORE INSERT OR UPDATE ON tarefas_recorrentes
FOR EACH ROW EXECUTE FUNCTION fn_carimbar_recorrente();

ALTER TABLE tarefas_recorrentes ENABLE ROW LEVEL SECURITY;
CREATE POLICY rec_ler    ON tarefas_recorrentes FOR SELECT TO authenticated
    USING (fn_eh_gestor() OR responsavel_id = fn_usuario_atual());
CREATE POLICY rec_gestor ON tarefas_recorrentes FOR ALL TO authenticated
    USING (fn_eh_gestor()) WITH CHECK (fn_eh_gestor());
GRANT SELECT, INSERT, UPDATE ON tarefas_recorrentes TO authenticated;
GRANT USAGE ON SEQUENCE tarefas_recorrentes_id_seq TO authenticated;
REVOKE EXECUTE ON FUNCTION fn_recorrente_after(), fn_carimbar_recorrente() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION fn_gerar_tarefas_recorrentes(INT),
                           fn_vencimento_recorrencia(DATE, periodicidade_tarefa, INT, ajuste_fim_semana) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION fn_gerar_tarefas_recorrentes(INT),
                          fn_vencimento_recorrencia(DATE, periodicidade_tarefa, INT, ajuste_fim_semana) TO authenticated;

-- vw_tarefas ganha recorrencia_id e periodicidade (colunas no fim)
CREATE OR REPLACE VIEW vw_tarefas WITH (security_invoker = true) AS
WITH dep AS (
    SELECT tarefa_id, count(*) AS pendencias_abertas,
        count(*) FILTER (WHERE tipo = 'tarefa') AS pend_tarefa,
        count(*) FILTER (WHERE tipo = 'pessoa') AS pend_pessoa,
        count(*) FILTER (WHERE tipo = 'cliente') AS pend_cliente,
        count(*) FILTER (WHERE tipo = 'externo') AS pend_externo,
        string_agg(tipo_descricao || ': ' || bloqueado_por || ' - ' || o_que_falta, ' | ' ORDER BY pendente_desde) AS aguardando
    FROM vw_pendencias_abertas GROUP BY tarefa_id
)
SELECT
    t.id AS tarefa_id, t.titulo, t.descricao, t.area, t.competencia,
    to_char(t.competencia, 'MM/YYYY') AS competencia_txt,
    c.id AS cliente_id, c.codigo AS cliente_codigo, COALESCE(c.razao_social, '(interna)') AS cliente,
    u.id AS responsavel_id, u.nome AS responsavel, u.email AS responsavel_email, u.modalidade AS responsavel_modalidade,
    rv.nome AS revisor, t.prioridade, t.status,
    CASE WHEN t.status = 'concluida' THEN 'Concluída' WHEN t.status = 'cancelada' THEN 'Cancelada'
         WHEN COALESCE(dep.pendencias_abertas,0) > 0 THEN 'Bloqueada' WHEN t.status = 'em_revisao' THEN 'Em revisão'
         WHEN t.status = 'em_andamento' THEN 'Em andamento' ELSE 'Liberada para iniciar' END AS situacao,
    COALESCE(dep.pendencias_abertas, 0) AS pendencias_abertas, COALESCE(dep.pend_tarefa, 0) AS pend_outra_tarefa,
    COALESCE(dep.pend_pessoa, 0) AS pend_colega, COALESCE(dep.pend_cliente, 0) AS pend_cliente,
    COALESCE(dep.pend_externo, 0) AS pend_externo, dep.aguardando, t.prazo,
    CASE WHEN t.status NOT IN ('concluida','cancelada') THEN t.prazo - CURRENT_DATE END AS dias_para_prazo,
    (t.status NOT IN ('concluida','cancelada') AND t.prazo < CURRENT_DATE) AS atrasada,
    t.criado_em, cr.nome AS criado_por, t.iniciado_em, t.concluido_em, cp.nome AS concluido_por,
    CASE WHEN t.status = 'concluida' AND t.prazo IS NOT NULL THEN t.concluido_em::date <= t.prazo END AS concluida_no_prazo,
    t.atualizado_em, t.caminho_arquivos, c.pasta_arquivos AS pasta_cliente,
    CASE t.prioridade WHEN 'urgente' THEN 1 WHEN 'alta' THEN 2 WHEN 'media' THEN 3 ELSE 4 END AS ordem_prioridade,
    t.recorrencia_id, rec.periodicidade
FROM tarefas t
JOIN usuarios u       ON u.id  = t.responsavel_id
JOIN usuarios cr      ON cr.id = t.criado_por
LEFT JOIN usuarios rv ON rv.id = t.revisor_id
LEFT JOIN usuarios cp ON cp.id = t.concluido_por
LEFT JOIN clientes c  ON c.id  = t.cliente_id
LEFT JOIN tarefas_recorrentes rec ON rec.id = t.recorrencia_id
LEFT JOIN dep         ON dep.tarefa_id = t.id;

CREATE OR REPLACE VIEW vw_tarefas_recorrentes WITH (security_invoker = true) AS
SELECT r.id, r.titulo, r.descricao, r.area, r.prioridade, r.periodicidade, r.primeiro_vencimento,
       r.antecedencia_dias, r.competencia_regra, r.fim_de_semana, r.data_fim, r.ativo,
       r.cliente_id, c.codigo AS cliente_codigo, c.razao_social AS cliente,
       r.responsavel_id, u.nome AS responsavel,
       fn_vencimento_recorrencia(r.primeiro_vencimento, r.periodicidade, r.proxima_ocorrencia, r.fim_de_semana) AS proximo_vencimento,
       (SELECT count(*) FROM tarefas t WHERE t.recorrencia_id = r.id) AS tarefas_geradas,
       r.ultima_geracao, r.criado_em
FROM tarefas_recorrentes r
JOIN usuarios u ON u.id = r.responsavel_id
LEFT JOIN clientes c ON c.id = r.cliente_id;
GRANT SELECT ON vw_tarefas_recorrentes TO authenticated;

-- Agenda diária às 06:07 (Brasília) = 09:07 UTC. Requer pg_cron (nativo no Supabase).
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;
SELECT cron.schedule('escritorio-gerar-tarefas-recorrentes', '7 9 * * *',
                     $$SELECT escritorio.fn_gerar_tarefas_recorrentes()$$);
