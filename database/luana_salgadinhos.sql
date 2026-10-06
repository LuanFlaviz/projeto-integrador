-- ============================================================================
-- BANCO DE DADOS — SISTEMA LUANA SALGADINHOS  (versão corrigida)
-- Baseado em: DOCUMENTAÇÃO — Sistema Luana Salgadinhos (v2.0)
-- SGBD: MySQL 8.0.19+  (CHECK constraints, JSON_TABLE).
--       Testado também em MariaDB 10.11.
--
-- Como rodar no DBeaver: abra este arquivo e execute como SCRIPT
-- (Alt+X), não como comando único (Ctrl+Enter) — ele usa DELIMITER.
-- Se o banco luana_salgadinhos já existir de uma tentativa anterior,
-- descomente a linha DROP DATABASE logo abaixo para recriar do zero.
--
-- COLLATION: nenhuma é fixada de propósito. O padrão do utf8mb4 no MySQL 8
-- (utf8mb4_0900_ai_ci) e no MariaDB (utf8mb4_general_ci) ignora acento e
-- maiúscula, e é isso que faz UNIQUE(nome) tratar "Óleo" = "oleo".
--
-- MODELO DE SINCRONIZAÇÃO (local-first):
-- Os dados são gravados primeiro no localStorage do navegador e só chegam
-- ao banco quando há internet. Toda procedure de sincronização pode ser
-- chamada mais de uma vez com o mesmo evento (reenvio após queda de
-- conexão) sem duplicar efeito:
--   - Cadastros (ingrediente, produto, receita) são idempotentes pela
--     chave natural (nome).
--   - Eventos (reposição, autorização de produção) levam um uuid_cliente
--     gerado no navegador (crypto.randomUUID()); o banco ignora reenvios.
--   - As procedures recebem NOMES, não IDs (offline o navegador não
--     conhece o AUTO_INCREMENT do servidor).
--   - Cada evento guarda data_evento_cliente (quando aconteceu de fato) e
--     a data de chegada no servidor.
--
-- RESULTADOS DAS PROCEDURES (parâmetro OUT p_resultado):
--   sp_cadastrar_ingrediente            CRIADO | REATIVADO | JA_EXISTIA
--   sp_registrar_reposicao_estoque      REGISTRADA | JA_PROCESSADA
--   sp_excluir_ingrediente              EXCLUIDO | JA_EXCLUIDO
--   sp_sincronizar_produto_com_receita  CRIADO | REATIVADO | ATUALIZADO
--   sp_excluir_produto                  EXCLUIDO | JA_EXCLUIDO
--   sp_sincronizar_autorizacao_producao FINALIZADA | JA_PROCESSADA |
--                                       ESTOQUE_INSUFICIENTE (+ p_faltantes)
-- Erros de regra de negócio (nome vazio, produto inexistente, unidade
-- incompatível, ingrediente em uso...) saem como SQLSTATE 45000 com
-- mensagem em português.
-- ============================================================================

-- DROP DATABASE IF EXISTS luana_salgadinhos;

CREATE DATABASE IF NOT EXISTS luana_salgadinhos
    CHARACTER SET utf8mb4;

USE luana_salgadinhos;

-- ============================================================================
-- 1) TABELAS DE REFERÊNCIA
-- ============================================================================

-- Unidades de estoque (Kg, L, Un) e unidades "finas" de receita (g, ml).
CREATE TABLE unidades_medida (
    unidade_id                TINYINT UNSIGNED NOT NULL PRIMARY KEY,
    sigla                     VARCHAR(5)       NOT NULL UNIQUE,
    descricao                 VARCHAR(50)      NOT NULL,
    permite_estoque           BOOLEAN          NOT NULL DEFAULT FALSE,
        -- TRUE = pode ser a unidade em que o ESTOQUE do ingrediente é guardado
    fator_conversao_para_base DECIMAL(10,6)    NOT NULL DEFAULT 1,
        -- converte 1 unidade desta linha para a unidade base (g->Kg = 0.001)
    unidade_base_id           TINYINT UNSIGNED NULL,
        -- para g/ml aponta para Kg/L; NULL quando a própria unidade já é base
    CONSTRAINT fk_unidades_medida_base FOREIGN KEY (unidade_base_id)
        REFERENCES unidades_medida(unidade_id)
) ENGINE = InnoDB;

INSERT INTO unidades_medida (unidade_id, sigla, descricao, permite_estoque, fator_conversao_para_base, unidade_base_id) VALUES
    (1, 'Kg', 'Quilograma', TRUE,  1.000000, NULL),
    (2, 'g',  'Grama',      FALSE, 0.001000, 1),
    (3, 'L',  'Litro',      TRUE,  1.000000, NULL),
    (4, 'ml', 'Mililitro',  FALSE, 0.001000, 3),
    (5, 'Un', 'Unidade',    TRUE,  1.000000, NULL);

-- O sistema atual não tem login. Fica pronta para quando existir: as
-- tabelas de evento têm usuario_id opcional (NULL).
CREATE TABLE usuarios (
    usuario_id     INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    nome           VARCHAR(150) NOT NULL,
    email          VARCHAR(150) NOT NULL UNIQUE,
    ativo          BOOLEAN      NOT NULL DEFAULT TRUE,
    data_cadastro  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE = InnoDB;

-- ============================================================================
-- 2) CADASTROS PRINCIPAIS
-- ============================================================================

-- Equivalente ao "stockDatabase". O nome é a chave de sincronização e é
-- único sem diferenciar acento/maiúscula (resolve a limitação conhecida).
-- Exclusão é lógica (ativo = FALSE): o ingrediente continua existindo para
-- o histórico.
CREATE TABLE ingredientes (
    ingrediente_id     INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    nome               VARCHAR(150)  NOT NULL,
    quantidade_atual   DECIMAL(12,4) NOT NULL DEFAULT 0 CHECK (quantidade_atual >= 0),
    quantidade_minima  DECIMAL(12,4) NOT NULL DEFAULT 0 CHECK (quantidade_minima >= 0),
    unidade_medida_id  TINYINT UNSIGNED NOT NULL,
    ativo              BOOLEAN       NOT NULL DEFAULT TRUE,
    data_cadastro      DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_ingredientes_nome UNIQUE (nome),
    CONSTRAINT fk_ingredientes_unidade FOREIGN KEY (unidade_medida_id)
        REFERENCES unidades_medida(unidade_id)
) ENGINE = InnoDB;

