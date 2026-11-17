const std = @import("std");
const parser = @import("parser.zig");

const StdIo = std.process.SpawnOptions.StdIo;

/// Executa um único comando externo, aplicando os redirecionamentos.
pub fn executarComandoExterno(
    comando: *const parser.Comando,
    io: std.Io,
    writer: *std.Io.Writer,
) !void {
    if (comando.estaVazio()) return;

    var entrada: ?std.Io.File = null;
    defer fecharArquivo(io, &entrada);

    if (comando.arquivo_entrada) |caminho| {
        entrada = try abrirEntrada(io, writer, caminho) orelse return;
    }

    var erro: ?std.Io.File = null;
    defer fecharArquivo(io, &erro);

    if (comando.arquivo_erro) |caminho| {
        erro = try criarSaida(io, writer, caminho) orelse return;
    }

    var saida: ?std.Io.File = null;
    defer fecharArquivo(io, &saida);

    if (comando.arquivo_saida) |caminho| {
        saida = try criarSaida(io, writer, caminho) orelse return;
    }

    var filho = std.process.spawn(io, .{
        .argv = comando.argumentos.items,
        .stdin = stdioDeArquivo(entrada),
        .stdout = stdioDeArquivo(saida),
        .stderr = stdioDeArquivo(erro),
    }) catch |err| {
        try escreverErroExecucao(writer, comando.argumentos.items[0], err);
        return;
    };

    if (comando.segundo_plano) {
        try escreverMensagemSegundoPlano(writer);
        return;
    }

    _ = filho.wait(io) catch |err| {
        try escreverErroEspera(writer, err);
    };
}

/// Executa uma pipeline ligando o stdout de cada comando ao stdin do próximo.
///
/// Em foreground, aguarda todos os filhos antes de retornar ao prompt. Em
/// background, apenas dispara os processos e retorna imediatamente.
pub fn executarPipeline(
    pipeline: []const parser.Comando,
    io: std.Io,
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
) !void {
    if (pipeline.len < 2) return;

    var filhos = std.ArrayList(std.process.Child).empty;
    defer filhos.deinit(allocator);

    const segundo_plano = pipelineTemSegundoPlano(pipeline);

    for (pipeline, 0..) |*comando, indice| {
        if (comando.estaVazio()) {
            try writer.writeAll("zigsh: pipeline com comando vazio\n");
            encerrarFilhos(filhos.items, io);
            return;
        }

        const primeiro = indice == 0;
        const ultimo = indice == pipeline.len - 1;

        var entrada: ?std.Io.File = null;
        defer fecharArquivo(io, &entrada);

        var saida: ?std.Io.File = null;
        defer fecharArquivo(io, &saida);

        var erro: ?std.Io.File = null;
        defer fecharArquivo(io, &erro);

        var stdin_behavior: StdIo = .inherit;

        if (primeiro) {
            if (comando.arquivo_entrada) |caminho| {
                entrada = try abrirEntrada(io, writer, caminho) orelse {
                    encerrarFilhos(filhos.items, io);
                    return;
                };
                stdin_behavior = stdioDeArquivo(entrada);
            }
        } else {
            // O descritor de leitura pertence ao filho anterior. Ele é
            // fechado no shell assim que o consumidor for criado.
            stdin_behavior = .{ .file = filhos.items[filhos.items.len - 1].stdout.? };
        }

        var stdout_behavior: StdIo = .inherit;

        if (!ultimo) {
            stdout_behavior = .pipe;
        } else if (comando.arquivo_saida) |caminho| {
            saida = try criarSaida(io, writer, caminho) orelse {
                encerrarFilhos(filhos.items, io);
                return;
            };
            stdout_behavior = stdioDeArquivo(saida);
        }

        var stderr_behavior: StdIo = .inherit;

        if (comando.arquivo_erro) |caminho| {
            erro = try criarSaida(io, writer, caminho) orelse {
                encerrarFilhos(filhos.items, io);
                return;
            };
            stderr_behavior = stdioDeArquivo(erro);
        }

        var filho = std.process.spawn(io, .{
            .argv = comando.argumentos.items,
            .stdin = stdin_behavior,
            .stdout = stdout_behavior,
            .stderr = stderr_behavior,
        }) catch |err| {
            try escreverErroExecucao(writer, comando.argumentos.items[0], err);
            encerrarFilhos(filhos.items, io);
            return;
        };

        // O filho já recebeu cópias dos descritores. O shell só precisa manter
        // os arquivos de redirecionamento até este ponto.
        fecharArquivo(io, &entrada);
        fecharArquivo(io, &saida);
        fecharArquivo(io, &erro);

        // Fechar a leitura do pipe no shell é essencial: caso o consumidor
        // termine antes, o produtor recebe SIGPIPE em vez de bloquear para
        // sempre (por exemplo, `yes | head -n 1`).
        if (!primeiro) {
            const anterior = &filhos.items[filhos.items.len - 1];
            fecharArquivo(io, &anterior.stdout);
        }

        filhos.append(allocator, filho) catch |err| {
            filho.kill(io);
            encerrarFilhos(filhos.items, io);
            return err;
        };
    }

    if (segundo_plano) {
        try escreverMensagemSegundoPlano(writer);
        return;
    }

    for (filhos.items) |*filho| {
        _ = filho.wait(io) catch |err| {
            try escreverErroEspera(writer, err);
        };
    }
}

