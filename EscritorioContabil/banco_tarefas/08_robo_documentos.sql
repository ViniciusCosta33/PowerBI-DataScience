-- =============================================================================
-- 08_robo_documentos.sql : robô que lê PDFs, arquiva e dá baixa nas tarefas
--   O robô (robo_documentos/robo_documentos.py) roda no computador central e
--   chama só 2 funções do schema "robo", protegidas por uma chave gerada pelo
--   gestor no app. Nada mais do banco fica acessível sem login.
-- =============================================================================
SET search_path TO escritorio, public;

-- Usuário técnico (autor das baixas automáticas). Inativo: não loga, não reativa.
INSERT INTO usuarios (nome, email, cargo, perfil, modalidade, ativo)
VALUES ('Robô de documentos', 'robo.documentos@interno.invalid', 'Automação', 'colaborador', 'presencial', FALSE);
ALTER TABLE usuarios ADD CONSTRAINT ck_usuario_tecnico_inativo
    CHECK (email NOT LIKE '%@interno.invalid' OR ativo = FALSE);

CREATE OR REPLACE FUNCTION fn_auth_somente_cadastrados()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = escritorio, public AS $$
BEGIN
    IF lower(NEW.email) LIKE '%@interno.invalid' OR NOT EXISTS (
        SELECT 1 FROM escritorio.usuarios WHERE lower(email) = lower(NEW.email) AND ativo) THEN
        RAISE EXCEPTION 'E-mail não autorizado. Peça ao gestor para cadastrar você.';
    END IF;
    RETURN NEW;
END $$;

CREATE TABLE integracao_tokens (
    id          SERIAL PRIMARY KEY,
    nome        VARCHAR(80) NOT NULL,
    token_hash  TEXT NOT NULL UNIQUE,
    criado_por  INT REFERENCES usuarios(id),
    criado_em   TIMESTAMPTZ NOT NULL DEFAULT now(),
    ultimo_uso  TIMESTAMPTZ,
    ativo       BOOLEAN NOT NULL DEFAULT TRUE
);
ALTER TABLE integracao_tokens ENABLE ROW LEVEL SECURITY;   -- sem políticas: ninguém lê pela API

CREATE TABLE robo_eventos (
    id              BIGSERIAL PRIMARY KEY,
    ocorrido_em     TIMESTAMPTZ NOT NULL DEFAULT now(),
    arquivo         VARCHAR(300) NOT NULL,
    tipo_documento  VARCHAR(60),
    cnpj            VARCHAR(20),
    cliente_id      INT REFERENCES clientes(id) ON DELETE SET NULL,
    tarefa_id       INT REFERENCES tarefas(id) ON DELETE SET NULL,
    resultado       VARCHAR(40) NOT NULL,
    detalhe         TEXT,
    caminho_destino VARCHAR(400)
);
ALTER TABLE robo_eventos ENABLE ROW LEVEL SECURITY;
CREATE POLICY robo_eventos_gestor ON robo_eventos FOR SELECT TO authenticated USING (fn_eh_gestor());
GRANT SELECT ON robo_eventos TO authenticated;

CREATE OR REPLACE FUNCTION fn_gerar_token_robo()
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER SET search_path = escritorio, public, extensions AS $$
DECLARE v_token TEXT;
BEGIN
    IF NOT fn_eh_gestor() THEN RAISE EXCEPTION 'Somente o gestor pode gerar a chave do robô.'; END IF;
    UPDATE integracao_tokens SET ativo = FALSE WHERE ativo;
    v_token := 'robo_' || encode(extensions.gen_random_bytes(24), 'hex');
    INSERT INTO integracao_tokens (nome, token_hash, criado_por)
    VALUES ('Robô de documentos', encode(extensions.digest(v_token, 'sha256'), 'hex'), fn_usuario_atual());
    RETURN v_token;
END $$;
REVOKE EXECUTE ON FUNCTION fn_gerar_token_robo() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION fn_gerar_token_robo() TO authenticated;