-- Equivalente ao "productNames". Exclusão também é lógica.
CREATE TABLE produtos (
    produto_id     INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    nome           VARCHAR(150) NOT NULL UNIQUE,
    ativo          BOOLEAN   NOT NULL DEFAULT TRUE,
    data_cadastro  DATETIME  NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE = InnoDB;

-- Eventos de cadastro/exclusão de produto — alimentam o relatório
-- ("ao inserir, é gerado um evento com a data em que o produto foi
-- inserido"). Um produto excluído e recadastrado gera um novo evento.
CREATE TABLE eventos_produto (
    evento_produto_id    BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    produto_id           INT UNSIGNED NOT NULL,
    tipo_evento          ENUM('CADASTRO', 'EXCLUSAO') NOT NULL,
    data_evento_cliente  DATETIME     NULL,
    data_registro        DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    usuario_id           INT UNSIGNED NULL,
    CONSTRAINT fk_eventos_produto_produto FOREIGN KEY (produto_id)
        REFERENCES produtos(produto_id),
    CONSTRAINT fk_eventos_produto_usuario FOREIGN KEY (usuario_id)
        REFERENCES usuarios(usuario_id)
) ENGINE = InnoDB;

-- Equivalente às "receitas": quantidade necessária POR UNIDADE produzida.
CREATE TABLE receita_itens (
    receita_item_id        INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    produto_id             INT UNSIGNED  NOT NULL,
    ingrediente_id         INT UNSIGNED  NOT NULL,
    quantidade_necessaria  DECIMAL(12,4) NOT NULL CHECK (quantidade_necessaria > 0),
    unidade_medida_id      TINYINT UNSIGNED NOT NULL,
        -- pode ser g/ml mesmo que o estoque seja Kg/L (a trigger abaixo
        -- garante que seja da MESMA grandeza do estoque)
    CONSTRAINT uq_receita_itens_produto_ingrediente UNIQUE (produto_id, ingrediente_id),
    CONSTRAINT fk_receita_itens_produto FOREIGN KEY (produto_id)
        REFERENCES produtos(produto_id),
    CONSTRAINT fk_receita_itens_ingrediente FOREIGN KEY (ingrediente_id)
        REFERENCES ingredientes(ingrediente_id),
    CONSTRAINT fk_receita_itens_unidade FOREIGN KEY (unidade_medida_id)
        REFERENCES unidades_medida(unidade_id)
) ENGINE = InnoDB;

-- ============================================================================
-- 3) AUTORIZAÇÃO DE PRODUÇÃO
-- uuid_cliente identifica o evento gerado no navegador: reenviar a mesma
-- autorização não debita o estoque duas vezes.
-- ============================================================================

CREATE TABLE autorizacoes_producao (
    autorizacao_id       INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    uuid_cliente         CHAR(36)     NOT NULL,
    data_evento_cliente  DATETIME     NULL,
        -- quando a autorização foi finalizada na tela, no navegador
    data_autorizacao     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
        -- quando chegou ao servidor
    data_finalizacao     DATETIME     NULL,
    status_autorizacao   ENUM('PENDENTE', 'FINALIZADA', 'CANCELADA') NOT NULL DEFAULT 'PENDENTE',
    usuario_id           INT UNSIGNED NULL,
    observacao           VARCHAR(500) NULL,
    CONSTRAINT uq_autorizacoes_uuid_cliente UNIQUE (uuid_cliente),
    CONSTRAINT fk_autorizacoes_producao_usuario FOREIGN KEY (usuario_id)
        REFERENCES usuarios(usuario_id)
) ENGINE = InnoDB;

CREATE TABLE autorizacao_itens (
    autorizacao_item_id   INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    autorizacao_id        INT UNSIGNED  NOT NULL,
    produto_id            INT UNSIGNED  NOT NULL,
    quantidade_produzida  DECIMAL(12,4) NOT NULL CHECK (quantidade_produzida > 0),
    CONSTRAINT fk_autorizacao_itens_autorizacao FOREIGN KEY (autorizacao_id)
        REFERENCES autorizacoes_producao(autorizacao_id),
    CONSTRAINT fk_autorizacao_itens_produto FOREIGN KEY (produto_id)
        REFERENCES produtos(produto_id)
) ENGINE = InnoDB;

-- ============================================================================
-- 4) MOVIMENTAÇÃO DE ESTOQUE (entradas e saídas de ingredientes)
-- Alimenta o "Histórico de movimento". uuid_cliente só é preenchido nos
-- eventos que o navegador gera direto (reposição); os demais movimentos
-- são efeito de uma operação já idempotente.
-- ============================================================================

CREATE TABLE movimentacoes_estoque (
    movimentacao_id      BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    ingrediente_id       INT UNSIGNED  NOT NULL,
    tipo_movimento       ENUM('ENTRADA', 'SAIDA') NOT NULL,
    quantidade           DECIMAL(12,4) NOT NULL CHECK (quantidade >= 0),
    origem_tipo          ENUM('CADASTRO_INICIAL', 'REPOSICAO', 'PRODUCAO', 'AJUSTE', 'EXCLUSAO') NOT NULL,
    autorizacao_id       INT UNSIGNED  NULL,
        -- preenchido só quando origem_tipo = 'PRODUCAO'
    uuid_cliente         CHAR(36)      NULL,
    data_evento_cliente  DATETIME      NULL,
    usuario_id           INT UNSIGNED  NULL,
    data_movimento       DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    observacao           VARCHAR(255)  NULL,
    CONSTRAINT uq_movimentacoes_uuid_cliente UNIQUE (uuid_cliente),
    CONSTRAINT fk_movimentacoes_ingrediente FOREIGN KEY (ingrediente_id)
        REFERENCES ingredientes(ingrediente_id),
    CONSTRAINT fk_movimentacoes_autorizacao FOREIGN KEY (autorizacao_id)
        REFERENCES autorizacoes_producao(autorizacao_id),
    CONSTRAINT fk_movimentacoes_usuario FOREIGN KEY (usuario_id)
        REFERENCES usuarios(usuario_id)
) ENGINE = InnoDB;

CREATE INDEX ix_movimentacoes_data ON movimentacoes_estoque(data_movimento);

-- ============================================================================
-- 5) TRIGGERS
-- CHECK constraint não aceita subquery, então as regras que dependem de
-- outra tabela ficam aqui.
-- ============================================================================

DELIMITER $$

-- Ingrediente só pode ser guardado em Kg, L ou Un.
CREATE TRIGGER trg_ingredientes_valida_unidade_ins
BEFORE INSERT ON ingredientes
FOR EACH ROW
BEGIN
    DECLARE v_permite_estoque BOOLEAN;
    SELECT permite_estoque INTO v_permite_estoque
    FROM unidades_medida
    WHERE unidade_id = NEW.unidade_medida_id;

    IF v_permite_estoque IS NULL OR v_permite_estoque = FALSE THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Unidade de medida informada não é válida para estoque (use Kg, L ou Un).';
    END IF;
