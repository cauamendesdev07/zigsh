const std = @import("std");
 
const ParsedCommand = struct {
    args: std.ArrayList([]const u8),
    stdin_file: ?[]const u8 = null,
    stdout_file: ?[]const u8 = null,
    stderr_file: ?[]const u8 = null,
    is_background: bool = false,
    
    pub fn init() ParsedCommand {
        return .{
            .args = std.ArrayList([]const u8).empty,
        };
    }

    pub fn deinit(self: *ParsedCommand, allocator: std.mem.Allocator) void {
        self.args.deinit(allocator);
    }
};
 
fn parseCommand(allocator: std.mem.Allocator, input: []const u8) !ParsedCommand {
    var cmd = ParsedCommand.init();
    errdefer cmd.deinit(allocator);

    var tokenizer = std.mem.tokenizeAny(u8, input, " \t\r\n");

    while (tokenizer.next()) |token| {
        if (std.mem.eql(u8, token, ">")) {
            if (tokenizer.next()) |file| {
                cmd.stdout_file = file;
            }
        } else if (std.mem.eql(u8, token, "2>")) {
            if (tokenizer.next()) |file| {
                cmd.stderr_file = file;
            }
        } else if (std.mem.eql(u8, token, "<")) {
            if (tokenizer.next()) |file| {
                cmd.stdin_file = file;
            }
        } else if (std.mem.eql(u8, token, "&")) {
            cmd.is_background = true;
        } else {
            try cmd.args.append(allocator, token);
        }
    }

    return cmd;
}

fn parseLine(allocator: std.mem.Allocator, input: []const u8) !std.ArrayList(ParsedCommand) {
    var pipeline = std.ArrayList(ParsedCommand).empty;
    errdefer {
        for (pipeline.items) |*cmd| {
            cmd.deinit(allocator);
        }
        pipeline.deinit(allocator);
    }

    var pipeline_iter = std.mem.splitScalar(u8, input, '|');

    while (pipeline_iter.next()) |segment| {
        const cmd = try parseCommand(allocator, segment);
        try pipeline.append(allocator, cmd);
    }

    // Se o último comando for marcado como background, propaga para a pipeline
    if (pipeline.items.len > 0) {
        const last_is_bg = pipeline.items[pipeline.items.len - 1].is_background;
        if (last_is_bg) {
            for (pipeline.items) |*cmd| {
                cmd.is_background = true;
            }
        }
    }

    return pipeline;
}


fn executarBuiltin(
    cmd: *const ParsedCommand,
    io: std.Io,
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
) !bool {
    // Não existe comando para executar.
    if (cmd.args.items.len == 0) return false;

    const comando = cmd.args.items[0];

    // BUILTIN: cd
    if (std.mem.eql(u8, comando, "cd")) {
        if (cmd.args.items.len != 2) {
            try writer.writeAll("Uso: cd <diretorio>\n");
            return true;
        }

        const diretorio = cmd.args.items[1];

        
	const novo_diretorio = std.Io.Dir.cwd().openDir(
	    io,
	    diretorio,
	    .{},
	) catch |err| {
	    try writer.print(
	        "zigsh: cd: não foi possível acessar '{s}': {s}\n",
	        .{ diretorio, @errorName(err) },
	    );
	    return true;
	};

	defer novo_diretorio.close(io);

	std.process.setCurrentDir(io, novo_diretorio) catch |err| {
	    try writer.print(
	        "zigsh: cd: erro ao alterar diretório: {s}\n",
	        .{@errorName(err)},
	    );
	};


        return true;
    }

    // BUILTIN: pwd
    if (std.mem.eql(u8, comando, "pwd")) {
        const diretorio = try std.process.currentPathAlloc(io, allocator);
        defer allocator.free(diretorio);

        try writer.print("{s}\n", .{diretorio});

        return true;
    }

    // BUILTIN: help
    if (std.mem.eql(u8, comando, "help")) {
        try writer.writeAll(
            \\ 
            \\========== ZIGSH ==========
            \\Shell minimalista desenvolvido em Zig.
            \\
            \\Comandos internos disponíveis:
            \\
            \\  cd <diretorio>  Altera o diretório atual.
            \\  pwd             Exibe o diretório atual.
            \\  help            Exibe esta mensagem.
            \\  exit [codigo]   Encerra o Shell.
            \\
            \\==========================
            \\
        );

        return true;
    }

    // BUILTIN: exit
    if (std.mem.eql(u8, comando, "exit")) {
        if (cmd.args.items.len > 2) {
            try writer.writeAll("Uso: exit [codigo]\n");
            return true;
        }

        var codigo: u8 = 0;

        if (cmd.args.items.len == 2) {
            codigo = std.fmt.parseInt(
                u8,
                cmd.args.items[1],
                10,
            ) catch {
                try writer.writeAll(
                    "zigsh: exit: código inválido\n",
                );
                return true;
            };
        }

        std.process.exit(codigo);
    }

    // Não é um comando interno.
    return false;
}


	
	
