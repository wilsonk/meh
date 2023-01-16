const std = @import("std");
const Queue = std.atomic.Queue;

const Buffer = @import("buffer.zig").Buffer;
const LSPMessages = @import("lsp_messages.zig");
const LSPThread = @import("lsp_thread.zig").LSPThread;
const U8Slice = @import("u8slice.zig").U8Slice;
const Vec2u = @import("vec.zig").Vec2u;
const Vec4u = @import("vec.zig").Vec4u;

pub const LSPError = error{
    MalformedResponse,
    MalformedUri,
    MissingRequestEntry,
    UnknownExtension,
};

// TODO(remy): comment
pub const LSPMessageType = enum {
    Completion,
    Definition,
    DidChange,
    Initialize,
    Initialized,
    LogMessage,
    TextDocumentDidOpen,
    References,
    // special, used internally to send the signal to stop the LSP server.
    MehExit,
};

// TODO(remy): comment
pub const LSPRequest = struct {
    json: U8Slice,
    message_type: LSPMessageType,
    request_id: i64,
    pub fn deinit(self: *LSPRequest) void {
        self.json.deinit();
    }
};

/// LSPResponse is used to transport a message sent from the LSP server back to the main app.
pub const LSPResponse = struct {
    allocator: std.mem.Allocator,
    message_type: LSPMessageType,
    log_message: ?U8Slice,
    completions: ?std.ArrayList(LSPCompletion),
    definitions: ?std.ArrayList(LSPPosition),
    references: ?std.ArrayList(LSPPosition),
    request_id: i64,
    pub fn init(allocator: std.mem.Allocator, request_id: i64, message_type: LSPMessageType) LSPResponse {
        return LSPResponse{
            .allocator = allocator,
            .message_type = message_type,
            .request_id = request_id,
            .completions = null,
            .definitions = null,
            .references = null,
            .log_message = null,
        };
    }
    pub fn deinit(self: LSPResponse) void {
        if (self.log_message) |log_message| {
            log_message.deinit();
        }
        if (self.completions) |comps| {
            for (comps.items) |completion| {
                completion.deinit();
            }
            comps.deinit();
        }
        if (self.definitions) |defs| {
            for (defs.items) |def| {
                def.deinit();
            }
            defs.deinit();
        }
        if (self.references) |refs| {
            for (refs.items) |ref| {
                ref.deinit();
            }
            refs.deinit();
        }
    }
};

pub const LSPPosition = struct {
    filepath: U8Slice,
    start: Vec2u,
    end: Vec2u,

    pub fn deinit(self: LSPPosition) void {
        self.filepath.deinit();
    }
};

pub const LSPCompletion = struct {
    insert_text: U8Slice,
    label: U8Slice,

    pub fn deinit(self: LSPCompletion) void {
        self.insert_text.deinit();
        self.label.deinit();
    }
};

// TODO(remy): comment
pub const LSPContext = struct {
    allocator: std.mem.Allocator,
    server_bin_path: []const u8,
    // queue used to communicate from the LSP thread to the main thread.
    response_queue: std.atomic.Queue(LSPResponse),
    // queue used to communicate from the main thread to the LSP thread.
    send_queue: std.atomic.Queue(LSPRequest),
    // LSP server thread is running
    is_running: std.atomic.Atomic(bool),
};