END$$

-- Mesma regra no UPDATE, e não deixa trocar a unidade de um ingrediente que
-- já está em receitas (a conversão g->Kg, ml->L deixaria de fazer sentido).
CREATE TRIGGER trg_ingredientes_valida_unidade_upd
BEFORE UPDATE ON ingredientes
FOR EACH ROW
BEGIN
    DECLARE v_permite_estoque BOOLEAN;
    DECLARE v_em_receitas     INT DEFAULT 0;

    SELECT permite_estoque INTO v_permite_estoque
    FROM unidades_medida
    WHERE unidade_id = NEW.unidade_medida_id;

    IF v_permite_estoque IS NULL OR v_permite_estoque = FALSE THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Unidade de medida informada não é válida para estoque (use Kg, L ou Un).';
    END IF;

    IF NEW.unidade_medida_id <> OLD.unidade_medida_id THEN
        SELECT COUNT(*) INTO v_em_receitas
        FROM receita_itens
        WHERE ingrediente_id = OLD.ingrediente_id;

        IF v_em_receitas > 0 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Não é possível trocar a unidade de um ingrediente que já está em receitas.';
        END IF;
    END IF;
END$$

-- A unidade da receita precisa ser da mesma grandeza do estoque do
-- ingrediente: Kg ou g com estoque em Kg; L ou ml com estoque em L; Un com Un.
CREATE TRIGGER trg_receita_itens_valida_unidade_ins
BEFORE INSERT ON receita_itens
FOR EACH ROW
BEGIN
    DECLARE v_base_receita    TINYINT UNSIGNED;
    DECLARE v_unidade_estoque TINYINT UNSIGNED;

    SELECT COALESCE(unidade_base_id, unidade_id) INTO v_base_receita
    FROM unidades_medida
    WHERE unidade_id = NEW.unidade_medida_id;

    SELECT unidade_medida_id INTO v_unidade_estoque
    FROM ingredientes
    WHERE ingrediente_id = NEW.ingrediente_id;

    IF v_base_receita IS NULL OR v_unidade_estoque IS NULL OR v_base_receita <> v_unidade_estoque THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Unidade da receita incompatível com o estoque do ingrediente (Kg/g, L/ml ou Un).';
    END IF;
END$$

CREATE TRIGGER trg_receita_itens_valida_unidade_upd
BEFORE UPDATE ON receita_itens
FOR EACH ROW
BEGIN
    DECLARE v_base_receita    TINYINT UNSIGNED;
    DECLARE v_unidade_estoque TINYINT UNSIGNED;

    SELECT COALESCE(unidade_base_id, unidade_id) INTO v_base_receita
    FROM unidades_medida
    WHERE unidade_id = NEW.unidade_medida_id;

    SELECT unidade_medida_id INTO v_unidade_estoque
    FROM ingredientes
    WHERE ingrediente_id = NEW.ingrediente_id;

    IF v_base_receita IS NULL OR v_unidade_estoque IS NULL OR v_base_receita <> v_unidade_estoque THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Unidade da receita incompatível com o estoque do ingrediente (Kg/g, L/ml ou Un).';
    END IF;
END$$

DELIMITER ;

-- ============================================================================
-- 6) VIEWS DE APOIO
-- ============================================================================

-- Tela de estoque. Filtre por ativo = TRUE para listar só os não excluídos.
CREATE OR REPLACE VIEW vw_estoque_atual AS
SELECT
    i.ingrediente_id,
    i.nome,
    i.quantidade_atual,
    um.sigla AS unidade_medida,
    i.quantidade_minima,
    (i.quantidade_atual <= i.quantidade_minima) AS alerta_estoque_baixo,
    i.ativo
FROM ingredientes i
INNER JOIN unidades_medida um ON um.unidade_id = i.unidade_medida_id;

-- "Ver receita do produto via tooltip" (somente produtos ativos).
CREATE OR REPLACE VIEW vw_receita_produto AS
SELECT
    p.produto_id,
    p.nome                 AS produto,
    i.ingrediente_id,
    i.nome                 AS ingrediente,
    ri.quantidade_necessaria,
    um.sigla               AS unidade_medida
FROM receita_itens ri
INNER JOIN produtos p        ON p.produto_id = ri.produto_id
INNER JOIN ingredientes i    ON i.ingrediente_id = ri.ingrediente_id
INNER JOIN unidades_medida um ON um.unidade_id = ri.unidade_medida_id
WHERE p.ativo = TRUE;

-- Histórico unificado ("Histórico de movimento"), exportável em planilha/PDF
-- pela API. Usa o horário REAL do evento (carimbado no navegador) quando
-- existe, e o horário de chegada ao servidor como alternativa.
--   Ingredientes: ENTRADA / SAIDA (cadastro, reposição, produção, exclusão)
--   Produtos:     ENTRADA (produção), CADASTRO e EXCLUSAO (sem quantidade)
CREATE OR REPLACE VIEW vw_historico_movimentacoes AS
SELECT
    'INGREDIENTE'  AS tipo_entidade,
    i.nome         AS entidade,
    m.tipo_movimento,
    m.quantidade,
    um.sigla       AS unidade_medida,
    m.origem_tipo,
    COALESCE(m.data_evento_cliente, m.data_movimento) AS data_evento,
    m.data_movimento AS data_sincronizado_em
FROM movimentacoes_estoque m
INNER JOIN ingredientes i ON i.ingrediente_id = m.ingrediente_id
INNER JOIN unidades_medida um ON um.unidade_id = i.unidade_medida_id

UNION ALL

SELECT
    'PRODUTO'                AS tipo_entidade,
    p.nome                   AS entidade,
    'ENTRADA'                AS tipo_movimento,
    ai.quantidade_produzida  AS quantidade,
    'Un'                     AS unidade_medida,
    'PRODUCAO'               AS origem_tipo,
    COALESCE(ap.data_evento_cliente, ap.data_finalizacao) AS data_evento,
    ap.data_finalizacao      AS data_sincronizado_em
FROM autorizacao_itens ai
INNER JOIN autorizacoes_producao ap ON ap.autorizacao_id = ai.autorizacao_id
INNER JOIN produtos p ON p.produto_id = ai.produto_id
WHERE ap.status_autorizacao = 'FINALIZADA'

UNION ALL

SELECT
    'PRODUTO'                AS tipo_entidade,
    p.nome                   AS entidade,
    e.tipo_evento            AS tipo_movimento,
    NULL                     AS quantidade,
    NULL                     AS unidade_medida,
    e.tipo_evento            AS origem_tipo,
    COALESCE(e.data_evento_cliente, e.data_registro) AS data_evento,
    e.data_registro          AS data_sincronizado_em
