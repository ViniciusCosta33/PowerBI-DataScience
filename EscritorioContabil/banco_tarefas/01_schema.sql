-- =============================================================================
-- ESCRITÓRIO CONTÁBIL - CONTROLE DE TAREFAS
-- 01_schema.sql : tabelas, tipos e índices
-- Banco alvo: PostgreSQL 14+ (funciona em servidor local, Supabase, Azure, AWS)
--
-- Por que um banco central (e não planilha)?
--   * Equipe presencial e home office enxergam a MESMA informação em tempo real.
--   * Cada mudança de status fica registrada (quem, quando, de -> para).
--   * Dependências entre tarefas/pessoas/clientes são controladas pelo banco.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS escritorio;
SET search_path TO escritorio, public;

-- -----------------------------------------------------------------------------
-- Tipos enumerados
-- -----------------------------------------------------------------------------
CREATE TYPE perfil_usuario   AS ENUM ('gestor', 'colaborador');
CREATE TYPE modalidade_trab  AS ENUM ('presencial', 'home_office', 'hibrido');
CREATE TYPE area_escritorio  AS ENUM ('contabil', 'fiscal', 'departamento_pessoal',
                                      'societario', 'financeiro', 'administrativo');
CREATE TYPE status_tarefa    AS ENUM ('a_fazer', 'em_andamento', 'aguardando',
                                      'em_revisao', 'concluida', 'cancelada');
CREATE TYPE prioridade_tarefa AS ENUM ('baixa', 'media', 'alta', 'urgente');

-- Tipo de dependência (o "porquê" de a tarefa estar travada)
--   tarefa  -> depende de OUTRA TAREFA ainda não concluída
--   pessoa  -> depende de uma ação/resposta de OUTRO COLABORADOR
--   cliente -> depende do CLIENTE (envio de documento, aprovação, pagamento...)
--   externo -> depende de terceiros (Receita, Prefeitura, banco, Junta...)
CREATE TYPE tipo_dependencia AS ENUM ('tarefa', 'pessoa', 'cliente', 'externo');

