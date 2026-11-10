-- =============================================================================
-- Testes automáticos das regras (rodar após 01, 02, 03 e 05).
-- Tudo roda dentro de uma transação que é desfeita no final (ROLLBACK).
--   psql -v ON_ERROR_STOP=1 -d <banco> -f testes/testes_regras.sql
-- =============================================================================
SET search_path TO escritorio, public;
BEGIN;

-- 1. Não pode concluir tarefa com dependência aberta
DO $$
BEGIN
    PERFORM fn_concluir_tarefa(6, 5);
    RAISE EXCEPTION 'FALHOU: concluiu tarefa bloqueada';
EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'FALHOU%' THEN RAISE; END IF;
    RAISE NOTICE 'OK 1 - bloqueio de conclusão: %', SQLERRM;
END $$;

-- 2. Dependência circular é recusada (tarefa 1 passar a depender da 6,
--    sendo que 6 -> 2 -> 1)
DO $$
BEGIN
    PERFORM fn_adicionar_dependencia(1, 1, 'tarefa', 6, 'ciclo');
    RAISE EXCEPTION 'FALHOU: aceitou ciclo';
EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'FALHOU%' THEN RAISE; END IF;
    RAISE NOTICE 'OK 2 - ciclo bloqueado: %', SQLERRM;
END $$;

-- 3. Cadeia completa: cliente entrega extrato -> 1 libera -> 2 libera -> 6 libera
DO $$
DECLARE v TEXT;
BEGIN
    PERFORM fn_resolver_dependencia(1, 3, 'Extrato recebido');
    SELECT status INTO v FROM tarefas WHERE id = 1;
    ASSERT v = 'a_fazer', 'tarefa 1 deveria voltar para a_fazer, está ' || v;

    PERFORM fn_concluir_tarefa(1, 3);
    SELECT status INTO v FROM tarefas WHERE id = 2;
    ASSERT v = 'a_fazer', 'tarefa 2 deveria ser liberada, está ' || v;

    PERFORM fn_concluir_tarefa(2, 3);
    PERFORM fn_concluir_tarefa(4, 2);
    PERFORM fn_concluir_tarefa(5, 2);
    SELECT situacao INTO v FROM vw_tarefas WHERE tarefa_id = 6;
    ASSERT v = 'Liberada para iniciar', 'balancete deveria estar liberado, está ' || v;
    RAISE NOTICE 'OK 3 - liberação em cadeia';
END $$;

-- 4. Quem concluiu e quando ficam gravados
DO $$
DECLARE r RECORD;
BEGIN
    SELECT concluido_por, concluido_em INTO r FROM tarefas WHERE id = 2;
    ASSERT r.concluido_por = 3 AND r.concluido_em IS NOT NULL, 'conclusão não registrada';
    ASSERT (SELECT count(*) FROM tarefa_historico
             WHERE tarefa_id = 2 AND status_novo = 'concluida' AND usuario_id = 3) = 1,
           'histórico de conclusão ausente';
    RAISE NOTICE 'OK 4 - conclusão rastreada (usuário e data/hora)';
END $$;

-- 5. Reabrir limpa a conclusão; reatribuir muda quem é aguardado
DO $$
BEGIN
    PERFORM fn_alterar_status(3, 1, 'em_andamento', 'Cliente pediu retificação');
    ASSERT (SELECT concluido_em FROM tarefas WHERE id = 3) IS NULL, 'reabertura não limpou conclusão';

    PERFORM fn_adicionar_dependencia(12, 1, 'tarefa', 10, 'teste reatribuição');
    UPDATE tarefas SET responsavel_id = 3, atualizado_por = 1 WHERE id = 10;
    ASSERT (SELECT bloqueador_usuario_id FROM vw_pendencias_abertas
             WHERE tarefa_id = 12 AND o_que_falta = 'teste reatribuição') = 3,
           'dependência não acompanhou o novo responsável';
    RAISE NOTICE 'OK 5 - reabertura e reatribuição';
END $$;

ROLLBACK;