FROM eventos_produto e
INNER JOIN produtos p ON p.produto_id = e.produto_id;

-- ============================================================================
-- 7) STORED PROCEDURES — sincronização idempotente (localStorage -> banco)
-- ============================================================================

DELIMITER $$

-- ---------------------------------------------------------------------------
-- Cadastro de ingrediente (estoque.html) com quantidade inicial.
--   - não existe            -> cria com a quantidade informada      (CRIADO)
--   - existe mas excluído   -> reativa; o saldo recomeça na quantidade
--                              informada                            (REATIVADO)
--   - existe e está ativo   -> não altera nada (reenvio)            (JA_EXISTIA)
-- Gera o evento de cadastro (ENTRADA / CADASTRO_INICIAL) com a quantidade.
-- ---------------------------------------------------------------------------
CREATE PROCEDURE sp_cadastrar_ingrediente(
    IN  p_nome                VARCHAR(150),
    IN  p_unidade_medida_id   TINYINT UNSIGNED,
    IN  p_quantidade_inicial  DECIMAL(12,4),
    IN  p_data_evento_cliente DATETIME,
    IN  p_usuario_id          INT UNSIGNED,
    OUT p_ingrediente_id      INT UNSIGNED,
    OUT p_resultado           VARCHAR(20)
)
proc_body: BEGIN
    DECLARE v_ativo       BOOLEAN;
    DECLARE v_em_receitas INT DEFAULT 0;
    DECLARE v_qtd         DECIMAL(12,4);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    SET p_nome = TRIM(p_nome);
    SET v_qtd  = COALESCE(p_quantidade_inicial, 0);

    IF p_nome IS NULL OR p_nome = '' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'O nome do ingrediente é obrigatório.';
    END IF;

    IF v_qtd < 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'A quantidade inicial não pode ser negativa.';
    END IF;

    START TRANSACTION;

    SELECT ingrediente_id, ativo INTO p_ingrediente_id, v_ativo
    FROM ingredientes
    WHERE nome = p_nome
    FOR UPDATE;

    IF p_ingrediente_id IS NULL THEN
        INSERT INTO ingredientes (nome, quantidade_atual, unidade_medida_id)
        VALUES (p_nome, v_qtd, p_unidade_medida_id);

        SET p_ingrediente_id = LAST_INSERT_ID();
        SET p_resultado = 'CRIADO';

        INSERT INTO movimentacoes_estoque (ingrediente_id, tipo_movimento, quantidade, origem_tipo, data_evento_cliente, usuario_id)
        VALUES (p_ingrediente_id, 'ENTRADA', v_qtd, 'CADASTRO_INICIAL', p_data_evento_cliente, p_usuario_id);

    ELSEIF v_ativo = FALSE THEN
        -- Ingrediente excluído antes: reativa em vez de ficar invisível.
        -- A unidade só é trocada se ele não estiver em nenhuma receita.
        SELECT COUNT(*) INTO v_em_receitas
        FROM receita_itens
        WHERE ingrediente_id = p_ingrediente_id;

        UPDATE ingredientes
        SET ativo = TRUE,
            quantidade_atual = v_qtd,
            unidade_medida_id = CASE WHEN v_em_receitas > 0 THEN unidade_medida_id ELSE p_unidade_medida_id END
        WHERE ingrediente_id = p_ingrediente_id;

        SET p_resultado = 'REATIVADO';

        INSERT INTO movimentacoes_estoque (ingrediente_id, tipo_movimento, quantidade, origem_tipo, data_evento_cliente, usuario_id)
        VALUES (p_ingrediente_id, 'ENTRADA', v_qtd, 'CADASTRO_INICIAL', p_data_evento_cliente, p_usuario_id);

    ELSE
        SET p_resultado = 'JA_EXISTIA';
    END IF;

    COMMIT;
END proc_body$$

-- ---------------------------------------------------------------------------
-- Reposição de estoque (estoque.html). Identifica o ingrediente pelo NOME e
-- usa uuid_cliente para nunca aplicar duas vezes o mesmo reenvio.
-- ---------------------------------------------------------------------------
CREATE PROCEDURE sp_registrar_reposicao_estoque(
    IN  p_nome_ingrediente    VARCHAR(150),
    IN  p_quantidade          DECIMAL(12,4),
    IN  p_uuid_cliente        CHAR(36),
    IN  p_data_evento_cliente DATETIME,
    IN  p_usuario_id          INT UNSIGNED,
    OUT p_resultado           VARCHAR(20)
)
proc_body: BEGIN
    DECLARE v_ingrediente_id INT UNSIGNED;
    DECLARE v_ja_existe      INT DEFAULT 0;

    -- Reenvio simultâneo do mesmo evento: o UNIQUE do uuid barra o segundo.
    DECLARE EXIT HANDLER FOR 1062
    BEGIN
        ROLLBACK;
        SET p_resultado = 'JA_PROCESSADA';
    END;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    SET p_nome_ingrediente = TRIM(p_nome_ingrediente);

    IF p_uuid_cliente IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'uuid_cliente é obrigatório para registrar a reposição.';
    END IF;

    IF p_quantidade IS NULL OR p_quantidade <= 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'A quantidade de reposição deve ser positiva.';
    END IF;

    SELECT COUNT(*) INTO v_ja_existe
    FROM movimentacoes_estoque
    WHERE uuid_cliente = p_uuid_cliente;

    IF v_ja_existe > 0 THEN
        SET p_resultado = 'JA_PROCESSADA';
        LEAVE proc_body;
    END IF;

    START TRANSACTION;

    SELECT ingrediente_id INTO v_ingrediente_id
    FROM ingredientes
    WHERE nome = p_nome_ingrediente AND ativo = TRUE
    FOR UPDATE;

    IF v_ingrediente_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Ingrediente não encontrado (ou já excluído) para reposição.';
    END IF;

    UPDATE ingredientes
    SET quantidade_atual = quantidade_atual + p_quantidade
    WHERE ingrediente_id = v_ingrediente_id;

    INSERT INTO movimentacoes_estoque
        (ingrediente_id, tipo_movimento, quantidade, origem_tipo, uuid_cliente, data_evento_cliente, usuario_id)
    VALUES
        (v_ingrediente_id, 'ENTRADA', p_quantidade, 'REPOSICAO', p_uuid_cliente, p_data_evento_cliente, p_usuario_id);

    COMMIT;
    SET p_resultado = 'REGISTRADA';
END proc_body$$