CREATE OR REPLACE FUNCTION fn_robo_token_ok(p_token TEXT)
RETURNS BOOLEAN LANGUAGE plpgsql SECURITY DEFINER SET search_path = escritorio, public, extensions AS $$
BEGIN
    UPDATE integracao_tokens SET ultimo_uso = now()
     WHERE ativo AND token_hash = encode(extensions.digest(COALESCE(p_token, ''), 'sha256'), 'hex');
    RETURN FOUND;
END $$;
REVOKE EXECUTE ON FUNCTION fn_robo_token_ok(TEXT) FROM PUBLIC, anon, authenticated;

CREATE SCHEMA robo;
REVOKE ALL ON SCHEMA robo FROM PUBLIC;
GRANT USAGE ON SCHEMA robo TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA robo REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA escritorio REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

-- 1) cliente pela raiz do CNPJ + tarefa aberta do tipo de documento
CREATE OR REPLACE FUNCTION robo.identificar(p_token TEXT, p_cnpj TEXT, p_tipo TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = escritorio, public AS $$
DECLARE
    v_raiz TEXT := left(regexp_replace(COALESCE(p_cnpj, ''), '\D', '', 'g'), 8);
    v_cli clientes%ROWTYPE; v_n INT; v_tar RECORD; v_qtd INT;
BEGIN
    IF NOT fn_robo_token_ok(p_token) THEN RAISE EXCEPTION 'Chave do robô inválida ou desativada.'; END IF;
    IF length(v_raiz) < 8 THEN RETURN jsonb_build_object('ok', false, 'motivo', 'CNPJ não encontrado no documento'); END IF;
    SELECT count(*) INTO v_n FROM clientes WHERE ativo AND left(regexp_replace(cnpj_cpf, '\D', '', 'g'), 8) = v_raiz;
    IF v_n = 0 THEN RETURN jsonb_build_object('ok', false, 'motivo', 'CNPJ ' || p_cnpj || ' não está cadastrado'); END IF;
    IF v_n > 1 THEN RETURN jsonb_build_object('ok', false, 'motivo', 'Mais de um cliente com a raiz de CNPJ ' || v_raiz); END IF;
    SELECT * INTO v_cli FROM clientes WHERE ativo AND left(regexp_replace(cnpj_cpf, '\D', '', 'g'), 8) = v_raiz;
    IF p_tipo = 'cnd_federal' THEN
        -- só tarefas que ainda esperam o documento (em revisão = documento já recebido)
        SELECT count(*) INTO v_qtd FROM tarefas t
         WHERE t.cliente_id = v_cli.id AND t.status NOT IN ('concluida', 'cancelada', 'em_revisao')
           AND upper(translate(t.titulo, 'ÁÀÃÂÉÊÍÓÔÕÚÇáàãâéêíóôõúç', 'AAAAEEIOOOUCaaaaeeiooouc')) ~ '(CND|CERTIDAO)';
        SELECT t.id, t.titulo, t.prazo INTO v_tar FROM tarefas t
         WHERE t.cliente_id = v_cli.id AND t.status NOT IN ('concluida', 'cancelada', 'em_revisao')
           AND upper(translate(t.titulo, 'ÁÀÃÂÉÊÍÓÔÕÚÇáàãâéêíóôõúç', 'AAAAEEIOOOUCaaaaeeiooouc')) ~ '(CND|CERTIDAO)'
         ORDER BY (upper(t.titulo) LIKE '%FEDERA%') DESC, t.prazo NULLS LAST, t.id
         LIMIT 1;
    END IF;
    RETURN jsonb_build_object('ok', true, 'cliente_id', v_cli.id, 'cliente_codigo', v_cli.codigo,
        'cliente_nome', v_cli.razao_social, 'pasta_cliente', v_cli.pasta_arquivos,
        'tarefa_id', v_tar.id, 'tarefa_titulo', v_tar.titulo, 'tarefas_candidatas', COALESCE(v_qtd, 0));
END $$;

-- 2) registra o resultado depois de mover o arquivo; dá a baixa quando cabe
CREATE OR REPLACE FUNCTION robo.registrar(
    p_token TEXT, p_arquivo TEXT, p_tipo TEXT, p_cnpj TEXT, p_cliente_id INT, p_tarefa_id INT,
    p_caminho TEXT, p_situacao TEXT, p_validade DATE, p_codigo TEXT, p_emissao DATE, p_status_baixa TEXT,
    p_motivo TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = escritorio, public AS $$
DECLARE
    v_robo INT; v_res TEXT; v_det TEXT; v_t tarefas%ROWTYPE; v_sit TEXT;
BEGIN
    IF NOT fn_robo_token_ok(p_token) THEN RAISE EXCEPTION 'Chave do robô inválida ou desativada.'; END IF;
    SELECT id INTO v_robo FROM usuarios WHERE email = 'robo.documentos@interno.invalid';
    v_sit := CASE p_situacao WHEN 'negativa' THEN 'Negativa' WHEN 'positiva_efeito_negativa' THEN 'Positiva com efeitos de negativa'
                             WHEN 'positiva' THEN 'POSITIVA (com débitos)' ELSE p_situacao END;
    v_det := concat_ws(' · ', 'CND federal ' || v_sit, 'emitida ' || to_char(p_emissao, 'DD/MM/YYYY'),
                       'válida até ' || to_char(p_validade, 'DD/MM/YYYY'), 'código ' || p_codigo, p_motivo);
    IF p_cliente_id IS NULL THEN
        v_res := CASE WHEN p_tipo IS NULL THEN 'nao_reconhecido' ELSE 'sem_cliente' END;
    ELSIF p_tarefa_id IS NULL THEN
        v_res := 'sem_tarefa';
    ELSE
        SELECT * INTO v_t FROM tarefas WHERE id = p_tarefa_id AND cliente_id = p_cliente_id;
        IF NOT FOUND OR v_t.status IN ('concluida', 'cancelada') THEN
            v_res := 'sem_tarefa';
        ELSE
            UPDATE tarefas SET caminho_arquivos = p_caminho, atualizado_por = v_robo WHERE id = v_t.id;
            INSERT INTO tarefa_comentarios (tarefa_id, usuario_id, texto)
            VALUES (v_t.id, v_robo, 'Documento recebido automaticamente: ' || p_arquivo || '. ' || v_det);
            IF p_situacao = 'positiva' THEN
                INSERT INTO tarefa_dependencias (tarefa_id, tipo, depende_cliente_id, descricao, criado_por)
                VALUES (v_t.id, 'cliente', p_cliente_id, 'CND federal POSITIVA: regularizar débitos federais antes de nova certidão', v_robo);
                v_res := 'cnd_positiva';
            ELSIF EXISTS (SELECT 1 FROM tarefa_dependencias WHERE tarefa_id = v_t.id AND resolvido_em IS NULL) THEN
                v_res := 'bloqueada';
            ELSE
                UPDATE tarefas SET status = CASE WHEN p_status_baixa = 'concluida' THEN 'concluida'::status_tarefa
                                                 ELSE 'em_revisao'::status_tarefa END,
                                   atualizado_por = v_robo
                 WHERE id = v_t.id;
                v_res := 'baixada';
            END IF;
            INSERT INTO tarefa_historico (tarefa_id, usuario_id, evento, detalhe)
            VALUES (v_t.id, v_robo, 'baixa_automatica', v_res || ' · ' || p_arquivo || ' · ' || v_det);
        END IF;
    END IF;
    INSERT INTO robo_eventos (arquivo, tipo_documento, cnpj, cliente_id, tarefa_id, resultado, detalhe, caminho_destino)
    VALUES (p_arquivo, p_tipo, p_cnpj, p_cliente_id, CASE WHEN v_res IN ('baixada','bloqueada','cnd_positiva') THEN p_tarefa_id END,
            v_res, v_det, p_caminho);
    RETURN jsonb_build_object('resultado', v_res, 'tarefa_id', p_tarefa_id);
END $$;

REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA robo FROM PUBLIC;
GRANT EXECUTE ON FUNCTION robo.identificar(TEXT, TEXT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION robo.registrar(TEXT, TEXT, TEXT, TEXT, INT, INT, TEXT, TEXT, DATE, TEXT, DATE, TEXT, TEXT) TO anon, authenticated;

ALTER ROLE authenticator SET pgrst.db_schemas = 'public, graphql_public, escritorio, robo';
NOTIFY pgrst, 'reload config';
