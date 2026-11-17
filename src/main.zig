const std = @import("std");
const builtins = @import("builtins.zig");
const executor = @import("executor.zig");
const parser = @import("parser.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var entrada_buffer: [4096]u8 = undefined;
    var entrada = std.Io.File.stdin().readerStreaming(init.io, &entrada_buffer);

    var saida_buffer: [1024]u8 = undefined;
    var saida = std.Io.File.stdout().writerStreaming(init.io, &saida_buffer);

    while (true) {
        const diretorio = try std.process.currentPathAlloc(init.io, allocator);
        defer allocator.free(diretorio);

        try saida.interface.print("zigsh [{s}]> ", .{diretorio});
        try saida.interface.flush();

        const linha = entrada.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => return entrada.err.?,
            error.StreamTooLong => return err,
        };

        if (linha == null) break;

        var pipeline = try parser.analisarLinha(allocator, linha.?);
        defer parser.liberarPipeline(&pipeline, allocator);

        if (pipeline.items.len == 1) {
            const resultado = try builtins.executar(
                &pipeline.items[0],
                init.io,
                allocator,
                &saida.interface,
            );

            if (resultado == .tratado) {
                try saida.interface.flush();
                continue;
            }

            try executor.executarComandoExterno(
                &pipeline.items[0],
                init.io,
                &saida.interface,
            );
        } else {
            try executor.executarPipeline(
                pipeline.items,
                init.io,
                allocator,
                &saida.interface,
            );
        }

        try saida.interface.flush();
    }
}

test {
    _ = @import("parser.zig");
    _ = @import("builtins.zig");
    _ = @import("executor.zig");
}