-- ---------------------------------------------------------------------------
-- Exclusão de ingrediente (o "x" de estoque.html).
-- Exclusão lógica. Bloqueia se o ingrediente ainda está na receita de algum
-- produto ativo. O saldo restante sai do estoque como SAIDA / EXCLUSAO, para
-- o histórico fechar a conta.
-- ---------------------------------------------------------------------------
CREATE PROCEDURE sp_excluir_ingrediente(
    IN  p_nome_ingrediente    VARCHAR(150),
    IN  p_data_evento_cliente DATETIME,
    IN  p_usuario_id          INT UNSIGNED,
    OUT p_resultado           VARCHAR(20)
)
proc_body: BEGIN
    DECLARE v_ingrediente_id INT UNSIGNED;
    DECLARE v_ativo          BOOLEAN;
    DECLARE v_qtd            DECIMAL(12,4);
    DECLARE v_produtos       VARCHAR(500);
    DECLARE v_msg            VARCHAR(500);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    SET p_nome_ingrediente = TRIM(p_nome_ingrediente);

    START TRANSACTION;

    SELECT ingrediente_id, ativo, quantidade_atual INTO v_ingrediente_id, v_ativo, v_qtd
    FROM ingredientes
    WHERE nome = p_nome_ingrediente
    FOR UPDATE;

    IF v_ingrediente_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Ingrediente não encontrado.';
    END IF;

    IF v_ativo = FALSE THEN
        COMMIT;
        SET p_resultado = 'JA_EXCLUIDO';
        LEAVE proc_body;
    END IF;

    SELECT GROUP_CONCAT(p.nome ORDER BY p.nome SEPARATOR ', ') INTO v_produtos
    FROM receita_itens ri
    INNER JOIN produtos p ON p.produto_id = ri.produto_id
    WHERE ri.ingrediente_id = v_ingrediente_id
      AND p.ativo = TRUE;

    IF v_produtos IS NOT NULL THEN
        SET v_msg = LEFT(CONCAT('Ingrediente usado na receita de: ', v_produtos), 128);
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = v_msg;
    END IF;

    INSERT INTO movimentacoes_estoque (ingrediente_id, tipo_movimento, quantidade, origem_tipo, data_evento_cliente, usuario_id, observacao)
    VALUES (v_ingrediente_id, 'SAIDA', v_qtd, 'EXCLUSAO', p_data_evento_cliente, p_usuario_id, 'Exclusão do ingrediente');

    UPDATE ingredientes
    SET ativo = FALSE, quantidade_atual = 0
    WHERE ingrediente_id = v_ingrediente_id;

    COMMIT;
    SET p_resultado = 'EXCLUIDO';
END proc_body$$

