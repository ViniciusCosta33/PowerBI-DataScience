-- =============================================================================
-- 02_regras_automaticas.sql : triggers e funções de operação
--
-- Regras automáticas:
--   1. Ao iniciar a tarefa, grava iniciado_em.
--   2. Ao concluir, grava concluido_em e concluido_por (quem concluiu).
--   3. NÃO permite concluir tarefa com dependência em aberto.
--   4. Toda mudança de status / responsável / prazo vai para o histórico.
--   5. Ao abrir uma dependência, a tarefa vai para 'aguardando'.
--   6. Ao concluir uma tarefa, as tarefas que dependiam dela são liberadas
--      automaticamente (e voltam para 'a_fazer' / 'em_andamento').
--   7. Impede dependência circular (A depende de B que depende de A).
-- =============================================================================
SET search_path TO escritorio, public;

-- -----------------------------------------------------------------------------
-- BEFORE INSERT/UPDATE em tarefas: carimbos de data/hora e validações
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_tarefas_before()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.atualizado_em := now();

    IF TG_OP = 'INSERT' THEN
        NEW.atualizado_por := COALESCE(NEW.atualizado_por, NEW.criado_por);
    END IF;

    IF TG_OP = 'INSERT' OR NEW.status IS DISTINCT FROM OLD.status THEN
        -- início do trabalho
        IF NEW.status IN ('em_andamento', 'em_revisao', 'concluida') AND NEW.iniciado_em IS NULL THEN
            NEW.iniciado_em := now();
        END IF;

        -- conclusão
        IF NEW.status = 'concluida' THEN
            IF TG_OP = 'UPDATE' AND EXISTS (
                SELECT 1 FROM tarefa_dependencias d
                 WHERE d.tarefa_id = NEW.id AND d.resolvido_em IS NULL
            ) THEN
                RAISE EXCEPTION 'Tarefa % possui dependências em aberto e não pode ser concluída.', NEW.id
                    USING HINT = 'Resolva as pendências (vw_pendencias_abertas) antes de concluir.';
            END IF;
            NEW.concluido_em  := COALESCE(NEW.concluido_em, now());
            NEW.concluido_por := COALESCE(NEW.atualizado_por, NEW.responsavel_id);
        ELSIF TG_OP = 'UPDATE' AND OLD.status = 'concluida' THEN
            -- tarefa reaberta: limpa a conclusão (o histórico mantém o registro anterior)
            NEW.concluido_em  := NULL;
            NEW.concluido_por := NULL;
        END IF;
    END IF;

    RETURN NEW;
END $$;

CREATE TRIGGER trg_tarefas_before
BEFORE INSERT OR UPDATE ON tarefas
FOR EACH ROW EXECUTE FUNCTION fn_tarefas_before();

-- -----------------------------------------------------------------------------
-- AFTER INSERT/UPDATE em tarefas: histórico + liberação de dependentes
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_tarefas_after()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO tarefa_historico (tarefa_id, usuario_id, evento, status_novo, detalhe)
        VALUES (NEW.id, NEW.criado_por, 'criada', NEW.status,
                'Atribuída a usuário ' || NEW.responsavel_id);
        RETURN NEW;
    END IF;

    IF NEW.status IS DISTINCT FROM OLD.status THEN
        INSERT INTO tarefa_historico (tarefa_id, usuario_id, evento, status_anterior, status_novo)
        VALUES (NEW.id, NEW.atualizado_por, 'status', OLD.status, NEW.status);

        -- Concluiu? Libera automaticamente quem dependia desta tarefa.
        IF NEW.status = 'concluida' THEN
            UPDATE tarefa_dependencias
               SET resolvido_em  = now(),
                   resolvido_por = NEW.concluido_por
             WHERE depende_tarefa_id = NEW.id
               AND resolvido_em IS NULL;
        END IF;
    END IF;

    IF NEW.responsavel_id IS DISTINCT FROM OLD.responsavel_id THEN
        INSERT INTO tarefa_historico (tarefa_id, usuario_id, evento, detalhe)
        VALUES (NEW.id, NEW.atualizado_por, 'reatribuida',
                format('Responsável: %s -> %s', OLD.responsavel_id, NEW.responsavel_id));

        -- quem espera por esta tarefa passa a esperar pelo novo responsável
        UPDATE tarefa_dependencias
           SET depende_usuario_id = NEW.responsavel_id
         WHERE depende_tarefa_id = NEW.id AND tipo = 'tarefa' AND resolvido_em IS NULL;
    END IF;

    IF NEW.prazo IS DISTINCT FROM OLD.prazo THEN
        INSERT INTO tarefa_historico (tarefa_id, usuario_id, evento, detalhe)
        VALUES (NEW.id, NEW.atualizado_por, 'prazo_alterado',
                format('Prazo: %s -> %s', OLD.prazo, NEW.prazo));
    END IF;

    RETURN NEW;