-- -----------------------------------------------------------------------------
-- Usuários (colaboradores e gestores)
-- -----------------------------------------------------------------------------
CREATE TABLE usuarios (
    id              SERIAL PRIMARY KEY,
    nome            VARCHAR(120) NOT NULL,
    email           VARCHAR(160) NOT NULL UNIQUE,   -- usado no login / RLS do Power BI
    cargo           VARCHAR(80),
    area            area_escritorio,
    perfil          perfil_usuario  NOT NULL DEFAULT 'colaborador',
    modalidade      modalidade_trab NOT NULL DEFAULT 'presencial',
    ativo           BOOLEAN NOT NULL DEFAULT TRUE,
    auth_user_id    UUID UNIQUE,                    -- opcional: id do Supabase Auth
    criado_em       TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- Clientes do escritório
-- -----------------------------------------------------------------------------
CREATE TABLE clientes (
    id                  SERIAL PRIMARY KEY,
    codigo              VARCHAR(10) NOT NULL UNIQUE,   -- ex.: C0001 (usado no nome da pasta)
    razao_social        VARCHAR(200) NOT NULL,
    cnpj_cpf            VARCHAR(18)  NOT NULL UNIQUE,
    regime_tributario   VARCHAR(30),                   -- Simples, Presumido, Real, MEI, PF
    responsavel_id      INT REFERENCES usuarios(id),   -- carteira: quem atende o cliente
    contato_nome        VARCHAR(120),
    contato_email       VARCHAR(160),
    contato_telefone    VARCHAR(20),
    pasta_arquivos      VARCHAR(300),                  -- caminho na rede/nuvem
    ativo               BOOLEAN NOT NULL DEFAULT TRUE,
    criado_em           TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- Tarefas
-- -----------------------------------------------------------------------------
CREATE TABLE tarefas (
    id                  SERIAL PRIMARY KEY,
    titulo              VARCHAR(200) NOT NULL,
    descricao           TEXT,
    cliente_id          INT REFERENCES clientes(id),   -- NULL = tarefa interna
    area                area_escritorio NOT NULL,
    competencia         DATE,                          -- 1º dia do mês de referência
    responsavel_id      INT NOT NULL REFERENCES usuarios(id),
    revisor_id          INT REFERENCES usuarios(id),   -- opcional: quem confere
    criado_por          INT NOT NULL REFERENCES usuarios(id),
    prioridade          prioridade_tarefa NOT NULL DEFAULT 'media',
    status              status_tarefa NOT NULL DEFAULT 'a_fazer',
    prazo               DATE,
    criado_em           TIMESTAMPTZ NOT NULL DEFAULT now(),
    iniciado_em         TIMESTAMPTZ,                   -- preenchido automaticamente
    concluido_em        TIMESTAMPTZ,                   -- preenchido automaticamente
    concluido_por       INT REFERENCES usuarios(id),   -- preenchido automaticamente
    atualizado_em       TIMESTAMPTZ NOT NULL DEFAULT now(),
    atualizado_por      INT REFERENCES usuarios(id),   -- quem fez a última alteração
    caminho_arquivos    VARCHAR(300),                  -- pasta/arquivo da entrega
    CONSTRAINT ck_competencia_dia1 CHECK (competencia IS NULL OR EXTRACT(DAY FROM competencia) = 1)
);

CREATE INDEX ix_tarefas_responsavel ON tarefas (responsavel_id, status);
CREATE INDEX ix_tarefas_cliente     ON tarefas (cliente_id);
CREATE INDEX ix_tarefas_prazo       ON tarefas (prazo) WHERE status NOT IN ('concluida', 'cancelada');
CREATE INDEX ix_tarefas_concluido   ON tarefas (concluido_em);

-- -----------------------------------------------------------------------------
-- Dependências / pendências de uma tarefa
-- Uma tarefa pode ter várias. Enquanto houver dependência ABERTA
-- (resolvido_em IS NULL), a tarefa é considerada BLOQUEADA.
-- -----------------------------------------------------------------------------
CREATE TABLE tarefa_dependencias (
    id                  SERIAL PRIMARY KEY,
    tarefa_id           INT NOT NULL REFERENCES tarefas(id) ON DELETE CASCADE,
    tipo                tipo_dependencia NOT NULL,
    depende_tarefa_id   INT REFERENCES tarefas(id),    -- tipo = 'tarefa'
    depende_usuario_id  INT REFERENCES usuarios(id),   -- tipo = 'pessoa'
    depende_cliente_id  INT REFERENCES clientes(id),   -- tipo = 'cliente'
    descricao           VARCHAR(300) NOT NULL,         -- o que exatamente está faltando
    criado_em           TIMESTAMPTZ NOT NULL DEFAULT now(),
    criado_por          INT REFERENCES usuarios(id),
    cobrado_em          TIMESTAMPTZ,                   -- última cobrança feita
    resolvido_em        TIMESTAMPTZ,
    resolvido_por       INT REFERENCES usuarios(id),
    CONSTRAINT ck_dep_tarefa  CHECK (tipo <> 'tarefa'  OR depende_tarefa_id  IS NOT NULL),
    CONSTRAINT ck_dep_pessoa  CHECK (tipo <> 'pessoa'  OR depende_usuario_id IS NOT NULL),
    CONSTRAINT ck_dep_cliente CHECK (tipo <> 'cliente' OR depende_cliente_id IS NOT NULL),
    CONSTRAINT ck_dep_propria CHECK (depende_tarefa_id IS NULL OR depende_tarefa_id <> tarefa_id)
);

CREATE INDEX ix_dep_tarefa_aberta ON tarefa_dependencias (tarefa_id) WHERE resolvido_em IS NULL;
CREATE INDEX ix_dep_depende_de    ON tarefa_dependencias (depende_tarefa_id) WHERE resolvido_em IS NULL;
CREATE INDEX ix_dep_usuario       ON tarefa_dependencias (depende_usuario_id) WHERE resolvido_em IS NULL;

-- -----------------------------------------------------------------------------
-- Histórico (auditoria) - alimentado automaticamente por trigger.
-- É aqui que o gestor vê "quem fez o quê e quando".
-- -----------------------------------------------------------------------------
CREATE TABLE tarefa_historico (
    id                  BIGSERIAL PRIMARY KEY,
    tarefa_id           INT NOT NULL REFERENCES tarefas(id) ON DELETE CASCADE,
    usuario_id          INT REFERENCES usuarios(id),
    evento              VARCHAR(40) NOT NULL,   -- criada, status, reatribuida, dependencia_aberta...
    status_anterior     status_tarefa,
    status_novo         status_tarefa,
    detalhe             TEXT,
    ocorrido_em         TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX ix_hist_tarefa  ON tarefa_historico (tarefa_id, ocorrido_em);
CREATE INDEX ix_hist_usuario ON tarefa_historico (usuario_id, ocorrido_em);

-- -----------------------------------------------------------------------------
-- Comentários livres na tarefa (comunicação presencial x remoto fica registrada)
-- -----------------------------------------------------------------------------
CREATE TABLE tarefa_comentarios (
    id          BIGSERIAL PRIMARY KEY,
    tarefa_id   INT NOT NULL REFERENCES tarefas(id) ON DELETE CASCADE,
    usuario_id  INT NOT NULL REFERENCES usuarios(id),
    texto       TEXT NOT NULL,
    criado_em   TIMESTAMPTZ NOT NULL DEFAULT now()
);
