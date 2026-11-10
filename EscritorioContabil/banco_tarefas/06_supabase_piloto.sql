-- =============================================================================
-- 06_supabase_piloto.sql : complemento para rodar no SUPABASE (após 01-04)
--   * libera a API só para usuários logados (visitante anônimo não vê nada)
--   * login só para e-mails já cadastrados em escritorio.usuarios
--   * datas e autoria carimbadas pelo sistema (ninguém forja conclusão/prazo)
-- No 01 do Supabase o RLS já é ligado na criação das tabelas.
-- =============================================================================
SET search_path TO escritorio, public;

-- ---------------------------------------------------------------- permissões da API
REVOKE ALL ON SCHEMA escritorio FROM PUBLIC, anon;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA escritorio FROM PUBLIC, anon;
GRANT USAGE ON SCHEMA escritorio TO authenticated;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA escritorio TO authenticated;
GRANT DELETE ON escritorio.tarefas TO authenticated;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA escritorio TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA escritorio TO authenticated;
REVOKE INSERT, UPDATE ON escritorio.tarefa_historico FROM authenticated;
REVOKE UPDATE ON escritorio.tarefa_comentarios FROM authenticated;

-- ---------------------------------------------------------------- login só para cadastrados
CREATE OR REPLACE FUNCTION escritorio.fn_auth_somente_cadastrados()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = escritorio, public AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM escritorio.usuarios WHERE lower(email) = lower(NEW.email) AND ativo) THEN
        RAISE EXCEPTION 'E-mail não autorizado. Peça ao gestor para cadastrar você.';
    END IF;
    RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION escritorio.fn_auth_vincular_usuario()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = escritorio, public AS $$
BEGIN
    UPDATE escritorio.usuarios SET auth_user_id = NEW.id
     WHERE lower(email) = lower(NEW.email) AND auth_user_id IS NULL;
    RETURN NEW;
END $$;
REVOKE EXECUTE ON FUNCTION escritorio.fn_auth_somente_cadastrados(), escritorio.fn_auth_vincular_usuario() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_escritorio_somente_cadastrados BEFORE INSERT ON auth.users
FOR EACH ROW EXECUTE FUNCTION escritorio.fn_auth_somente_cadastrados();
CREATE TRIGGER trg_escritorio_vincular_usuario AFTER INSERT ON auth.users
FOR EACH ROW EXECUTE FUNCTION escritorio.fn_auth_vincular_usuario();

-- ---------------------------------------------------------------- campos protegidos
CREATE OR REPLACE FUNCTION fn_carimbar_usuario_tarefa()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = escritorio, public AS $$
BEGIN
    IF auth.uid() IS NOT NULL THEN
        NEW.atualizado_por := fn_usuario_atual();
        IF TG_OP = 'INSERT' THEN
            NEW.criado_por := fn_usuario_atual(); NEW.criado_em := now(); NEW.status := 'a_fazer';
            NEW.iniciado_em := NULL; NEW.concluido_em := NULL; NEW.concluido_por := NULL;
        ELSE
            NEW.id := OLD.id; NEW.criado_por := OLD.criado_por; NEW.criado_em := OLD.criado_em;
            NEW.iniciado_em := OLD.iniciado_em; NEW.concluido_em := OLD.concluido_em; NEW.concluido_por := OLD.concluido_por;
            IF NOT fn_eh_gestor() THEN   -- só o gestor muda prazo, responsável, cliente...
                NEW.responsavel_id := OLD.responsavel_id; NEW.revisor_id := OLD.revisor_id;
                NEW.cliente_id := OLD.cliente_id; NEW.prazo := OLD.prazo; NEW.prioridade := OLD.prioridade;
                NEW.competencia := OLD.competencia; NEW.area := OLD.area; NEW.titulo := OLD.titulo;
            END IF;
        END IF;
    END IF;
    RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION fn_carimbar_usuario_dependencia()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = escritorio, public AS $$
