-- =============================================================================
-- 05_dados_exemplo.sql : dados fictícios para testar (rode em banco VAZIO)
-- As datas são relativas a hoje, então o exemplo funciona em qualquer data.
-- =============================================================================
SET search_path TO escritorio, public;

INSERT INTO usuarios (nome, email, cargo, area, perfil, modalidade) VALUES
 ('Ana Gestora',   'ana@escritorio.com.br',   'Sócia / Gestora',     'administrativo',       'gestor',      'presencial'),   -- 1
 ('Bruno Fiscal',  'bruno@escritorio.com.br', 'Analista Fiscal',     'fiscal',               'colaborador', 'presencial'),   -- 2
 ('Carla Contábil','carla@escritorio.com.br', 'Analista Contábil',   'contabil',             'colaborador', 'home_office'),  -- 3
 ('Diego DP',      'diego@escritorio.com.br', 'Analista de DP',      'departamento_pessoal', 'colaborador', 'hibrido'),      -- 4
 ('Elisa Contábil','elisa@escritorio.com.br', 'Contadora',           'contabil',             'colaborador', 'home_office');  -- 5

INSERT INTO clientes (codigo, razao_social, cnpj_cpf, regime_tributario, responsavel_id,
                      contato_nome, contato_email, contato_telefone, pasta_arquivos) VALUES
 ('C0001', 'Padaria Pão Quente Ltda',   '11.111.111/0001-11', 'Lucro Presumido', 3, 'Marcos', 'marcos@paoquente.com', '(11) 90000-0001', '01_CLIENTES/C0001_PADARIA_PAO_QUENTE_LTDA'),
 ('C0002', 'Loja Bella Moda ME',        '22.222.222/0001-22', 'Simples Nacional', 2, 'Joana',  'joana@bellamoda.com',  '(11) 90000-0002', '01_CLIENTES/C0002_LOJA_BELLA_MODA_ME'),
 ('C0003', 'Transportes Rota Sul Ltda', '33.333.333/0001-33', 'Lucro Real',       4, 'Paulo',  'paulo@rotasul.com',    '(11) 90000-0003', '01_CLIENTES/C0003_TRANSPORTES_ROTA_SUL_LTDA'),
 ('C0004', 'Clínica Sorriso S/S',       '44.444.444/0001-44', 'Simples Nacional', 5, 'Rita',   'rita@sorriso.com',     '(11) 90000-0004', '01_CLIENTES/C0004_CLINICA_SORRISO_S_S');

-- competência = mês anterior
INSERT INTO tarefas (titulo, cliente_id, area, competencia, responsavel_id, revisor_id, criado_por, prioridade, prazo) VALUES
 ('Importar extrato bancário',          1, 'contabil',             date_trunc('month', CURRENT_DATE - interval '1 month'), 3, NULL, 1, 'alta',    CURRENT_DATE + 2),  -- 1
 ('Conciliação bancária',               1, 'contabil',             date_trunc('month', CURRENT_DATE - interval '1 month'), 3, 5,    1, 'alta',    CURRENT_DATE + 5),  -- 2
 ('Apuração do Simples Nacional (DAS)', 2, 'fiscal',               date_trunc('month', CURRENT_DATE - interval '1 month'), 2, 1,    1, 'urgente', CURRENT_DATE + 1),  -- 3
 ('Escrituração fiscal de entradas',    1, 'fiscal',               date_trunc('month', CURRENT_DATE - interval '1 month'), 2, NULL, 1, 'media',   CURRENT_DATE + 3),  -- 4
 ('Apuração PIS/COFINS e ICMS',         1, 'fiscal',               date_trunc('month', CURRENT_DATE - interval '1 month'), 2, 1,    1, 'alta',    CURRENT_DATE + 6),  -- 5
 ('Balancete mensal',                   1, 'contabil',             date_trunc('month', CURRENT_DATE - interval '1 month'), 5, 1,    1, 'media',   CURRENT_DATE + 10), -- 6
 ('Folha de pagamento',                 3, 'departamento_pessoal', date_trunc('month', CURRENT_DATE - interval '1 month'), 4, 1,    1, 'urgente', CURRENT_DATE + 1),  -- 7
 ('Guias FGTS Digital e DCTFWeb',       3, 'departamento_pessoal', date_trunc('month', CURRENT_DATE - interval '1 month'), 4, NULL, 1, 'alta',    CURRENT_DATE + 4),  -- 8
 ('Alteração contratual (endereço)',    4, 'societario',           NULL,                                                   1, NULL, 1, 'media',   CURRENT_DATE + 20), -- 9
 ('Classificação contábil das despesas',4, 'contabil',             date_trunc('month', CURRENT_DATE - interval '1 month'), 5, NULL, 1, 'alta',    CURRENT_DATE - 2),  -- 10 (atrasada)
 ('Apuração do Simples Nacional (DAS)', 4, 'fiscal',               date_trunc('month', CURRENT_DATE - interval '1 month'), 2, NULL, 1, 'alta',    CURRENT_DATE - 3),  -- 11
 ('Pró-labore dos sócios',              4, 'departamento_pessoal', date_trunc('month', CURRENT_DATE - interval '1 month'), 4, NULL, 1, 'media',   CURRENT_DATE + 2);  -- 12