-- ---------------------------------------------------------------------------
-- Cadastro de produto com a receita completa (produto.html).
-- p_itens_json:
--   [{"nome_ingrediente":"Farinha de trigo","quantidade_necessaria":200,"unidade_medida_id":2}, ...]
-- A receita enviada É a receita do produto: itens que não vieram são
-- removidos (isso também permite editar receita pelo mesmo caminho).
--   - Ingrediente que não existe é criado com saldo 0, na unidade BASE (g->Kg, ml->L).
--   - Ingrediente que foi excluído é reativado (saldo 0).
--   - Produto novo ou reativado gera evento de CADASTRO para o histórico.
-- Resultado: CRIADO | REATIVADO | ATUALIZADO (já existia; receita sincronizada).
-- ---------------------------------------------------------------------------
CREATE PROCEDURE sp_sincronizar_produto_com_receita(
    IN  p_nome_produto        VARCHAR(150),
    IN  p_itens_json          JSON,
    IN  p_data_evento_cliente DATETIME,
    IN  p_usuario_id          INT UNSIGNED,
    OUT p_produto_id          INT UNSIGNED,
    OUT p_resultado           VARCHAR(20)
)
proc_body: BEGIN
    DECLARE v_ativo      BOOLEAN;
    DECLARE v_total      INT DEFAULT 0;
    DECLARE v_invalidos  INT DEFAULT 0;
    DECLARE v_repetidos  INT DEFAULT 0;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        DROP TEMPORARY TABLE IF EXISTS tmp_itens_receita;
        DROP TEMPORARY TABLE IF EXISTS tmp_ingredientes_novos;
        DROP TEMPORARY TABLE IF EXISTS tmp_ingredientes_evento;
        ROLLBACK;
        RESIGNAL;
    END;

    SET p_nome_produto = TRIM(p_nome_produto);

    IF p_nome_produto IS NULL OR p_nome_produto = '' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'O nome do produto é obrigatório.';
    END IF;

    IF p_itens_json IS NULL OR JSON_TYPE(p_itens_json) <> 'ARRAY' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'A receita deve ser uma lista (JSON) de ingredientes.';
    END IF;

    -- Itens recebidos do navegador, validados antes de gravar qualquer coisa.
    DROP TEMPORARY TABLE IF EXISTS tmp_itens_receita;
    CREATE TEMPORARY TABLE tmp_itens_receita (
        nome_ingrediente      VARCHAR(150)     NULL,
        quantidade_necessaria DECIMAL(12,4)    NULL,
        unidade_medida_id     TINYINT UNSIGNED NULL
    );

    INSERT INTO tmp_itens_receita (nome_ingrediente, quantidade_necessaria, unidade_medida_id)
    SELECT TRIM(jt.nome_ingrediente), jt.quantidade_necessaria, jt.unidade_medida_id
    FROM JSON_TABLE(
        p_itens_json, '$[*]'
        COLUMNS (
            nome_ingrediente      VARCHAR(150)     PATH '$.nome_ingrediente',
            quantidade_necessaria DECIMAL(12,4)    PATH '$.quantidade_necessaria',
            unidade_medida_id     TINYINT UNSIGNED PATH '$.unidade_medida_id'
        )
    ) AS jt;

    SELECT COUNT(*) INTO v_total FROM tmp_itens_receita;
    IF v_total = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'A receita precisa ter pelo menos um ingrediente.';
    END IF;

    SELECT COUNT(*) INTO v_invalidos
    FROM tmp_itens_receita t
    LEFT JOIN unidades_medida um ON um.unidade_id = t.unidade_medida_id
    WHERE t.nome_ingrediente IS NULL OR t.nome_ingrediente = ''
       OR t.quantidade_necessaria IS NULL OR t.quantidade_necessaria <= 0
       OR um.unidade_id IS NULL;
    IF v_invalidos > 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Item de receita inválido: nome vazio, quantidade <= 0 ou unidade desconhecida.';
    END IF;

    -- COUNT(DISTINCT) respeita a collation: "Óleo" e "oleo" contam como um só.
    SELECT COUNT(*) - COUNT(DISTINCT nome_ingrediente) INTO v_repetidos FROM tmp_itens_receita;
    IF v_repetidos > 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Há ingrediente repetido na receita.';
    END IF;

    START TRANSACTION;

    -- 1) Produto: cria, reativa ou apenas localiza (idempotente pelo nome)
    SELECT produto_id, ativo INTO p_produto_id, v_ativo
    FROM produtos
    WHERE nome = p_nome_produto
    FOR UPDATE;

    IF p_produto_id IS NULL THEN
        INSERT INTO produtos (nome) VALUES (p_nome_produto);
        SET p_produto_id = LAST_INSERT_ID();
        SET p_resultado = 'CRIADO';

        INSERT INTO eventos_produto (produto_id, tipo_evento, data_evento_cliente, usuario_id)
        VALUES (p_produto_id, 'CADASTRO', p_data_evento_cliente, p_usuario_id);

    ELSEIF v_ativo = FALSE THEN
        UPDATE produtos SET ativo = TRUE WHERE produto_id = p_produto_id;
        SET p_resultado = 'REATIVADO';

        INSERT INTO eventos_produto (produto_id, tipo_evento, data_evento_cliente, usuario_id)
        VALUES (p_produto_id, 'CADASTRO', p_data_evento_cliente, p_usuario_id);

    ELSE
        SET p_resultado = 'ATUALIZADO';
    END IF;

    -- 2) Ingredientes que precisam de evento de cadastro (reativados + novos)
    DROP TEMPORARY TABLE IF EXISTS tmp_ingredientes_evento;
    CREATE TEMPORARY TABLE tmp_ingredientes_evento (
        ingrediente_id INT UNSIGNED NOT NULL
    );

    -- 2a) citados na receita mas excluídos: reativa (saldo já está em 0)
    INSERT INTO tmp_ingredientes_evento (ingrediente_id)
    SELECT DISTINCT i.ingrediente_id
    FROM ingredientes i
    INNER JOIN tmp_itens_receita t ON t.nome_ingrediente = i.nome
    WHERE i.ativo = FALSE;

    UPDATE ingredientes i
    INNER JOIN tmp_ingredientes_evento e ON e.ingrediente_id = i.ingrediente_id
    SET i.ativo = TRUE;

    -- 2b) citados na receita e inexistentes: cria com saldo 0 na unidade BASE
    DROP TEMPORARY TABLE IF EXISTS tmp_ingredientes_novos;
    CREATE TEMPORARY TABLE tmp_ingredientes_novos (
        nome              VARCHAR(150)     NOT NULL,
        unidade_medida_id TINYINT UNSIGNED NOT NULL
    );

    INSERT INTO tmp_ingredientes_novos (nome, unidade_medida_id)
    SELECT t.nome_ingrediente, COALESCE(um.unidade_base_id, t.unidade_medida_id)
    FROM tmp_itens_receita t
    INNER JOIN unidades_medida um ON um.unidade_id = t.unidade_medida_id
    WHERE NOT EXISTS (
        SELECT 1 FROM ingredientes i WHERE i.nome = t.nome_ingrediente
    );

    INSERT INTO ingredientes (nome, quantidade_atual, unidade_medida_id)
    SELECT nome, 0, unidade_medida_id FROM tmp_ingredientes_novos;

    INSERT INTO tmp_ingredientes_evento (ingrediente_id)
    SELECT i.ingrediente_id
    FROM ingredientes i
    INNER JOIN tmp_ingredientes_novos n ON n.nome = i.nome;

    INSERT INTO movimentacoes_estoque (ingrediente_id, tipo_movimento, quantidade, origem_tipo, data_evento_cliente, usuario_id)
    SELECT ingrediente_id, 'ENTRADA', 0, 'CADASTRO_INICIAL', p_data_evento_cliente, p_usuario_id
    FROM tmp_ingredientes_evento;

    -- 3) Receita: grava/atualiza os itens enviados (a trigger valida a unidade)
    INSERT INTO receita_itens (produto_id, ingrediente_id, quantidade_necessaria, unidade_medida_id)
    SELECT p_produto_id, i.ingrediente_id, t.quantidade_necessaria, t.unidade_medida_id
    FROM tmp_itens_receita t
    INNER JOIN ingredientes i ON i.nome = t.nome_ingrediente
    ON DUPLICATE KEY UPDATE
        quantidade_necessaria = VALUES(quantidade_necessaria),
        unidade_medida_id     = VALUES(unidade_medida_id);

    -- 4) ...e remove da receita o que não foi enviado
    DELETE ri
    FROM receita_itens ri
    LEFT JOIN (
        SELECT i.ingrediente_id
        FROM tmp_itens_receita t
        INNER JOIN ingredientes i ON i.nome = t.nome_ingrediente
    ) enviados ON enviados.ingrediente_id = ri.ingrediente_id
    WHERE ri.produto_id = p_produto_id
      AND enviados.ingrediente_id IS NULL;

    DROP TEMPORARY TABLE IF EXISTS tmp_itens_receita;
    DROP TEMPORARY TABLE IF EXISTS tmp_ingredientes_novos;
    DROP TEMPORARY TABLE IF EXISTS tmp_ingredientes_evento;
    COMMIT;
END proc_body$$

-- ---------------------------------------------------------------------------
-- Exclusão de produto (o "x" de produto.html). Exclusão lógica: a receita e
-- o histórico de produção continuam existindo. Gera evento de EXCLUSAO.
-- ---------------------------------------------------------------------------
CREATE PROCEDURE sp_excluir_produto(
    IN  p_nome_produto        VARCHAR(150),
    IN  p_data_evento_cliente DATETIME,
    IN  p_usuario_id          INT UNSIGNED,
    OUT p_resultado           VARCHAR(20)
)
proc_body: BEGIN
    DECLARE v_produto_id INT UNSIGNED;
    DECLARE v_ativo      BOOLEAN;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    SET p_nome_produto = TRIM(p_nome_produto);

    START TRANSACTION;

    SELECT produto_id, ativo INTO v_produto_id, v_ativo
    FROM produtos
    WHERE nome = p_nome_produto
    FOR UPDATE;

    IF v_produto_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Produto não encontrado.';
    END IF;

    IF v_ativo = FALSE THEN
        COMMIT;
        SET p_resultado = 'JA_EXCLUIDO';
        LEAVE proc_body;
    END IF;

    UPDATE produtos SET ativo = FALSE WHERE produto_id = v_produto_id;

    INSERT INTO eventos_produto (produto_id, tipo_evento, data_evento_cliente, usuario_id)
    VALUES (v_produto_id, 'EXCLUSAO', p_data_evento_cliente, p_usuario_id);

    COMMIT;
    SET p_resultado = 'EXCLUIDO';
END proc_body$$