// TODO(remy): comment
pub const LSP = struct {
    allocator: std.mem.Allocator,
    context: *LSPContext,
    thread: std.Thread,
    current_request_id: i64,
    uri_working_dir: U8Slice,
    language_id: U8Slice,

    pub fn init(allocator: std.mem.Allocator, server_bin_path: []const u8, language_id: []const u8, working_dir: []const u8) !*LSP {
        // start a thread dealing with the LSP server in the background
        // create two queues for bidirectional communication
        var ctx = try allocator.create(LSPContext);
        ctx.allocator = allocator;
        ctx.response_queue = Queue(LSPResponse).init();
        ctx.send_queue = Queue(LSPRequest).init();
        ctx.server_bin_path = server_bin_path;

        // spawn the LSP thread
        const thread = try std.Thread.spawn(std.Thread.SpawnConfig{}, LSPThread.run, .{ctx});
        ctx.is_running = std.atomic.Atomic(bool).init(true);

        var uri_working_dir = try U8Slice.initFromSlice(allocator, "file://");
        try uri_working_dir.appendConst(working_dir);

        var lsp = try allocator.create(LSP);
        lsp.allocator = allocator;
        lsp.context = ctx;
        lsp.thread = thread;
        lsp.uri_working_dir = uri_working_dir;
        lsp.current_request_id = 0;
        lsp.language_id = try U8Slice.initFromSlice(allocator, language_id);
        return lsp;
    }

    pub fn deinit(self: *LSP) void {
        self.uri_working_dir.deinit();

        // send an exit message to the LSP thread
        // it'll process it and close the thread
        // --------------------------------------

        var is_running = self.context.is_running.load(.Acquire);
        if (is_running) {
            // send an exit message if the lsp thread is still running

            var exit_msg = U8Slice.initEmpty(self.allocator);
            exit_msg.appendConst("exit") catch |err| {
                std.log.err("LSP.deinit: can't allocate the bytes to send the exit message: {}", .{err});
                return;
            };
            var node = self.allocator.create(Queue(LSPRequest).Node) catch |err| {
                std.log.err("LSP.deinit: can't allocate the node to send the exit message: {}", .{err});
                return;
            };
            node.data = LSPRequest{
                .json = exit_msg,
                .message_type = .MehExit,
                .request_id = 0,
            };
            self.context.send_queue.put(node);

            // wait for thread to finish
            self.thread.join();
            std.log.debug("self.thread.joined()", .{});
        }

        // release all messages sent from the lsp thread to the app thread
        // ---------------------------------------------------------------

        // drain and release nodes in the `response_queue`
        while (!self.context.response_queue.isEmpty()) {
            var msg_node = self.context.response_queue.get().?;
            msg_node.data.deinit();
            self.allocator.destroy(msg_node);
        }

        // release the thread context memory
        // ---------------------------------

        self.allocator.destroy(self.context);

        self.language_id.deinit();
        self.allocator.destroy(self);
    }

    pub fn serverFromExtension(extension: []const u8) ![]const u8 {
        if (std.mem.eql(u8, extension, ".go")) {
            return "gopls";
        } else if (std.mem.eql(u8, extension, ".zig")) {
            return "zls";
        } else if (std.mem.eql(u8, extension, ".cpp")) {
            return "clangd";
        }
        return LSPError.UnknownExtension;
    }

    // LSP messages
    // ------------

    pub fn initialize(self: *LSP) !void {
        var msg_id = self.id();
        var json = try LSPWriter.initialize(self.allocator, msg_id, self.uri_working_dir.bytes());
        var request = LSPRequest{
            .json = json,
            .message_type = .Initialize,
            .request_id = msg_id,
        };
        try self.sendMessage(request);
    }

    pub fn initialized(self: *LSP) !void {
        var msg_id = self.id();
        var json = try LSPWriter.initialized(self.allocator);
        var request = LSPRequest{
            .json = json,
            .message_type = .Initialized,
            .request_id = msg_id,
        };
        try self.sendMessage(request);
    }

    pub fn openFile(self: *LSP, buffer: *Buffer) !void {
        if (self.context.is_running.load(.Acquire) == false) {
            return;
        }

        var msg_id = self.id();
        var uri = try toUri(self.allocator, buffer.fullpath.bytes());
        defer uri.deinit();
        var fulltext = try buffer.fulltext();
        defer fulltext.deinit();

        var json = try LSPWriter.textDocumentDidOpen(self.allocator, uri.bytes(), self.language_id.bytes(), fulltext.bytes());
        var request = LSPRequest{
            .json = json,
            .message_type = .TextDocumentDidOpen,
            .request_id = msg_id,
        };
        try self.sendMessage(request);
    }

    pub fn references(self: *LSP, buffer: *Buffer, cursor: Vec2u) !void {
        if (self.context.is_running.load(.Acquire) == false) {
            return;
        }

        var msg_id = self.id();
        var uri = try toUri(self.allocator, buffer.fullpath.bytes());
        defer uri.deinit();

        var json = try LSPWriter.textDocumentReference(self.allocator, msg_id, uri.bytes(), cursor);
        var request = LSPRequest{
            .json = json,
            .message_type = .References,
            .request_id = msg_id,
        };
        try self.sendMessage(request);
    }

    pub fn definition(self: *LSP, buffer: *Buffer, cursor: Vec2u) !void {
        if (self.context.is_running.load(.Acquire) == false) {
            return;
        }

        var msg_id = self.id();
        var uri = try toUri(self.allocator, buffer.fullpath.bytes());
        defer uri.deinit();

        var json = try LSPWriter.textDocumentDefinition(self.allocator, msg_id, uri.bytes(), cursor);
        var request = LSPRequest{
            .json = json,
            .message_type = .Definition,
            .request_id = msg_id,
        };
        try self.sendMessage(request);
    }

    pub fn completion(self: *LSP, buffer: *Buffer, cursor: Vec2u) !void {
        if (self.context.is_running.load(.Acquire) == false) {
            return;
        }

        var msg_id = self.id();
        var uri = try toUri(self.allocator, buffer.fullpath.bytes());
        defer uri.deinit();

        var json = try LSPWriter.textDocumentCompletion(self.allocator, msg_id, uri.bytes(), cursor);
        var request = LSPRequest{
            .json = json,
            .message_type = .Completion,
            .request_id = msg_id,
        };
        try self.sendMessage(request);
    }

    pub fn didChange(self: *LSP, buffer: *Buffer, lines_range: Vec2u) !void {
        if (self.context.is_running.load(.Acquire) == false) {
            return;
        }

        var msg_id = self.id();
        var uri = try toUri(self.allocator, buffer.fullpath.bytes());
        defer uri.deinit();

        var new_text = U8Slice.initEmpty(self.allocator);
        var i: usize = lines_range.a;
        var last_line_size: usize = 0;
        errdefer new_text.deinit();

        while (i <= lines_range.b) : (i += 1) {
            var line = try buffer.getLine(i);
            last_line_size = line.size();
            try new_text.appendConst(line.bytes());
        }

        defer new_text.deinit();

        var range = Vec4u{
            .a = 0,
            .b = lines_range.a,
            .c = last_line_size,
            .d = lines_range.b,
        };

        var json = try LSPWriter.textDocumentDidChange(self.allocator, msg_id, uri.bytes(), range, new_text.bytes());
        var request = LSPRequest{
            .json = json,
            .message_type = .DidChange,
            .request_id = msg_id,
        };
        try self.sendMessage(request);
    }

    // -

    fn sendMessage(self: LSP, request: LSPRequest) !void {
        if (self.context.is_running.load(.Acquire) == false) {
            return;
        }

        var node = try self.allocator.create(Queue(LSPRequest).Node);
        node.data = request;
        // send the JSON data to the other thread
        self.context.send_queue.put(node);
    }

    fn id(self: *LSP) i64 {
        defer self.current_request_id += 1;
        return self.current_request_id;
    }

    fn toUri(allocator: std.mem.Allocator, path: []const u8) !U8Slice {
        var uri = U8Slice.initEmpty(allocator);
        try uri.appendConst("file://");
        try uri.appendConst(path);
        return uri;
    }
};