-- ---------------- Dependências ----------------------------------------------
-- Carla aguarda o CLIENTE enviar o extrato
SELECT fn_adicionar_dependencia(1, 3, 'cliente', 1, 'Enviar extrato bancário Itaú do mês (PDF ou OFX)');
-- Conciliação depende da importação (outra TAREFA)
SELECT fn_adicionar_dependencia(2, 1, 'tarefa', 1, 'Precisa do extrato importado');
-- Apuração de PIS/COFINS depende da escrituração (outra TAREFA)
SELECT fn_adicionar_dependencia(5, 1, 'tarefa', 4, 'Precisa das notas de entrada escrituradas');
-- Balancete (Elisa) depende da conciliação (Carla) e da apuração (Bruno)
SELECT fn_adicionar_dependencia(6, 1, 'tarefa', 2, 'Conciliação bancária finalizada');
SELECT fn_adicionar_dependencia(6, 1, 'tarefa', 5, 'Impostos do mês apurados');
-- Folha depende do CLIENTE e da aprovação de uma PESSOA (gestora)
SELECT fn_adicionar_dependencia(7, 4, 'cliente', 3, 'Enviar relação de horas extras e faltas');
SELECT fn_adicionar_dependencia(7, 4, 'pessoa',  1, 'Aprovar cálculo do reajuste do dissídio');
-- Guias dependem da folha
SELECT fn_adicionar_dependencia(8, 1, 'tarefa', 7, 'Folha fechada');
-- Alteração contratual depende de órgão EXTERNO
SELECT fn_adicionar_dependencia(9, 1, 'externo', NULL, 'Análise da Junta Comercial (protocolo 123456)');

-- ---------------- Andamento simulado -----------------------------------------
SELECT fn_alterar_status(4, 2, 'em_andamento');
SELECT fn_alterar_status(3, 2, 'em_andamento');
SELECT fn_concluir_tarefa(3, 2, '01_CLIENTES/C0002_LOJA_BELLA_MODA_ME/03_FISCAL/2026/2026-10/03_APURACAO/2026-10_C0002_FISCAL_APURACAO-DAS_v01.pdf', 'DAS enviado ao cliente por e-mail');

-- cliente da folha enviou a planilha; gestora aprovou o reajuste
SELECT fn_resolver_dependencia(6, 4, 'Planilha recebida no portal');
SELECT fn_resolver_dependencia(7, 1, 'Reajuste de 5% aprovado');
SELECT fn_alterar_status(7, 4, 'em_andamento');
SELECT fn_concluir_tarefa(7, 4, '01_CLIENTES/C0003_TRANSPORTES_ROTA_SUL_LTDA/04_DEPARTAMENTO_PESSOAL/2026/2026-10/01_FOLHA/');
-- (a tarefa 8 - Guias - foi liberada automaticamente pela conclusão da 7)

SELECT fn_registrar_cobranca(1, 3);    -- Carla cobrou o extrato do cliente

SELECT fn_alterar_status(12, 4, 'em_andamento');
SELECT fn_alterar_status(12, 4, 'em_revisao', 'Conferir valor do INSS');

-- tarefa entregue com atraso (simula conclusão há 1 dia)
SELECT fn_concluir_tarefa(11, 2);
UPDATE tarefas SET concluido_em = now() - interval '1 day', iniciado_em = now() - interval '2 days' WHERE id = 11;