-- ---------------------------------------------------------------------------
-- Autorização de produção ("Finalizar Autorização"): cria E finaliza em uma
-- única operação atômica, identificada por uuid_cliente.
-- p_itens_json:
--   [{"nome_produto":"Salgados fritos","quantidade_produzida":10}, ...]
-- Passos: valida os produtos -> soma o consumo por ingrediente (receita x
-- quantidade, já convertido g->Kg / ml->L) -> se algum ingrediente não tem
-- saldo, NADA é debitado e o resultado é ESTOQUE_INSUFICIENTE com a lista em
-- p_faltantes (JSON) -> senão debita, registra as saídas e finaliza.
--
-- p_faltantes (quando ESTOQUE_INSUFICIENTE):
--   [{"ingrediente":"Óleo","unidade":"L","disponivel":9.5,"necessario":50,"faltante":40.5}]
-- ---------------------------------------------------------------------------
CREATE PROCEDURE sp_sincronizar_autorizacao_producao(
    IN  p_uuid_cliente         CHAR(36),
    IN  p_observacao           VARCHAR(500),
    IN  p_itens_json           JSON,
    IN  p_data_evento_cliente  DATETIME,
    IN  p_usuario_id           INT UNSIGNED,
    OUT p_autorizacao_id       INT UNSIGNED,
    OUT p_resultado            VARCHAR(25),
    OUT p_faltantes            JSON
)
proc_body: BEGIN
    DECLARE v_status        VARCHAR(15);
    DECLARE v_total         INT DEFAULT 0;
    DECLARE v_invalidos     INT DEFAULT 0;
    DECLARE v_inexistentes  INT DEFAULT 0;
    DECLARE v_nomes         VARCHAR(500);
    DECLARE v_faltantes     INT DEFAULT 0;
    DECLARE v_travados      INT DEFAULT 0;
    DECLARE v_msg           VARCHAR(500);

    -- Reenvio simultâneo do mesmo uuid: o UNIQUE barra o segundo.
    DECLARE EXIT HANDLER FOR 1062
    BEGIN
        ROLLBACK;
        DROP TEMPORARY TABLE IF EXISTS tmp_itens_autorizacao;
        DROP TEMPORARY TABLE IF EXISTS tmp_envolvidos;
        DROP TEMPORARY TABLE IF EXISTS tmp_consumo;
        SELECT autorizacao_id INTO p_autorizacao_id
        FROM autorizacoes_producao
        WHERE uuid_cliente = p_uuid_cliente;
        SET p_resultado = 'JA_PROCESSADA';
    END;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        DROP TEMPORARY TABLE IF EXISTS tmp_itens_autorizacao;
        DROP TEMPORARY TABLE IF EXISTS tmp_envolvidos;
        DROP TEMPORARY TABLE IF EXISTS tmp_consumo;
        ROLLBACK;
        RESIGNAL;
    END;

    SET p_autorizacao_id = NULL;
    SET p_resultado      = NULL;
    SET p_faltantes      = NULL;

    IF p_uuid_cliente IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'uuid_cliente é obrigatório para a autorização de produção.';
    END IF;

    -- Idempotência: esse uuid já chegou e foi finalizado? Reenvio -> no-op.
    SELECT autorizacao_id, status_autorizacao INTO p_autorizacao_id, v_status
    FROM autorizacoes_producao
    WHERE uuid_cliente = p_uuid_cliente;

    IF p_autorizacao_id IS NOT NULL THEN
        IF v_status = 'FINALIZADA' THEN
            SET p_resultado = 'JA_PROCESSADA';
            LEAVE proc_body;
        END IF;
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Esta autorização já existe e não está finalizada.';
    END IF;

    IF p_itens_json IS NULL OR JSON_TYPE(p_itens_json) <> 'ARRAY' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Os itens da autorização devem ser uma lista (JSON) de produtos.';
    END IF;

    -- Itens recebidos, com o produto já resolvido pelo NOME (só produtos ativos)
    DROP TEMPORARY TABLE IF EXISTS tmp_itens_autorizacao;
    CREATE TEMPORARY TABLE tmp_itens_autorizacao (
        nome_produto          VARCHAR(150)  NULL,
        quantidade_produzida  DECIMAL(12,4) NULL,
        produto_id            INT UNSIGNED  NULL
    );

    INSERT INTO tmp_itens_autorizacao (nome_produto, quantidade_produzida)
    SELECT TRIM(jt.nome_produto), jt.quantidade_produzida
    FROM JSON_TABLE(
        p_itens_json, '$[*]'
        COLUMNS (
            nome_produto          VARCHAR(150)  PATH '$.nome_produto',
            quantidade_produzida  DECIMAL(12,4) PATH '$.quantidade_produzida'
        )
    ) AS jt;

    UPDATE tmp_itens_autorizacao t
    INNER JOIN produtos p ON p.nome = t.nome_produto AND p.ativo = TRUE
    SET t.produto_id = p.produto_id;

    SELECT COUNT(*) INTO v_total FROM tmp_itens_autorizacao;
    IF v_total = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'A autorização precisa ter pelo menos um produto.';
    END IF;

    SELECT COUNT(*) INTO v_invalidos
    FROM tmp_itens_autorizacao
    WHERE nome_produto IS NULL OR nome_produto = ''
       OR quantidade_produzida IS NULL OR quantidade_produzida <= 0;
    IF v_invalidos > 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Item inválido na autorização: produto vazio ou quantidade <= 0.';
    END IF;

    SELECT COUNT(*), GROUP_CONCAT(nome_produto ORDER BY nome_produto SEPARATOR ', ')
    INTO v_inexistentes, v_nomes
    FROM tmp_itens_autorizacao
    WHERE produto_id IS NULL;
    IF v_inexistentes > 0 THEN
        SET v_msg = LEFT(CONCAT('Produto não encontrado (ou excluído): ', v_nomes), 128);
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = v_msg;
    END IF;

    START TRANSACTION;

    INSERT INTO autorizacoes_producao (uuid_cliente, observacao, usuario_id, data_evento_cliente)
    VALUES (p_uuid_cliente, p_observacao, p_usuario_id, p_data_evento_cliente);

    SET p_autorizacao_id = LAST_INSERT_ID();

    INSERT INTO autorizacao_itens (autorizacao_id, produto_id, quantidade_produzida)
    SELECT p_autorizacao_id, produto_id, quantidade_produzida
    FROM tmp_itens_autorizacao;

    -- Trava os ingredientes envolvidos para outra transação não debitar o
    -- mesmo insumo ao mesmo tempo (sem devolver result set ao cliente).
    DROP TEMPORARY TABLE IF EXISTS tmp_envolvidos;
    CREATE TEMPORARY TABLE tmp_envolvidos (
        ingrediente_id INT UNSIGNED NOT NULL
    );

    INSERT INTO tmp_envolvidos (ingrediente_id)
    SELECT DISTINCT ri.ingrediente_id
    FROM autorizacao_itens ai
    INNER JOIN receita_itens ri ON ri.produto_id = ai.produto_id
    WHERE ai.autorizacao_id = p_autorizacao_id;

    SELECT COUNT(*) INTO v_travados
    FROM ingredientes i
    INNER JOIN tmp_envolvidos e ON e.ingrediente_id = i.ingrediente_id
    FOR UPDATE;

    -- Consumo total por ingrediente, convertido para a unidade base do estoque
    DROP TEMPORARY TABLE IF EXISTS tmp_consumo;
    CREATE TEMPORARY TABLE tmp_consumo AS
    SELECT
        i.ingrediente_id,
        i.nome,
        i.unidade_medida_id,
        i.quantidade_atual,
        ROUND(SUM(ri.quantidade_necessaria * um.fator_conversao_para_base * ai.quantidade_produzida), 4) AS quantidade_total_necessaria
    FROM autorizacao_itens ai
    INNER JOIN receita_itens ri ON ri.produto_id = ai.produto_id
    INNER JOIN unidades_medida um ON um.unidade_id = ri.unidade_medida_id
    INNER JOIN ingredientes i ON i.ingrediente_id = ri.ingrediente_id
    WHERE ai.autorizacao_id = p_autorizacao_id
    GROUP BY i.ingrediente_id, i.nome, i.unidade_medida_id, i.quantidade_atual;

    SELECT COUNT(*) INTO v_faltantes
    FROM tmp_consumo
    WHERE quantidade_atual < quantidade_total_necessaria;

    IF v_faltantes > 0 THEN
        -- Falta insumo: nada é debitado, nada fica gravado (inclusive o
        -- cabeçalho). O cliente pode tentar de novo depois de repor.
        SELECT JSON_ARRAYAGG(
                   JSON_OBJECT(
                       'ingrediente', c.nome,
                       'unidade',     um.sigla,
                       'disponivel',  c.quantidade_atual,
                       'necessario',  c.quantidade_total_necessaria,
                       'faltante',    c.quantidade_total_necessaria - c.quantidade_atual
                   )
               )
        INTO p_faltantes
        FROM tmp_consumo c
        INNER JOIN unidades_medida um ON um.unidade_id = c.unidade_medida_id
        WHERE c.quantidade_atual < c.quantidade_total_necessaria;

        ROLLBACK;
        DROP TEMPORARY TABLE IF EXISTS tmp_itens_autorizacao;
        DROP TEMPORARY TABLE IF EXISTS tmp_envolvidos;
        DROP TEMPORARY TABLE IF EXISTS tmp_consumo;
        SET p_autorizacao_id = NULL;
        SET p_resultado = 'ESTOQUE_INSUFICIENTE';
        LEAVE proc_body;
    END IF;

    UPDATE ingredientes i
    INNER JOIN tmp_consumo c ON c.ingrediente_id = i.ingrediente_id
    SET i.quantidade_atual = i.quantidade_atual - c.quantidade_total_necessaria;

    INSERT INTO movimentacoes_estoque (ingrediente_id, tipo_movimento, quantidade, origem_tipo, autorizacao_id, data_evento_cliente, usuario_id)
    SELECT ingrediente_id, 'SAIDA', quantidade_total_necessaria, 'PRODUCAO', p_autorizacao_id, p_data_evento_cliente, p_usuario_id
    FROM tmp_consumo;

    UPDATE autorizacoes_producao
    SET data_finalizacao = NOW(),
        status_autorizacao = 'FINALIZADA'
    WHERE autorizacao_id = p_autorizacao_id;

    DROP TEMPORARY TABLE IF EXISTS tmp_itens_autorizacao;
    DROP TEMPORARY TABLE IF EXISTS tmp_envolvidos;
    DROP TEMPORARY TABLE IF EXISTS tmp_consumo;
    COMMIT;
    SET p_resultado = 'FINALIZADA';
