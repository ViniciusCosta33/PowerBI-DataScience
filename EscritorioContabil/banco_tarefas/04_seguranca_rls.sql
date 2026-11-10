-- =============================================================================
-- 04_seguranca_rls.sql  (OPCIONAL - recomendado quando o banco está na nuvem,
--                        ex.: Supabase, e cada pessoa acessa com o próprio login)
--
-- Row Level Security:
--   * GESTOR       -> vê e altera tudo.
--   * COLABORADOR  -> vê as tarefas em que é responsável, revisor ou criador,
--                     e as tarefas de colegas que estão esperando por ele.
--   * O usuário que executa a ação é SEMPRE o usuário logado (não dá para
--     concluir uma tarefa "em nome" de outra pessoa) => histórico confiável.
--
-- Pré-requisito: função auth.uid() (nativa no Supabase) e a coluna
-- usuarios.auth_user_id preenchida com o id de login de cada pessoa.
-- =============================================================================
SET search_path TO escritorio, public;

-- -----------------------------------------------------------------------------
-- Funções auxiliares
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_usuario_atual()
RETURNS INT LANGUAGE sql STABLE SECURITY DEFINER SET search_path = escritorio, public AS $$
    SELECT id FROM escritorio.usuarios WHERE auth_user_id = auth.uid() AND ativo;
$$;

CREATE OR REPLACE FUNCTION fn_eh_gestor()
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = escritorio, public AS $$
    SELECT EXISTS (SELECT 1 FROM escritorio.usuarios
                    WHERE auth_user_id = auth.uid() AND perfil = 'gestor' AND ativo);
$$;

-- Pode ver a tarefa? (SECURITY DEFINER evita recursão entre políticas)
CREATE OR REPLACE FUNCTION fn_pode_ver_tarefa(p_tarefa_id INT)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = escritorio, public AS $$
    SELECT fn_eh_gestor()
        OR EXISTS (SELECT 1 FROM escritorio.tarefas t
                    WHERE t.id = p_tarefa_id
                      AND fn_usuario_atual() IN (t.responsavel_id, t.revisor_id, t.criado_por))
        OR EXISTS (SELECT 1 FROM escritorio.tarefa_dependencias d
                    WHERE d.tarefa_id = p_tarefa_id
                      AND d.depende_usuario_id = fn_usuario_atual());
$$;

-- Funções de operação passam a usar o usuário logado
CREATE OR REPLACE FUNCTION fn_executor(p_usuario_id INT)
RETURNS INT LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN auth.uid() IS NULL THEN p_usuario_id ELSE fn_usuario_atual() END;
$$;

-- -----------------------------------------------------------------------------
-- Carimbo do usuário logado (anti "concluir em nome de outro")
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_carimbar_usuario_tarefa()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF auth.uid() IS NOT NULL THEN
        NEW.atualizado_por := fn_usuario_atual();
        IF TG_OP = 'INSERT' THEN NEW.criado_por := fn_usuario_atual(); END IF;
    END IF;
    RETURN NEW;
END $$;

-- nome começa com "a" para rodar ANTES de trg_tarefas_before (ordem alfabética)
CREATE TRIGGER a_trg_carimbar_usuario_tarefa
BEFORE INSERT OR UPDATE ON tarefas
FOR EACH ROW EXECUTE FUNCTION fn_carimbar_usuario_tarefa();

CREATE OR REPLACE FUNCTION fn_carimbar_usuario_dependencia()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF auth.uid() IS NOT NULL THEN
        IF TG_OP = 'INSERT' THEN
            NEW.criado_por := fn_usuario_atual();
        ELSIF NEW.resolvido_em IS NOT NULL AND OLD.resolvido_em IS NULL THEN
            NEW.resolvido_por := fn_usuario_atual();
        END IF;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER a_trg_carimbar_usuario_dependencia
BEFORE INSERT OR UPDATE ON tarefa_dependencias
FOR EACH ROW EXECUTE FUNCTION fn_carimbar_usuario_dependencia();