END $$;

CREATE TRIGGER trg_tarefas_after
AFTER INSERT OR UPDATE ON tarefas
FOR EACH ROW EXECUTE FUNCTION fn_tarefas_after();

-- -----------------------------------------------------------------------------
-- BEFORE INSERT em dependências: valida ciclo / já resolvida
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_dependencias_before()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_status status_tarefa;
BEGIN
    IF NEW.tipo = 'tarefa' THEN
        -- dependência circular: a tarefa de quem dependo já depende (direta ou
        -- indiretamente) de mim?
        IF EXISTS (
            WITH RECURSIVE cadeia(id) AS (
                SELECT d.depende_tarefa_id FROM tarefa_dependencias d
                 WHERE d.tarefa_id = NEW.depende_tarefa_id AND d.tipo = 'tarefa'
                UNION
                SELECT d.depende_tarefa_id FROM tarefa_dependencias d
                  JOIN cadeia c ON d.tarefa_id = c.id
                 WHERE d.tipo = 'tarefa'
            )
            SELECT 1 FROM cadeia WHERE id = NEW.tarefa_id
        ) THEN
            RAISE EXCEPTION 'Dependência circular: tarefa % já depende (direta ou indiretamente) da tarefa %.',
                NEW.depende_tarefa_id, NEW.tarefa_id;
        END IF;

        -- a tarefa de que dependo já foi concluída? então nasce resolvida
        SELECT status INTO v_status FROM tarefas WHERE id = NEW.depende_tarefa_id;
        IF v_status = 'concluida' AND NEW.resolvido_em IS NULL THEN
            NEW.resolvido_em  := now();
            NEW.resolvido_por := NEW.criado_por;
        END IF;

        -- preenche "pessoa" automaticamente com o responsável da outra tarefa
        IF NEW.depende_usuario_id IS NULL THEN
            SELECT responsavel_id INTO NEW.depende_usuario_id
              FROM tarefas WHERE id = NEW.depende_tarefa_id;
        END IF;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_dependencias_before
BEFORE INSERT ON tarefa_dependencias
FOR EACH ROW EXECUTE FUNCTION fn_dependencias_before();

-- -----------------------------------------------------------------------------
-- AFTER INSERT/UPDATE em dependências: muda status da tarefa e registra histórico
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_dependencias_after()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_tarefa tarefas%ROWTYPE;
    v_abertas INT;
BEGIN
    SELECT * INTO v_tarefa FROM tarefas WHERE id = NEW.tarefa_id;
    SELECT count(*) INTO v_abertas
      FROM tarefa_dependencias WHERE tarefa_id = NEW.tarefa_id AND resolvido_em IS NULL;

    IF TG_OP = 'INSERT' THEN
        INSERT INTO tarefa_historico (tarefa_id, usuario_id, evento, detalhe)
        VALUES (NEW.tarefa_id, NEW.criado_por, 'dependencia_aberta',
                format('[%s] %s', NEW.tipo, NEW.descricao));

        IF NEW.resolvido_em IS NULL AND v_tarefa.status IN ('a_fazer', 'em_andamento') THEN
            UPDATE tarefas SET status = 'aguardando', atualizado_por = NEW.criado_por
             WHERE id = NEW.tarefa_id;
        END IF;

    ELSIF NEW.resolvido_em IS NOT NULL AND OLD.resolvido_em IS NULL THEN
        INSERT INTO tarefa_historico (tarefa_id, usuario_id, evento, detalhe)
        VALUES (NEW.tarefa_id, NEW.resolvido_por, 'dependencia_resolvida',
                format('[%s] %s', NEW.tipo, NEW.descricao));

        -- sem mais pendências: tarefa volta para a fila do responsável
        IF v_abertas = 0 AND v_tarefa.status = 'aguardando' THEN
            UPDATE tarefas
               SET status = CASE WHEN iniciado_em IS NULL THEN 'a_fazer'::status_tarefa
                                 ELSE 'em_andamento'::status_tarefa END,
                   atualizado_por = NEW.resolvido_por
             WHERE id = NEW.tarefa_id;
        END IF;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_dependencias_after
AFTER INSERT OR UPDATE ON tarefa_dependencias
FOR EACH ROW EXECUTE FUNCTION fn_dependencias_after();

-- =============================================================================
-- FUNÇÕES DE OPERAÇÃO (a "API" usada pelo app / Power Apps / Supabase RPC)
-- Sempre recebem o usuário que está executando a ação => rastreabilidade.
-- =============================================================================

-- Quem está executando a ação. Sem login (rede local) = o usuário informado.
-- O arquivo 04_seguranca_rls.sql redefine esta função para usar SEMPRE o
-- usuário logado, impedindo registrar ações em nome de outra pessoa.
CREATE OR REPLACE FUNCTION fn_executor(p_usuario_id INT)
RETURNS INT LANGUAGE sql STABLE AS $$ SELECT p_usuario_id $$;

