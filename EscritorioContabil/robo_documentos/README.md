# Robô de documentos

Roda no **computador central** (onde fica a pasta da rede). A cada 10 minutos ele:

1. Lê os PDFs salvos em `00_ENTRADA`, com qualquer nome.
2. Reconhece o documento. Hoje: **CND federal** (negativa, positiva com efeitos de negativa e positiva).
3. Acha o cliente pelo **CNPJ** do documento e a tarefa aberta de CND desse cliente
   (título com "CND" ou "Certidão"; se houver mais de uma, a que tem "Federal" e o prazo mais próximo).
4. Move o PDF para `01_CLIENTES/<cliente>/07_CERTIDOES/` com nome padrão:
   `2026-11-10_C0000239_CND-FEDERAL_NEGATIVA_valida-2027-05-09.pdf`.
5. Dá a baixa na tarefa (vai para **Em revisão**, ou **Concluída** se configurado) e grava o link do arquivo.

| Situação | O que o robô faz |
|---|---|
| CND negativa ou positiva com efeitos de negativa | Arquiva e dá a baixa |
| CND **positiva** (há débitos) | Arquiva e **não** dá baixa: abre a pendência "regularizar débitos federais" |
| Cliente com CNPJ não cadastrado | Move para `00_A_CONFERIR` |
| Cliente certo, mas sem tarefa de CND aberta | Arquiva na pasta do cliente e avisa |
| Documento não reconhecido | Move para `00_A_CONFERIR` |

Tudo aparece no app em **Equipe e clientes → Robô de documentos**, e no histórico da tarefa como "Robô de documentos".

## Instalação no computador central (Windows), uma vez só

1. **Python**: instale em https://www.python.org/downloads/ marcando **"Add python.exe to PATH"**.
2. Abra o **Prompt de Comando** e rode: `pip install pypdf`
3. Copie esta pasta `robo_documentos` para o computador central (ex.: `C:\RoboDocumentos`).
4. Copie `robo_config.exemplo.ini` para `robo_config.ini` e preencha:
   - `raiz`: a pasta principal da rede **no próprio computador** (ex.: `D:\Escritorio`).
   - `token_robo`: no app, **Equipe e clientes → Robô de documentos → Gerar chave do robô**, copie e cole aqui.
5. Crie as pastas `00_ENTRADA` e `00_A_CONFERIR` dentro da raiz, se não existirem.
6. Teste sem mexer em nada: `python robo_documentos.py --simular`
7. Dê dois cliques em **`instalar_agendamento.bat`** para rodar a cada 10 minutos.

Registros: `robo.log` (o que foi feito) e `robo_saida.log` (erros do agendamento), nesta pasta.

## Cuidados
- O `robo_config.ini` tem a chave do robô: não envie por e-mail/WhatsApp. Se vazar, gere outra no app (a antiga para de funcionar na hora).
- A chave só permite ao robô **identificar clientes e registrar baixas**; ela não lê tarefas nem dados do escritório.
- Os PDFs não saem do computador central: só CNPJ, tipo, validade e o caminho do arquivo vão para o sistema.
- PDF escaneado (imagem) não tem texto: vai para `00_A_CONFERIR`. A CND emitida no site da Receita tem texto e funciona.
