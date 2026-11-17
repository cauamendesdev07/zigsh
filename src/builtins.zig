const std = @import("std");
const parser = @import("parser.zig");

pub const Resultado = enum {
    nao_tratado,
    tratado,
};

const mensagem_ajuda =
    " \n" ++
    "========== ZIGSH ==========\n" ++
    "Shell minimalista desenvolvido em Zig.\n" ++
    "\n" ++
    "Comandos internos disponíveis:\n" ++
    "\n" ++
    "  cd <diretorio>  Altera o diretório atual.\n" ++
    "  pwd             Exibe o diretório atual.\n" ++
    "  help            Exibe esta mensagem.\n" ++
    "  exit [codigo]   Encerra o Shell.\n" ++
    "\n" ++
    "==========================\n";

/// Executa o comando interno, quando houver um.
pub fn executar(
    comando: *const parser.Comando,
    io: std.Io,
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
) !Resultado {
    if (comando.estaVazio()) return .nao_tratado;

    const nome = comando.argumentos.items[0];

    if (std.mem.eql(u8, nome, "cd")) return executarCd(comando, io, writer);
    if (std.mem.eql(u8, nome, "pwd")) return executarPwd(io, allocator, writer);
    if (std.mem.eql(u8, nome, "help")) return executarHelp(writer);
    if (std.mem.eql(u8, nome, "exit")) return executarExit(comando, writer);

    return .nao_tratado;
}

fn escreverAjuda(writer: *std.Io.Writer) !void {
    try writer.writeAll(mensagem_ajuda);
}

fn executarCd(
    comando: *const parser.Comando,
    io: std.Io,
    writer: *std.Io.Writer,
) !Resultado {
    if (comando.argumentos.items.len != 2) {
        try writer.writeAll("Uso: cd <diretorio>\n");
        return .tratado;
    }

    const diretorio = comando.argumentos.items[1];
    const novo_diretorio = std.Io.Dir.cwd().openDir(io, diretorio, .{}) catch |err| {
        try writer.print(
            "zigsh: cd: não foi possível acessar '{s}': {s}\n",
            .{ diretorio, @errorName(err) },
        );
        return .tratado;
    };
    defer novo_diretorio.close(io);

    std.process.setCurrentDir(io, novo_diretorio) catch |err| {
        try writer.print(
            "zigsh: cd: erro ao alterar diretório: {s}\n",
            .{@errorName(err)},
        );
    };

    return .tratado;
}

fn executarPwd(
    io: std.Io,
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
) !Resultado {
    const diretorio = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(diretorio);

    try writer.print("{s}\n", .{diretorio});
    return .tratado;
}

fn executarHelp(writer: *std.Io.Writer) !Resultado {
    try escreverAjuda(writer);
    return .tratado;
}

fn executarExit(
    comando: *const parser.Comando,
    writer: *std.Io.Writer,
) !Resultado {
    if (comando.argumentos.items.len > 2) {
        try writer.writeAll("Uso: exit [codigo]\n");
        return .tratado;
    }

    var codigo: u8 = 0;

    if (comando.argumentos.items.len == 2) {
        codigo = std.fmt.parseInt(u8, comando.argumentos.items[1], 10) catch {
            try writer.writeAll("zigsh: exit: código inválido\n");
            return .tratado;
        };
    }

    std.process.exit(codigo);
}

test "comando externo não é tratado como interno" {
    var comando = try parser.analisarComando(std.testing.allocator, "/bin/echo ola");
    defer comando.deinit(std.testing.allocator);

    var saida = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer saida.deinit();

    const resultado = try executar(
        &comando,
        std.testing.io,
        std.testing.allocator,
        &saida.writer,
    );

    try std.testing.expectEqual(Resultado.nao_tratado, resultado);
    try std.testing.expectEqual(@as(usize, 0), saida.written().len);
}

test "cd sem quantidade correta de argumentos exibe uso" {
    var comando = try parser.analisarComando(std.testing.allocator, "cd a b");
    defer comando.deinit(std.testing.allocator);

    var saida = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer saida.deinit();

    const resultado = try executar(
        &comando,
        std.testing.io,
        std.testing.allocator,
        &saida.writer,
    );

    try std.testing.expectEqual(Resultado.tratado, resultado);
    try std.testing.expectEqualStrings("Uso: cd <diretorio>\n", saida.written());
}

test "exit com código inválido informa o erro" {
    var comando = try parser.analisarComando(std.testing.allocator, "exit abc");
    defer comando.deinit(std.testing.allocator);

    var saida = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer saida.deinit();

    const resultado = try executar(
        &comando,
        std.testing.io,
        std.testing.allocator,
        &saida.writer,
    );

    try std.testing.expectEqual(Resultado.tratado, resultado);
    try std.testing.expectEqualStrings(
        "zigsh: exit: código inválido\n",
        saida.written(),
    );
}

test "exit com argumentos demais exibe uso" {
    var comando = try parser.analisarComando(std.testing.allocator, "exit 1 2");
    defer comando.deinit(std.testing.allocator);

    var saida = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer saida.deinit();

    const resultado = try executar(
        &comando,
        std.testing.io,
        std.testing.allocator,
        &saida.writer,
    );

    try std.testing.expectEqual(Resultado.tratado, resultado);
    try std.testing.expectEqualStrings("Uso: exit [codigo]\n", saida.written());
}

test "mensagem de ajuda permanece estável" {
    var saida = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer saida.deinit();

    try escreverAjuda(&saida.writer);

    const esperado =
        " \n" ++
        "========== ZIGSH ==========\n" ++
        "Shell minimalista desenvolvido em Zig.\n" ++
        "\n" ++
        "Comandos internos disponíveis:\n" ++
        "\n" ++
        "  cd <diretorio>  Altera o diretório atual.\n" ++
        "  pwd             Exibe o diretório atual.\n" ++
        "  help            Exibe esta mensagem.\n" ++
        "  exit [codigo]   Encerra o Shell.\n" ++
        "\n" ++
        "==========================\n";

    try std.testing.expectEqualStrings(esperado, saida.written());
}