-- Muda o status (iniciar, enviar para revisão, cancelar, reabrir...)
CREATE OR REPLACE FUNCTION fn_alterar_status(
    p_tarefa_id INT, p_usuario_id INT, p_status status_tarefa, p_comentario TEXT DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    p_usuario_id := fn_executor(p_usuario_id);
    UPDATE tarefas SET status = p_status, atualizado_por = p_usuario_id WHERE id = p_tarefa_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Tarefa % não encontrada.', p_tarefa_id;
    END IF;
    IF p_comentario IS NOT NULL THEN
        INSERT INTO tarefa_comentarios (tarefa_id, usuario_id, texto)
        VALUES (p_tarefa_id, p_usuario_id, p_comentario);
    END IF;
END $$;

-- Conclui a tarefa registrando onde está o arquivo entregue
CREATE OR REPLACE FUNCTION fn_concluir_tarefa(
    p_tarefa_id INT, p_usuario_id INT,
    p_caminho_arquivos TEXT DEFAULT NULL, p_comentario TEXT DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    p_usuario_id := fn_executor(p_usuario_id);
    UPDATE tarefas
       SET status = 'concluida',
           atualizado_por = p_usuario_id,
           caminho_arquivos = COALESCE(p_caminho_arquivos, caminho_arquivos)
     WHERE id = p_tarefa_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Tarefa % não encontrada.', p_tarefa_id;
    END IF;
    IF p_comentario IS NOT NULL THEN
        INSERT INTO tarefa_comentarios (tarefa_id, usuario_id, texto)
        VALUES (p_tarefa_id, p_usuario_id, p_comentario);
    END IF;
END $$;

-- Registra uma pendência. p_referencia_id = id da tarefa / usuário / cliente,
-- conforme o tipo (ignorado para 'externo').
CREATE OR REPLACE FUNCTION fn_adicionar_dependencia(
    p_tarefa_id INT, p_usuario_id INT, p_tipo tipo_dependencia,
    p_referencia_id INT, p_descricao TEXT)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE
    v_id INT;
BEGIN
    p_usuario_id := fn_executor(p_usuario_id);
    INSERT INTO tarefa_dependencias
        (tarefa_id, tipo, depende_tarefa_id, depende_usuario_id, depende_cliente_id,
         descricao, criado_por)
    VALUES
        (p_tarefa_id, p_tipo,
         CASE WHEN p_tipo = 'tarefa'  THEN p_referencia_id END,
         CASE WHEN p_tipo = 'pessoa'  THEN p_referencia_id END,
         CASE WHEN p_tipo = 'cliente' THEN p_referencia_id END,
         p_descricao, p_usuario_id)
    RETURNING id INTO v_id;
    RETURN v_id;
END $$;

-- Marca uma pendência como resolvida (ex.: cliente enviou o extrato)
CREATE OR REPLACE FUNCTION fn_resolver_dependencia(
    p_dependencia_id INT, p_usuario_id INT, p_comentario TEXT DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_tarefa INT;
BEGIN
    p_usuario_id := fn_executor(p_usuario_id);
    UPDATE tarefa_dependencias
       SET resolvido_em = now(), resolvido_por = p_usuario_id
     WHERE id = p_dependencia_id AND resolvido_em IS NULL
    RETURNING tarefa_id INTO v_tarefa;
    IF v_tarefa IS NULL THEN
        RAISE EXCEPTION 'Dependência % não encontrada ou já resolvida.', p_dependencia_id;
    END IF;
    IF p_comentario IS NOT NULL THEN
        INSERT INTO tarefa_comentarios (tarefa_id, usuario_id, texto)
        VALUES (v_tarefa, p_usuario_id, p_comentario);
    END IF;
END $$;

-- Registra que a pendência foi cobrada (cliente / colega / órgão)
CREATE OR REPLACE FUNCTION fn_registrar_cobranca(p_dependencia_id INT, p_usuario_id INT)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_dep tarefa_dependencias%ROWTYPE;
BEGIN
    p_usuario_id := fn_executor(p_usuario_id);
    UPDATE tarefa_dependencias SET cobrado_em = now()
     WHERE id = p_dependencia_id AND resolvido_em IS NULL
    RETURNING * INTO v_dep;
    IF v_dep.id IS NULL THEN
        RAISE EXCEPTION 'Dependência % não encontrada ou já resolvida.', p_dependencia_id;
    END IF;
    INSERT INTO tarefa_historico (tarefa_id, usuario_id, evento, detalhe)
    VALUES (v_dep.tarefa_id, p_usuario_id, 'cobranca', format('[%s] %s', v_dep.tipo, v_dep.descricao));
END $$;