BEGIN
    IF auth.uid() IS NOT NULL THEN
        IF TG_OP = 'INSERT' THEN
            NEW.criado_por := fn_usuario_atual(); NEW.criado_em := now(); NEW.cobrado_em := NULL;
            IF NEW.tipo <> 'tarefa' THEN NEW.resolvido_em := NULL; NEW.resolvido_por := NULL; END IF;
        ELSE   -- só pode: marcar como resolvida (agora) e registrar cobrança (agora)
            NEW.id := OLD.id; NEW.tarefa_id := OLD.tarefa_id; NEW.tipo := OLD.tipo;
            NEW.depende_tarefa_id := OLD.depende_tarefa_id; NEW.depende_cliente_id := OLD.depende_cliente_id;
            NEW.descricao := OLD.descricao; NEW.criado_em := OLD.criado_em; NEW.criado_por := OLD.criado_por;
            IF NEW.cobrado_em IS DISTINCT FROM OLD.cobrado_em THEN NEW.cobrado_em := now(); END IF;
            IF OLD.resolvido_em IS NOT NULL THEN
                NEW.resolvido_em := OLD.resolvido_em; NEW.resolvido_por := OLD.resolvido_por;
            ELSIF NEW.resolvido_em IS NOT NULL THEN
                NEW.resolvido_em := now(); NEW.resolvido_por := fn_usuario_atual();
            END IF;
            IF NOT fn_eh_gestor() THEN NEW.depende_usuario_id := OLD.depende_usuario_id; END IF;
        END IF;
    END IF;
    RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION fn_carimbar_comentario()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = escritorio, public AS $$
BEGIN
    IF auth.uid() IS NOT NULL THEN NEW.usuario_id := fn_usuario_atual(); NEW.criado_em := now(); END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER a_trg_carimbar_comentario BEFORE INSERT ON tarefa_comentarios
FOR EACH ROW EXECUTE FUNCTION fn_carimbar_comentario();

CREATE OR REPLACE FUNCTION fn_email_minusculo()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = escritorio, public AS $$
BEGIN NEW.email := lower(trim(NEW.email)); RETURN NEW; END $$;
CREATE TRIGGER a_trg_email_minusculo BEFORE INSERT OR UPDATE ON usuarios
FOR EACH ROW EXECUTE FUNCTION fn_email_minusculo();
REVOKE EXECUTE ON FUNCTION fn_carimbar_comentario(), fn_email_minusculo() FROM PUBLIC, anon;

-- ---------------------------------------------------------------- expõe o schema na API
ALTER ROLE authenticator SET pgrst.db_schemas = 'public, graphql_public, escritorio';
NOTIFY pgrst, 'reload config';

-- ---------------------------------------------------------------- área Legalização (bancos criados antes dela)
ALTER TYPE escritorio.area_escritorio ADD VALUE IF NOT EXISTS 'legalizacao' AFTER 'societario';

-- ---------------------------------------------------------------- só o gestor inclui, exclui ou cancela tarefas
DROP POLICY IF EXISTS tarefas_criar ON escritorio.tarefas;
CREATE POLICY tarefas_criar ON escritorio.tarefas FOR INSERT TO authenticated WITH CHECK (escritorio.fn_eh_gestor());

CREATE OR REPLACE FUNCTION escritorio.fn_bloquear_cancelamento()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = escritorio, public AS $$
BEGIN
    IF auth.uid() IS NOT NULL AND NOT fn_eh_gestor()
       AND NEW.status = 'cancelada' AND OLD.status IS DISTINCT FROM 'cancelada' THEN
        RAISE EXCEPTION 'Somente o gestor pode cancelar ou excluir tarefas.';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER b_trg_bloquear_cancelamento BEFORE UPDATE OF status ON escritorio.tarefas
FOR EACH ROW EXECUTE FUNCTION escritorio.fn_bloquear_cancelamento();
REVOKE EXECUTE ON FUNCTION escritorio.fn_bloquear_cancelamento() FROM PUBLIC, anon;