fn pipelineTemSegundoPlano(pipeline: []const parser.Comando) bool {
    for (pipeline) |comando| {
        if (comando.segundo_plano) return true;
    }
    return false;
}

fn abrirEntrada(
    io: std.Io,
    writer: *std.Io.Writer,
    caminho: []const u8,
) !?std.Io.File {
    return std.Io.Dir.cwd().openFile(io, caminho, .{}) catch |err| {
        try escreverErroAbertura(writer, caminho, err);
        return null;
    };
}

fn criarSaida(
    io: std.Io,
    writer: *std.Io.Writer,
    caminho: []const u8,
) !?std.Io.File {
    return std.Io.Dir.cwd().createFile(io, caminho, .{}) catch |err| {
        try escreverErroCriacao(writer, caminho, err);
        return null;
    };
}

fn stdioDeArquivo(arquivo: ?std.Io.File) StdIo {
    return if (arquivo) |file| .{ .file = file } else .inherit;
}

fn fecharArquivo(io: std.Io, arquivo: *?std.Io.File) void {
    if (arquivo.*) |file| {
        file.close(io);
        arquivo.* = null;
    }
}

fn encerrarFilhos(filhos: []std.process.Child, io: std.Io) void {
    for (filhos) |*filho| filho.kill(io);
}

fn escreverErroAbertura(
    writer: *std.Io.Writer,
    caminho: []const u8,
    err: anyerror,
) !void {
    try writer.print(
        "zigsh: não foi possível abrir '{s}': {s}\n",
        .{ caminho, @errorName(err) },
    );
}

fn escreverErroCriacao(
    writer: *std.Io.Writer,
    caminho: []const u8,
    err: anyerror,
) !void {
    try writer.print(
        "zigsh: não foi possível criar '{s}': {s}\n",
        .{ caminho, @errorName(err) },
    );
}

fn escreverErroExecucao(
    writer: *std.Io.Writer,
    comando: []const u8,
    err: anyerror,
) !void {
    try writer.print(
        "zigsh: não foi possível executar '{s}': {s}\n",
        .{ comando, @errorName(err) },
    );
}

fn escreverErroEspera(writer: *std.Io.Writer, err: anyerror) !void {
    try writer.print(
        "zigsh: erro ao aguardar processo: {s}\n",
        .{@errorName(err)},
    );
}

fn escreverMensagemSegundoPlano(writer: *std.Io.Writer) !void {
    try writer.writeAll("[Processo disparado em segundo plano]\n");
}

test "comando externo grava stdout no arquivo redirecionado" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const caminho = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/saida.txt",
        .{tmp.sub_path[0..]},
    );
    defer std.testing.allocator.free(caminho);

    var pipeline = try parser.analisarLinha(std.testing.allocator, "/bin/echo ola");
    defer parser.liberarPipeline(&pipeline, std.testing.allocator);

    pipeline.items[0].arquivo_saida = caminho;

    var saida = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer saida.deinit();

    try executarComandoExterno(&pipeline.items[0], std.testing.io, &saida.writer);

    const conteudo = try tmp.dir.readFileAlloc(
        std.testing.io,
        "saida.txt",
        std.testing.allocator,
        .limited(1024),
    );
    defer std.testing.allocator.free(conteudo);

    try std.testing.expectEqualStrings("ola\n", conteudo);
}

test "pipeline conecta stdout ao stdin" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const caminho = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/pipeline.txt",
        .{tmp.sub_path[0..]},
    );
    defer std.testing.allocator.free(caminho);

    var pipeline = try parser.analisarLinha(
        std.testing.allocator,
        "/bin/echo ola | /bin/cat",
    );
    defer parser.liberarPipeline(&pipeline, std.testing.allocator);

    pipeline.items[1].arquivo_saida = caminho;

    var saida = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer saida.deinit();

    try executarPipeline(
        pipeline.items,
        std.testing.io,
        std.testing.allocator,
        &saida.writer,
    );

    const conteudo = try tmp.dir.readFileAlloc(
        std.testing.io,
        "pipeline.txt",
        std.testing.allocator,
        .limited(1024),
    );
    defer std.testing.allocator.free(conteudo);

    try std.testing.expectEqualStrings("ola\n", conteudo);
}

test "pipeline vazia informa erro e não deixa processos" {
    var pipeline = try parser.analisarLinha(
        std.testing.allocator,
        "/bin/echo a | ",
    );
    defer parser.liberarPipeline(&pipeline, std.testing.allocator);

    var saida = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer saida.deinit();

    try executarPipeline(
        pipeline.items,
        std.testing.io,
        std.testing.allocator,
        &saida.writer,
    );

    try std.testing.expectEqualStrings(
        "zigsh: pipeline com comando vazio\n",
        saida.written(),
    );
}

test "comando em background exibe mensagem sem aguardar" {
    var pipeline = try parser.analisarLinha(std.testing.allocator, "/bin/true &");
    defer parser.liberarPipeline(&pipeline, std.testing.allocator);

    var saida = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer saida.deinit();

    try executarComandoExterno(&pipeline.items[0], std.testing.io, &saida.writer);

    try std.testing.expectEqualStrings(
        "[Processo disparado em segundo plano]\n",
        saida.written(),
    );
}