pub const LSPWriter = struct {
    fn initialize(allocator: std.mem.Allocator, request_id: i64, uri_working_dir: []const u8) !U8Slice {
        var m = LSPMessages.initialize{
            .jsonrpc = "2.0",
            .id = request_id,
            .method = "initialize",
            .params = LSPMessages.initializeParams{
                .processId = 0,
                .capabilities = LSPMessages.initializeCapabilities{
                    .textDocument = LSPMessages.initializeTextDocumentCapabilities{
                        .references = LSPMessages.dynRegTrue,
                        .implementation = LSPMessages.dynRegTrue,
                        .definition = LSPMessages.dynRegTrue,
                    },
                },
                .workspaceFolders = [1]LSPMessages.workspaceFolder{
                    LSPMessages.workspaceFolder{
                        .uri = uri_working_dir,
                        .name = "workspace",
                    },
                },
            },
        };
        return try LSPWriter.toJson(allocator, m);
    }

    fn initialized(allocator: std.mem.Allocator) !U8Slice {
        var m = LSPMessages.initialized{
            .jsonrpc = "2.0",
            .params = LSPMessages.emptyStruct{},
            .method = "initialized",
        };
        return try LSPWriter.toJson(allocator, m);
    }

    fn textDocumentDidOpen(allocator: std.mem.Allocator, uri: []const u8, language_id: []const u8, text: []const u8) !U8Slice {
        var m = LSPMessages.textDocumentDidOpen{
            .jsonrpc = "2.0",
            .method = "textDocument/didOpen",
            .params = LSPMessages.textDocumentDidOpenParams{
                .textDocument = LSPMessages.textDocumentItem{
                    .uri = uri,
                    .languageId = language_id,
                    .version = 1,
                    .text = text,
                },
            },
        };
        return try LSPWriter.toJson(allocator, m);
    }

    fn textDocumentReference(allocator: std.mem.Allocator, msg_id: i64, filepath: []const u8, cursor_pos: Vec2u) !U8Slice {
        var m = LSPMessages.textDocumentReferences{
            .jsonrpc = "2.0",
            .method = "textDocument/references",
            .id = msg_id,
            .params = LSPMessages.referencesParams{
                .textDocument = LSPMessages.textDocumentIdentifier{
                    .uri = filepath,
                },
                .position = LSPMessages.position{
                    .character = cursor_pos.a,
                    .line = cursor_pos.b,
                },
                .context = LSPMessages.referencesContext{
                    .includeDeclaration = true,
                },
            },
        };
        return try LSPWriter.toJson(allocator, m);
    }

    fn textDocumentDefinition(allocator: std.mem.Allocator, msg_id: i64, filepath: []const u8, cursor_pos: Vec2u) !U8Slice {
        var m = LSPMessages.textDocumentDefinition{
            .jsonrpc = "2.0",
            .method = "textDocument/definition",
            .id = msg_id,
            .params = LSPMessages.definitionParams{
                .textDocument = LSPMessages.textDocumentIdentifier{
                    .uri = filepath,
                },
                .position = LSPMessages.position{
                    .character = cursor_pos.a,
                    .line = cursor_pos.b,
                },
            },
        };
        return try LSPWriter.toJson(allocator, m);
    }

    fn textDocumentDidChange(allocator: std.mem.Allocator, msg_id: i64, filepath: []const u8, range: Vec4u, new_text: []const u8) !U8Slice {
        var content_change = LSPMessages.contentChange{
            .range = LSPMessages.range{
                .start = LSPMessages.position{ .character = range.a, .line = range.b },
                .end = LSPMessages.position{ .character = range.c, .line = range.d },
            },
            .text = new_text,
        };
        var m = LSPMessages.textDocumentDidChange{
            .jsonrpc = "2.0",
            .method = "textDocument/didChange",
            .params = LSPMessages.didChangeParams{
                .textDocument = LSPMessages.textDocumentIdentifierVersioned{
                    .uri = filepath,
                    .version = msg_id, // we can re-use the msg id which is a monotonic counter
                },
                .contentChanges = [1]LSPMessages.contentChange{content_change},
            },
        };
        return try LSPWriter.toJson(allocator, m);
    }

    fn textDocumentCompletion(allocator: std.mem.Allocator, msg_id: i64, filepath: []const u8, cursor_pos: Vec2u) !U8Slice {
        var m = LSPMessages.textDocumentCompletion{
            .jsonrpc = "2.0",
            .method = "textDocument/completion",
            .id = msg_id,
            .params = LSPMessages.completionParams{
                .textDocument = LSPMessages.textDocumentIdentifier{
                    .uri = filepath,
                },
                .position = LSPMessages.position{
                    .character = cursor_pos.a,
                    .line = cursor_pos.b,
                },
            },
        };
        return try LSPWriter.toJson(allocator, m);
    }

    fn toJson(allocator: std.mem.Allocator, message: anytype) !U8Slice {
        var rv = U8Slice.initEmpty(allocator);
        errdefer rv.deinit();
        try std.json.stringify(message, std.json.StringifyOptions{}, rv.data.writer());
        return rv;
    }
};

test "lspwriter initialize" {
    const allocator = std.testing.allocator;
    var init_msg = try LSPWriter.initialize(allocator, 0, "hello world");
    init_msg.deinit();
}