fn executarComandoExterno(
    cmd: *const ParsedCommand,
    io: std.Io,
    writer: *std.Io.Writer,
) !void {
    // Não há comando para executar.
    if (cmd.args.items.len == 0) return;

    var input_file: ?std.Io.File = null;

    if (cmd.stdin_file) |path| {
        input_file = std.Io.Dir.cwd().openFile(
            io,
            path,
            .{},
        ) catch |err| {
            try writer.print(
                "zigsh: não foi possível abrir '{s}': {s}\n",
                .{ path, @errorName(err) },
            );
            return;
        };
    }

    // Arquivo opcional para redirecionamento de stdout.
    var output_file: ?std.Io.File = null;
    
    var error_file: ?std.Io.File = null;

    if (cmd.stderr_file) |path| {
        error_file = std.Io.Dir.cwd().createFile(
            io,
            path,
            .{},
        ) catch |err| {
            try writer.print(
                "zigsh: não foi possível criar '{s}': {s}\n",
                .{ path, @errorName(err) },
            );
            return;
        };
     }

    if (cmd.stdout_file) |path| {
        output_file = std.Io.Dir.cwd().createFile(
            io,
            path,
            .{},
        ) catch |err| {
            try writer.print(
                "zigsh: não foi possível criar '{s}': {s}\n",
                .{ path, @errorName(err) },
            );
            return;
        };
    }

    // Fecha o arquivo quando a execução terminar.
    defer {
        if (output_file) |file| {
            file.close(io);
        }
    }

    defer {
        if (error_file) |file| {
            file.close(io);
        }
    }

    defer {
        if (input_file) |file| {
            file.close(io);
        }
    }

    // Cria o processo filho.
    var child = std.process.spawn(io, .{
        .argv = cmd.args.items,
        .stdin = if (input_file) |file| .{ .file = file } else .inherit,

        // Se houver arquivo, stdout será direcionado para ele.
        .stdout = if (output_file) |file| .{ .file = file } else .inherit,

        .stderr = if (error_file) |file| .{ .file = file } else .inherit,
    }) catch |err| {
        try writer.print(
            "zigsh: não foi possível executar '{s}': {s}\n",
            .{ cmd.args.items[0], @errorName(err) },
        );
        return;
    };

    // Se possuir &, não aguarda o término do processo.
    if (cmd.is_background) {
        try writer.writeAll(
            "[Processo disparado em segundo plano]\n",
        );
        return;
    }

    // Sem &, aguarda o processo terminar.
    _ = child.wait(io) catch |err| {
        try writer.print(
            "zigsh: erro ao aguardar processo: {s}\n",
            .{@errorName(err)},
        );
        return;
    };
}