END proc_body$$

DELIMITER ;

-- ============================================================================
-- 8) EXEMPLO DE USO (referência — não faz parte do schema)
-- ============================================================================
--
-- -- Cadastro de insumo com quantidade inicial (1 = Kg, 3 = L, 5 = Un)
-- CALL sp_cadastrar_ingrediente('Farinha de trigo', 1, 25, '2026-09-15 08:00:00', NULL, @id_farinha, @res);
--
-- -- Reposição (uuid gerado no navegador; aqui UUID() só para teste)
-- SET @uuid_repos = UUID();
-- CALL sp_registrar_reposicao_estoque('Farinha de trigo', 10, @uuid_repos, '2026-09-15 08:01:00', NULL, @res);
-- CALL sp_registrar_reposicao_estoque('Farinha de trigo', 10, @uuid_repos, '2026-09-15 08:01:00', NULL, @res);
-- -- @res = 'JA_PROCESSADA' no segundo envio; o saldo não dobra
--
-- -- Produto com receita (2 = g, 4 = ml). Óleo não existe: é criado com saldo 0 em L.
-- CALL sp_sincronizar_produto_com_receita(
--     'Salgados fritos',
--     '[{"nome_ingrediente":"Farinha de trigo","quantidade_necessaria":200,"unidade_medida_id":2},
--       {"nome_ingrediente":"Óleo","quantidade_necessaria":50,"unidade_medida_id":4}]',
--     '2026-09-15 08:05:00', NULL, @id_produto, @res);
--
-- -- Autorização de produção
-- SET @uuid_aut = UUID();
-- CALL sp_sincronizar_autorizacao_producao(
--     @uuid_aut, NULL,
--     '[{"nome_produto":"Salgados fritos","quantidade_produzida":10}]',
--     '2026-09-15 09:00:00', NULL, @id_aut, @res, @faltantes);
-- SELECT @id_aut, @res, @faltantes;
-- -- @res = 'FINALIZADA'; se faltar insumo: 'ESTOQUE_INSUFICIENTE' e @faltantes
-- -- traz a lista. Reenviar o MESMO @uuid_aut devolve 'JA_PROCESSADA'.
--
-- -- Exclusões
-- CALL sp_excluir_produto('Salgados fritos', NULL, NULL, @res);
-- CALL sp_excluir_ingrediente('Óleo', NULL, NULL, @res);
--
-- SELECT * FROM vw_estoque_atual WHERE ativo = TRUE;
-- SELECT * FROM vw_receita_produto;
-- SELECT * FROM vw_historico_movimentacoes ORDER BY data_evento DESC;
-- ============================================================================