-- Triggers internos precisam gravar histórico / liberar tarefas de colegas
-- mesmo que o usuário não tenha permissão direta nessas linhas.
ALTER FUNCTION fn_tarefas_after()       SECURITY DEFINER;
ALTER FUNCTION fn_dependencias_before() SECURITY DEFINER;
ALTER FUNCTION fn_dependencias_after()  SECURITY DEFINER;
ALTER FUNCTION fn_tarefas_after()       SET search_path = escritorio, public;
ALTER FUNCTION fn_dependencias_before() SET search_path = escritorio, public;
ALTER FUNCTION fn_dependencias_after()  SET search_path = escritorio, public;

-- -----------------------------------------------------------------------------
-- Habilita RLS
-- -----------------------------------------------------------------------------
ALTER TABLE usuarios            ENABLE ROW LEVEL SECURITY;
ALTER TABLE clientes            ENABLE ROW LEVEL SECURITY;
ALTER TABLE tarefas             ENABLE ROW LEVEL SECURITY;
ALTER TABLE tarefa_dependencias ENABLE ROW LEVEL SECURITY;
ALTER TABLE tarefa_historico    ENABLE ROW LEVEL SECURITY;
ALTER TABLE tarefa_comentarios  ENABLE ROW LEVEL SECURITY;

-- usuários e clientes: todos leem (para ver nomes); só gestor altera
CREATE POLICY usuarios_ler     ON usuarios FOR SELECT USING (fn_usuario_atual() IS NOT NULL);
CREATE POLICY usuarios_gestor  ON usuarios FOR ALL    USING (fn_eh_gestor()) WITH CHECK (fn_eh_gestor());
CREATE POLICY clientes_ler     ON clientes FOR SELECT USING (fn_usuario_atual() IS NOT NULL);
CREATE POLICY clientes_gestor  ON clientes FOR ALL    USING (fn_eh_gestor()) WITH CHECK (fn_eh_gestor());

-- tarefas
CREATE POLICY tarefas_ler      ON tarefas FOR SELECT USING (fn_pode_ver_tarefa(id));
CREATE POLICY tarefas_criar    ON tarefas FOR INSERT WITH CHECK (fn_usuario_atual() IS NOT NULL);
CREATE POLICY tarefas_alterar  ON tarefas FOR UPDATE
    USING (fn_eh_gestor() OR fn_usuario_atual() IN (responsavel_id, revisor_id))
    WITH CHECK (fn_eh_gestor() OR fn_usuario_atual() IN (responsavel_id, revisor_id));
CREATE POLICY tarefas_excluir  ON tarefas FOR DELETE USING (fn_eh_gestor());

-- dependências: quem vê a tarefa vê/cria; quem é cobrado também pode resolver
CREATE POLICY dep_ler      ON tarefa_dependencias FOR SELECT USING (fn_pode_ver_tarefa(tarefa_id));
CREATE POLICY dep_criar    ON tarefa_dependencias FOR INSERT WITH CHECK (fn_pode_ver_tarefa(tarefa_id));
CREATE POLICY dep_alterar  ON tarefa_dependencias FOR UPDATE USING (fn_pode_ver_tarefa(tarefa_id));

-- histórico: somente leitura (gravado pelos triggers)
CREATE POLICY hist_ler     ON tarefa_historico FOR SELECT USING (fn_pode_ver_tarefa(tarefa_id));

-- comentários
CREATE POLICY coment_ler   ON tarefa_comentarios FOR SELECT USING (fn_pode_ver_tarefa(tarefa_id));
CREATE POLICY coment_criar ON tarefa_comentarios FOR INSERT
    WITH CHECK (fn_pode_ver_tarefa(tarefa_id) AND usuario_id = fn_usuario_atual());

-- Views respeitam o RLS de quem consulta (PostgreSQL 15+)
ALTER VIEW vw_pendencias_abertas    SET (security_invoker = true);
ALTER VIEW vw_tarefas               SET (security_invoker = true);
ALTER VIEW vw_minhas_tarefas        SET (security_invoker = true);
ALTER VIEW vw_gestor_conclusoes     SET (security_invoker = true);
ALTER VIEW vw_gestor_resumo_usuario SET (security_invoker = true);
ALTER VIEW vw_gestor_linha_tempo    SET (security_invoker = true);
ALTER VIEW vw_gestor_gargalos       SET (security_invoker = true);
