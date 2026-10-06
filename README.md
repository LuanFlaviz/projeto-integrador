# Sistema Luana Salgados — Backend (API)

API em **Node.js + TypeScript + Express** que conecta as telas `estoque.html`, `produto.html` e `painel.html` ao banco MySQL `luana_salgadinhos`.

O front hoje guarda tudo no `localStorage`. Com esta API, o front passa a chamar as rotas abaixo (veja "O que o front precisa trocar").

---

## 1. Como rodar (Windows)

Pré-requisitos: **Node.js 20 ou superior** (https://nodejs.org) e o **MySQL 8** com o banco já criado pelo script `database/luana_salgadinhos.sql` (o mesmo que você rodou no DBeaver).

```
cd luana-salgados-backend
npm install
copy .env.example .env
```

Abra o arquivo `.env` e ajuste a senha e o usuário do seu MySQL:

```
DB_USER=root
DB_PASSWORD=a_senha_do_seu_mysql
DB_NAME=luana_salgadinhos
```

Depois:

```
npm run dev
```

Você deve ver `API no ar: http://localhost:3000/api/saude`. Abra esse endereço no navegador: deve aparecer `{"api":"ok","banco":"ok"}`.

Scripts:

| Comando | O que faz |
|---|---|
| `npm run dev` | Roda e reinicia sozinho quando você salva um arquivo |
| `npm run build` | Compila o TypeScript para a pasta `dist/` |
| `npm start` | Roda a versão compilada (produção) |
| `npm test` | Roda os testes automáticos (usam um banco separado, veja a seção 5) |
| `npm run typecheck` | Só confere os tipos, sem gerar arquivos |

Se der erro de conexão, a API avisa o motivo no terminal (senha errada, MySQL desligado, banco inexistente).

---

## 2. Rotas

Todas começam com `/api`. Todas recebem e devolvem JSON.

| Tela | Método e rota | O que faz |
|---|---|---|
| geral | `GET /api/saude` | Confere API e banco |
| geral | `GET /api/unidades` | Unidades (para montar os selects) |
| estoque | `GET /api/ingredientes` | Lista o estoque (só ativos) |
| estoque | `GET /api/ingredientes/:id` | Um ingrediente |
| estoque | `POST /api/ingredientes` | "Adicionar ingrediente" |
| estoque | `POST /api/ingredientes/:id/reposicoes` | "Repor estoque" (soma) |
| estoque | `DELETE /api/ingredientes/:id` | "Excluir ingrediente" |
| produtos | `GET /api/produtos` | Lista produtos **já com a receita** (para o tooltip) |
| produtos | `GET /api/produtos/:id` | Um produto |
| produtos | `POST /api/produtos` | "Salvar produto" do modal (com a receita) |
| produtos | `DELETE /api/produtos/:id` | Excluir produto |
| produtos | `POST /api/autorizacoes` | "Finalizar autorização" (debita o estoque) |

O `painel.html` é só navegação, não precisa de rota.

### Exemplos

**Adicionar ingrediente** — `POST /api/ingredientes`

```json
{ "nome": "Farinha de trigo", "quantidade": 10, "unidade": "Kg" }
```

Resposta `201`:

```json
{
  "resultado": "CRIADO",
  "ingrediente": { "id": 1, "nome": "FARINHA DE TRIGO", "quantidade": 10, "unidade": "Kg", "quantidadeMinima": 0, "alertaEstoqueBaixo": false }
}
```

`resultado` pode ser `CRIADO`, `REATIVADO` (existia e tinha sido excluído) ou `JA_EXISTIA` (HTTP 200, nada muda). A unidade aceita `Kg`, `L` ou `Un` em qualquer capitalização. O nome é guardado em maiúsculas pelo banco, como o front já fazia.

**Repor estoque** — `POST /api/ingredientes/1/reposicoes`

```json
{ "quantidade": 5 }
```

Devolve `resultado: "REGISTRADA"`, o `uuidCliente` usado e o ingrediente já atualizado.

**Criar produto** — `POST /api/produtos`

```json
{
  "nome": "Coxinha",
  "receita": [
    { "ingrediente": "Farinha de trigo", "quantidade": 500, "unidade": "g" },
    { "ingrediente": "Leite", "quantidade": 250, "unidade": "ml" }
  ]
}
```

Unidades da receita: `g`, `kg`, `ml`, `L`, `un`. Ingrediente que ainda não existe é criado automaticamente com estoque zero. Se o produto já existir, a receita enviada **substitui** a antiga (`resultado: "ATUALIZADO"`).

**Finalizar autorização** — `POST /api/autorizacoes`

```json
{
  "observacao": "Pedido do sábado",
  "itens": [ { "produtoId": 1, "quantidade": 10 } ]
}
```

Sucesso (`201`): devolve a autorização com `produtos` e `consumo` (o que saiu do estoque, já convertido para Kg/L — é o "Ingredientes Totais Necessários" que o front mostrava no alert).

Se faltar insumo (`409`), **nada é debitado** e a resposta diz o que falta:

```json
{
  "erro": "Estoque insuficiente para finalizar a autorização de produção.",
  "codigo": "ESTOQUE_INSUFICIENTE",
  "faltantes": [
    { "ingrediente": "FARINHA", "unidade": "Kg", "disponivel": 10, "necessario": 50, "faltante": 40 }
  ]
}
```

### Erros

Sempre no formato `{ "erro": "mensagem em português", "codigo": "..." }`, e a mensagem pode ser mostrada direto ao usuário.

| Status | Quando |
|---|---|
| 400 | Dados inválidos. Vem `campos: [{ campo, mensagem }]` |
| 404 | Ingrediente/produto/rota não encontrado |
| 409 | Estoque insuficiente; ingrediente usado em receita não pode ser excluído; duplicado |
| 422 | Regra de negócio violada (ex.: unidade da receita incompatível com a do estoque) |
| 503 | Banco indisponível ou ocupado |
| 500 | Erro inesperado (o detalhe fica só no terminal da API) |

---

## 3. O que o front precisa trocar

Quem for fazer o front: o `localStorage` some e cada ação vira uma chamada `fetch`.

| Hoje (localStorage) | Passa a ser |
|---|---|
| carregar a tabela de estoque | `GET /api/ingredientes` |
| botão adicionar ingrediente | `POST /api/ingredientes` |
| botão repor | `POST /api/ingredientes/:id/reposicoes` |
| botão excluir ingrediente | `DELETE /api/ingredientes/:id` |
| carregar produtos e receitas | `GET /api/produtos` |
| salvar produto (modal) | `POST /api/produtos` |
| excluir produto | `DELETE /api/produtos/:id` |
| `finalizeAutorizacao()` (calcular e debitar no navegador) | `POST /api/autorizacoes` — o cálculo agora é feito no banco |

Pontos importantes:

- **O front passa a usar o `id`** (número) de ingredientes e produtos nas rotas, em vez do nome.
- **A lista de autorização** (os itens que o usuário vai adicionando com "ADICIONAR") pode continuar só em memória no front; ela só vai para a API quando clicar em "Finalizar".
- **Estoque insuficiente agora bloqueia** (HTTP 409) em vez de zerar o estoque como o front antigo fazia. O front deve mostrar a lista `faltantes`.
- O CORS está liberado (`CORS_ORIGIN=*`), então o front pode estar em outro endereço. Se quiser, coloque os três `.html` na pasta `public/` e abra `http://localhost:3000`: a própria API entrega as páginas (a entrada é o `painel.html`).

---

## 4. Modo offline (opcional, já preparado)

O banco foi pensado para o front funcionar sem internet e sincronizar depois. Por isso as rotas aceitam dois campos **opcionais** no corpo:

- `uuidCliente`: um UUID gerado pelo front para cada ação (`crypto.randomUUID()`). Se a mesma ação for enviada duas vezes (ex.: reenvio após queda de rede), a API **não repete** o efeito: responde `JA_PROCESSADA`. Vale para reposição e autorização. Se você não mandar, a API gera um.
- `dataEventoCliente`: data/hora em que a ação aconteceu no navegador, em ISO (`new Date().toISOString()`). Ela é convertida para o fuso do `.env` (`APP_TIMEZONE`, padrão `America/Cuiaba`) e gravada no histórico. Se não mandar, vale a hora em que a requisição chegou.

Se o front não for trabalhar offline, ignore os dois campos.

---

## 5. Testes

`npm test` sobe a API de verdade e conversa com um MySQL real (26 testes: cadastro, duplicados, validações, reposição e repetição por uuid, receita com g/ml, estoque insuficiente sem debitar nada, autorização, exclusões, reativação, fuso horário).

Os testes **apagam os dados** do banco em que rodam, por isso usam um banco separado e se recusam a rodar se o nome do banco não terminar em `_teste`. Para preparar (uma vez):

1. No DBeaver, rode o script `database/luana_salgadinhos.sql` trocando `luana_salgadinhos` por `luana_salgadinhos_teste` (Localizar e Substituir).
2. Crie o arquivo `.env.test` copiando o `.env.example` e usando `DB_NAME=luana_salgadinhos_teste` (e seu usuário/senha).
3. `npm test`.

O arquivo `requests.http` tem um exemplo de cada rota (extensão "REST Client" do VS Code) para você testar manualmente.

---

## 6. Como o projeto está organizado

```
src/
  server.ts          liga o servidor (confere o banco e escuta a porta)
  app.ts             monta o Express: CORS, JSON, rotas e tratamento de erros
  config.ts          lê o .env
  db.ts              conexão (pool) com o MySQL e helper para chamar procedures
  errors.ts          erros da API e tradução dos erros do MySQL para HTTP
  datas.ts           conversão de data do navegador para o fuso do banco
  unidades.ts        Kg, g, L, ml, Un
  schemas.ts         validação dos dados recebidos (zod)
  routes/            recebem a requisição, validam e chamam o service (finas)
  services/          falam com o banco
database/            script SQL do banco
test/                testes automáticos
public/              (opcional) coloque o front aqui
```

Caminho de uma requisição: **route** valida o JSON com o schema → **service** chama a **stored procedure** → o MySQL faz o trabalho em transação → a rota devolve o JSON.

Decisões:

- **A regra de negócio fica no banco** (procedures): transação, histórico de movimentações, idempotência, conversão g→Kg e ml→L e bloqueio por falta de estoque. A API não repete essa lógica, então não tem como as duas divergirem.
- As procedures identificam ingredientes e produtos pelo **nome**; por isso os services traduzem `id` → nome antes de chamar.
- **Exclusão é lógica**: o registro fica marcado como inativo para preservar o histórico. Recadastrar o mesmo nome reativa.
- **Histórico de movimentações**: o banco já grava tudo (tabela `movimentacoes_estoque`, view `vw_historico_movimentacoes`), mas ainda não há rota para consultar. Deixado para depois, como combinado.
- Sem autenticação por enquanto (o banco já tem a tabela `usuarios` para quando for preciso).
