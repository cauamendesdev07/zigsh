const std = @import("std");
 
const ParsedCommand = struct {
    args: std.ArrayList([]const u8),
    stdin_file: ?[]const u8 = null,
    stdout_file: ?[]const u8 = null,
    stderr_file: ?[]const u8 = null,
    is_background: bool = false,
 
    pub fn init(allocator: std.mem.Allocator) ParsedCommand {
        return .{
            .args = std.ArrayList([]const u8).init(allocator),
        };
    }
 
    pub fn deinit(self: *ParsedCommand) void {
        self.args.deinit();
    }
};
 
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

	_ = line.?; 

        // TODO 3: Fazer a tokenização da linha e identificar:
        // - Pipeline (|) separando sub-comandos
        // - Redirecionamentos (>, 2>, <)
        // - Operador de Background (& ao final do comando)
 
        // TODO 4: Verificar e executar Comandos Internos (cd, pwd, help, exit)
        
        // TODO 5: Configurar e disparar a execução de Comandos Externos via std.process.Child
 
        // TODO 6: Implementar a lógica de leitura/escrita para os arquivos de redirecionamento
 
        // TODO 7: Implementar o encadeamento I/O entre processos conectados por Pipeline (|)
        // Conectar o stdout.Pipe do processo 1 ao stdin.Pipe do processo 2
 
        // TODO 8: Controle de Concorrência:
        // - Se cmd.is_background == true: exibir mensagem de background e NÃO aguardar
        // - Se cmd.is_background == false: aguardar a finalização dos processos filhos via child.wait()
    }
}