/// Executa uma pipeline com dois ou mais comandos.
///
/// O stdout de cada comando (exceto o último) é criado como `.pipe` e o
/// descritor de leitura resultante é passado como stdin do próximo comando.
/// Em foreground, aguarda todos os filhos antes de retornar ao prompt.
fn executarPipeline(
    pipeline: []const ParsedCommand,
    io: std.Io,
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
) !void {
    if (pipeline.len < 2) return;

    var children = std.ArrayList(std.process.Child).empty;
    defer children.deinit(allocator);

    var is_background = false;
    for (pipeline) |cmd| {
        if (cmd.is_background) is_background = true;
    }

    for (pipeline, 0..) |*cmd, index| {
        if (cmd.args.items.len == 0) {
            try writer.writeAll("zigsh: pipeline com comando vazio\n");
            for (children.items) |*child| child.kill(io);
            return;
        }

        const is_first = index == 0;
        const is_last = index == pipeline.len - 1;

        var input_file: ?std.Io.File = null;
        defer {
            if (input_file) |file| file.close(io);
        }

        var output_file: ?std.Io.File = null;
        defer {
            if (output_file) |file| file.close(io);
        }

        var error_file: ?std.Io.File = null;
        defer {
            if (error_file) |file| file.close(io);
        }

        var stdin_behavior: std.process.SpawnOptions.StdIo = .inherit;

        if (is_first) {
            if (cmd.stdin_file) |path| {
                input_file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
                    try writer.print(
                        "zigsh: não foi possível abrir '{s}': {s}\n",
                        .{ path, @errorName(err) },
                    );
                    for (children.items) |*child| child.kill(io);
                    return;
                };

                stdin_behavior = .{ .file = input_file.? };
            }
        } else {
            // O descritor de leitura do pipe do comando anterior pertence ao
            // `Child` anterior; ele será fechado quando aquele processo for
            // aguardado (ou explicitamente no caso de background).
            const previous = &children.items[children.items.len - 1];
            stdin_behavior = .{ .file = previous.stdout.? };
        }

        var stdout_behavior: std.process.SpawnOptions.StdIo = .inherit;

        if (!is_last) {
            // Todo comando intermediário escreve no pipe lido pelo próximo.
            stdout_behavior = .pipe;
        } else if (cmd.stdout_file) |path| {
            output_file = std.Io.Dir.cwd().createFile(io, path, .{}) catch |err| {
                try writer.print(
                    "zigsh: não foi possível criar '{s}': {s}\n",
                    .{ path, @errorName(err) },
                );
                for (children.items) |*child| child.kill(io);
                return;
            };

            stdout_behavior = .{ .file = output_file.? };
        }

        var stderr_behavior: std.process.SpawnOptions.StdIo = .inherit;

        if (cmd.stderr_file) |path| {
            error_file = std.Io.Dir.cwd().createFile(io, path, .{}) catch |err| {
                try writer.print(
                    "zigsh: não foi possível criar '{s}': {s}\n",
                    .{ path, @errorName(err) },
                );
                for (children.items) |*child| child.kill(io);
                return;
            };

            stderr_behavior = .{ .file = error_file.? };
        }

        var child = std.process.spawn(io, .{
            .argv = cmd.args.items,
            .stdin = stdin_behavior,
            .stdout = stdout_behavior,
            .stderr = stderr_behavior,
        }) catch |err| {
            try writer.print(
                "zigsh: não foi possível executar '{s}': {s}\n",
                .{ cmd.args.items[0], @errorName(err) },
            );
            for (children.items) |*child_item| child_item.kill(io);
            return;
        };

        // O filho já possui suas próprias cópias dos descritores; o shell pode
        // fechar as cópias locais usadas apenas durante o spawn.
        if (input_file) |file| {
            file.close(io);
            input_file = null;
        }
        if (output_file) |file| {
            file.close(io);
            output_file = null;
        }
        if (error_file) |file| {
            file.close(io);
            error_file = null;
        }

        // Depois que o consumidor foi criado, o shell não precisa mais manter
        // aberta a ponta de leitura do pipe anterior. Mantê-la aberta faria o
        // produtor continuar bloqueado quando o consumidor terminasse antes
        // (por exemplo, `yes | head -n 1`).
        if (!is_first) {
            const previous = &children.items[children.items.len - 1];
            if (previous.stdout) |file| {
                file.close(io);
                previous.stdout = null;
            }
        }

        children.append(allocator, child) catch |err| {
            child.kill(io);
            for (children.items) |*child_item| child_item.kill(io);
            return err;
        };
    }

    if (is_background) {
        // Descarta as pontas dos pipes que pertencem ao shell. Os processos
        // filhos mantêm suas próprias cópias e continuam executando.
        for (children.items) |*child| {
            if (child.stdout) |file| {
                file.close(io);
                child.stdout = null;
            }
        }

        try writer.writeAll("[Processo disparado em segundo plano]\n");
        return;
    }

    // Aguarda todos os processos da pipeline antes de retornar ao prompt.
    for (children.items) |*child| {
        _ = child.wait(io) catch |err| {
            try writer.print(
                "zigsh: erro ao aguardar processo: {s}\n",
                .{@errorName(err)},
            );
        };
    }
}

