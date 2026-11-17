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

	    // Cria um novo processo filho.
	    var child = std.process.spawn(io, .{
	        .argv = cmd.args.items,
	        .stdin = .inherit,
	        .stdout = .inherit,
	        .stderr = .inherit,
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
	
	// TODO 5: Executar comandos externos.
	if (pipeline.items.len == 1) {
	    try executarComandoExterno(
	        &pipeline.items[0],
	        init.io,
	        &stdout_writer.interface,
	    );

	    try stdout_writer.interface.flush();
	}	

        // TODO 5: Configurar e disparar a execução de Comandos Externos via std.process.Child
 
        // TODO 6: Implementar a lógica de leitura/escrita para os arquivos de redirecionamento
 
        // TODO 7: Implementar o encadeamento I/O entre processos conectados por Pipeline (|)
        // Conectar o stdout.Pipe do processo 1 ao stdin.Pipe do processo 2
 
        // TODO 8: Controle de Concorrência:
        // - Se cmd.is_background == true: exibir mensagem de background e NÃO aguardar
        // - Se cmd.is_background == false: aguardar a finalização dos processos filhos via child.wait()
    }
}
