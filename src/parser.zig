const std = @import("std");

/// Um comando já separado em argumentos e redirecionamentos.
pub const Comando = struct {
    argumentos: std.ArrayList([]const u8),
    arquivo_entrada: ?[]const u8 = null,
    arquivo_saida: ?[]const u8 = null,
    arquivo_erro: ?[]const u8 = null,
    segundo_plano: bool = false,

    pub fn init() Comando {
        return .{
            .argumentos = std.ArrayList([]const u8).empty,
        };
    }

    pub fn deinit(self: *Comando, allocator: std.mem.Allocator) void {
        self.argumentos.deinit(allocator);
    }

    pub fn estaVazio(self: *const Comando) bool {
        return self.argumentos.items.len == 0;
    }
};

pub const Pipeline = std.ArrayList(Comando);

/// Converte um trecho da linha em um comando.
///
/// Os redirecionamentos são reconhecidos como tokens isolados. Caso o caminho
/// de um redirecionamento não seja informado, o token é descartado, mantendo o
/// comportamento original do shell.
pub fn analisarComando(allocator: std.mem.Allocator, entrada: []const u8) !Comando {
    var comando = Comando.init();
    errdefer comando.deinit(allocator);

    var tokenizador = std.mem.tokenizeAny(u8, entrada, " \t\r\n");

    while (tokenizador.next()) |token| {
        if (std.mem.eql(u8, token, ">")) {
            if (tokenizador.next()) |arquivo| {
                comando.arquivo_saida = arquivo;
            }
        } else if (std.mem.eql(u8, token, "2>")) {
            if (tokenizador.next()) |arquivo| {
                comando.arquivo_erro = arquivo;
            }
        } else if (std.mem.eql(u8, token, "<")) {
            if (tokenizador.next()) |arquivo| {
                comando.arquivo_entrada = arquivo;
            }
        } else if (std.mem.eql(u8, token, "&")) {
            comando.segundo_plano = true;
        } else {
            try comando.argumentos.append(allocator, token);
        }
    }

    return comando;
}

/// Separa a linha em comandos e propaga o `&` do último comando para toda a
/// pipeline. Isso permite que `cmd1 | cmd2 &` seja executada em background.
pub fn analisarLinha(allocator: std.mem.Allocator, entrada: []const u8) !Pipeline {
    var pipeline = Pipeline.empty;
    errdefer liberarPipeline(&pipeline, allocator);

    var trechos = std.mem.splitScalar(u8, entrada, '|');

    while (trechos.next()) |trecho| {
        var comando = try analisarComando(allocator, trecho);
        errdefer comando.deinit(allocator);
        try pipeline.append(allocator, comando);
    }

    if (pipeline.items.len > 0) {
        const ultimo = &pipeline.items[pipeline.items.len - 1];
        if (ultimo.segundo_plano) {
            for (pipeline.items) |*comando| {
                comando.segundo_plano = true;
            }
        }
    }

    return pipeline;
}

pub fn liberarPipeline(pipeline: *Pipeline, allocator: std.mem.Allocator) void {
    for (pipeline.items) |*comando| {
        comando.deinit(allocator);
    }
    pipeline.deinit(allocator);
}

test "analisa comando simples" {
    var pipeline = try analisarLinha(std.testing.allocator, "/bin/echo ola mundo");
    defer liberarPipeline(&pipeline, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), pipeline.items.len);
    const comando = &pipeline.items[0];

    try std.testing.expectEqual(@as(usize, 3), comando.argumentos.items.len);
    try std.testing.expectEqualStrings("/bin/echo", comando.argumentos.items[0]);
    try std.testing.expectEqualStrings("ola", comando.argumentos.items[1]);
    try std.testing.expectEqualStrings("mundo", comando.argumentos.items[2]);
    try std.testing.expect(!comando.segundo_plano);
}

test "analisa redirecionamentos" {
    var pipeline = try analisarLinha(
        std.testing.allocator,
        "/bin/cat < entrada.txt > saida.txt 2> erros.txt",
    );
    defer liberarPipeline(&pipeline, std.testing.allocator);

    const comando = &pipeline.items[0];
    try std.testing.expectEqualStrings("entrada.txt", comando.arquivo_entrada.?);
    try std.testing.expectEqualStrings("saida.txt", comando.arquivo_saida.?);
    try std.testing.expectEqualStrings("erros.txt", comando.arquivo_erro.?);
}

test "propaga background do último comando da pipeline" {
    var pipeline = try analisarLinha(
        std.testing.allocator,
        "/bin/cat arquivo.txt | /bin/grep termo &",
    );
    defer liberarPipeline(&pipeline, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), pipeline.items.len);
    try std.testing.expect(pipeline.items[0].segundo_plano);
    try std.testing.expect(pipeline.items[1].segundo_plano);
}

test "mantém comando vazio entre pipes" {
    var pipeline = try analisarLinha(
        std.testing.allocator,
        "/bin/echo a | | /bin/cat",
    );
    defer liberarPipeline(&pipeline, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), pipeline.items.len);
    try std.testing.expect(!pipeline.items[0].estaVazio());
    try std.testing.expect(pipeline.items[1].estaVazio());
    try std.testing.expect(!pipeline.items[2].estaVazio());
}

test "redirecionamento sem caminho não altera o comando" {
    var pipeline = try analisarLinha(std.testing.allocator, "/bin/echo x >");
    defer liberarPipeline(&pipeline, std.testing.allocator);

    const comando = &pipeline.items[0];
    try std.testing.expectEqual(@as(usize, 2), comando.argumentos.items.len);
    try std.testing.expect(comando.arquivo_saida == null);
}
