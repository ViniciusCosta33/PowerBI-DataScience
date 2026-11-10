# Robô de documentos (Google Drive)

Roda **dentro da conta Google do escritório** (Google Apps Script): não depende de nenhum
computador ligado. A cada 10 minutos ele:

1. Lê os PDFs salvos na pasta `00_ENTRADA` do Drive, com qualquer nome.
   O texto é extraído pelo próprio Google, **inclusive de PDF escaneado**.
2. Reconhece o documento. Hoje: **CND federal** (negativa, positiva com efeitos de negativa e positiva).
3. Acha o cliente pelo **CNPJ** e a tarefa de CND que ainda espera o documento
   (título com "CND" ou "Certidão"; tarefas já em revisão são ignoradas).
4. Move o PDF para `01_CLIENTES/<cliente>/07_CERTIDOES/` com nome padrão
   (`2026-11-10_C0000239_CND-FEDERAL_NEGATIVA_valida-2027-05-09.pdf`).
5. Dá a baixa na tarefa (**Em revisão**, ou **Concluída** se configurado) e grava o **link do arquivo**,
   que fica clicável no app.

| Situação | O que o robô faz |
|---|---|
| CND negativa ou positiva com efeitos de negativa | Arquiva e dá a baixa |
| CND **positiva** (há débitos) | Arquiva e **não** dá baixa: abre a pendência "regularizar débitos federais" |
| CNPJ não cadastrado | Move para `00_A_CONFERIR` |
| Cliente certo, sem tarefa de CND esperando | Arquiva na pasta do cliente e avisa |
| Documento não reconhecido | Move para `00_A_CONFERIR` |

O resultado de cada arquivo aparece no app em **Equipe e clientes → Robô de documentos**.

## Instalação (uma vez, uns 10 minutos)

1. **Pasta no Drive**: crie (ou escolha) a pasta principal do escritório no Google Drive e abra.
   Copie o **ID** dela: é o trecho do endereço depois de `/folders/`.
2. Abra https://script.google.com → **Novo projeto**. Dê o nome "Robô de documentos".
3. Apague o conteúdo de `Código.gs` e cole o conteúdo de [`Codigo.gs`](Codigo.gs).
   Na linha `PASTA_RAIZ_ID`, troque `COLE_AQUI_O_ID_DA_PASTA` pelo ID copiado.
4. Engrenagem **Configurações do projeto**:
   - marque **"Mostrar arquivo de manifesto appsscript.json no editor"**; volte ao editor,
     abra `appsscript.json` e substitua pelo conteúdo de [`appsscript.json`](appsscript.json);
   - em **Propriedades do script → Adicionar propriedade**: nome `TOKEN_ROBO`, valor = a chave gerada no app
     (**Equipe e clientes → Robô de documentos → Gerar chave do robô**).
5. No editor, escolha a função **`simular`** e clique em **Executar**. Na primeira vez o Google pede
   autorização: escolha a conta do escritório → *Avançado* → *Acessar Robô de documentos (não seguro)*
   → *Permitir*. (O aviso aparece porque o script é seu e não foi publicado na loja do Google.)
6. Escolha a função **`instalar`** e clique em **Executar**. Pronto: pastas criadas e robô agendado.

Para conferir o que ele fez: menu **Execuções** do Apps Script, ou a lista no app.
Para parar: execute a função **`desinstalar`**.

## Cuidados
- A chave do robô fica nas *Propriedades do script*, fora do código. Se vazar, gere outra no app:
  a antiga para de funcionar na hora.
- A chave só permite **identificar o cliente e registrar a baixa**; não lê tarefas nem dados do escritório.
- Os PDFs ficam no seu Drive. Só CNPJ, tipo, validade e o link do arquivo vão para o sistema.
- Para mudar a baixa para "Concluída", troque `STATUS_BAIXA: 'em_revisao'` por `'concluida'` no código.