// Utilização da assinatura idiomática Juicy Main em Zig 0.16.x
pub fn main(init: std.process.Init) !void {
    //_ = init; // Parâmetro de inicialização do processo em Zig 0.16.x
 
    //var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    //defer _ = gpa.deinit();
    //const allocator = gpa.allocator();
    const allocator = init.gpa;


    //const stdin = std.io.getStdIn().reader();
    //const stdout = std.io.getStdOut().writer();
    
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(
        init.io,
        &stdin_buffer,
    );

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(
        init.io,
        &stdout_buffer,
    ); 


    while (true) {
        // TODO 1: Exibir Prompt Dinâmico exibindo o diretório de trabalho atual (getCwd)
	const cwd = try std.process.currentPathAlloc(init.io, allocator);

	try stdout_writer.interface.print(
	    "zigsh [{s}]> ",
	    .{cwd},
	);

	try stdout_writer.interface.flush();

	allocator.free(cwd);        


        // TODO 2: Ler a linha digitada pelo usuário no stdin
        // Tratamento de EOF (Ctrl+D) para encerramento gracioso
	const line = stdin_reader.interface.takeDelimiter('\n') catch |err| switch (err) {
	    error.ReadFailed => return stdin_reader.err.?,
	    error.StreamTooLong => return err,
	};

	if (line == null) {
    		break;
	}
         
        const input = line.?;
 
        // TODO 3: Fazer a tokenização da linha e identificar:
	var pipeline = try parseLine(allocator, input);

       // - Pipeline (|) separando sub-comandos
        // - Redirecionamentos (>, 2>, <)
        // - Operador de Background (& ao final do comando)

	// Liberar a memória utilizada pelos comandos ao sair deste bloco.
	defer {
	    for (pipeline.items) |*cmd_item| {
	        cmd_item.deinit(allocator);
	    }
	    pipeline.deinit(allocator);
	}
 
        // TODO 4: Verificar e executar Comandos Internos
	// Nesta etapa, tratamos os built-ins quando existe apenas um comando.
	if (pipeline.items.len == 1) {
	    if (try executarBuiltin(
	        &pipeline.items[0],
	        init.io,
	        allocator,
	        &stdout_writer.interface,
	    )) {
	        try stdout_writer.interface.flush();
	        continue;
	    }
	}
	
	// Executa comandos externos e pipelines.
	if (pipeline.items.len == 1) {
	    try executarComandoExterno(
	        &pipeline.items[0],
	        init.io,
	        &stdout_writer.interface,
	    );
	} else {
	    try executarPipeline(
	        pipeline.items,
	        init.io,
	        allocator,
	        &stdout_writer.interface,
	    );
	}

	try stdout_writer.interface.flush();
    }
}
