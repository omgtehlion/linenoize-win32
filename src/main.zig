const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const File = std.fs.File;

const LinenoiseState = @import("state.zig").LinenoiseState;
pub const History = @import("history.zig").History;
const term = @import("term.zig");
const isUnsupportedTerm = term.isUnsupportedTerm;
const enableRawMode = term.enableRawMode;
const disableRawMode = term.disableRawMode;
const getColumns = term.getColumns;

pub const HintsCallback = *const fn (Allocator, []const u8) Allocator.Error!?[]const u8;
pub const CompletionsCallback = *const fn (Allocator, []const u8) Allocator.Error![]const []const u8;

fn key_ctrl(comptime c: u8) u8 {
    return c - '`';
}
const char_escape = 27;
const char_delete = 127;

fn linenoiseEdit(ln: *Linenoise, in: File, out: File, prompt: []const u8) !?[]const u8 {
    var state = LinenoiseState.init(ln, in, out, prompt);
    defer state.buf.deinit(state.allocator);

    try state.ln.history.add("");
    state.ln.history.current = state.ln.history.hist.items.len - 1;
    try state.refreshLine();

    while (true) {
        var input_buf: [1]u8 = undefined;
        if ((try term.read(in, &input_buf)) < 1) return null;
        var c = input_buf[0];

        // Browse completions before editing
        if (c == '\t') {
            if (try state.browseCompletions()) |new_c| {
                c = new_c;
            }
        }

        switch (c) {
            '\x00', '\t' => {},
            key_ctrl('a') => try state.editMoveHome(),
            key_ctrl('b') => try state.editMoveLeft(),
            key_ctrl('c') => return error.CtrlC,
            key_ctrl('d') => {
                if (state.buf.items.len > 0) {
                    try state.editDelete();
                } else {
                    state.ln.history.pop();
                    return null;
                }
            },
            key_ctrl('e') => try state.editMoveEnd(),
            key_ctrl('f') => try state.editMoveRight(),
            key_ctrl('k') => try state.editKillLineForward(),
            key_ctrl('l') => {
                try term.clearScreen();
                try state.refreshLine();
            },
            '\r', '\n' => {
                state.ln.history.pop();
                return try ln.allocator.dupe(u8, state.buf.items);
            },
            key_ctrl('n') => try state.editHistoryNext(.next),
            key_ctrl('p') => try state.editHistoryNext(.prev),
            key_ctrl('t') => try state.editSwapPrev(),
            key_ctrl('u') => try state.editKillLineBackward(),
            key_ctrl('w') => try state.editDeletePrevWord(),
            char_delete, key_ctrl('h') => try state.editBackspace(),
            char_escape => {
                if ((try term.read(in, &input_buf)) < 1) return null;
                switch (input_buf[0]) {
                    'b' => try state.editMoveWordStart(),
                    'f' => try state.editMoveWordEnd(),
                    '[' => {
                        if ((try term.read(in, &input_buf)) < 1) return null;
                        switch (input_buf[0]) {
                            '0'...'9' => |num| {
                                if ((try in.read(&input_buf)) < 1) return null;
                                switch (input_buf[0]) {
                                    '~' => switch (num) {
                                        '1', '7' => try state.editMoveHome(),
                                        '3' => try state.editDelete(),
                                        '4', '8' => try state.editMoveEnd(),
                                        else => {},
                                    },
                                    '0'...'9' => {}, // TODO: read 2-digit CSI
                                    else => {},
                                }
                            },
                            'A' => try state.editHistoryNext(.prev),
                            'B' => try state.editHistoryNext(.next),
                            'C' => try state.editMoveRight(),
                            'D' => try state.editMoveLeft(),
                            'H' => try state.editMoveHome(),
                            'F' => try state.editMoveEnd(),
                            else => {},
                        }
                    },
                    '0' => {
                        if ((try term.read(in, &input_buf)) < 1) return null;
                        switch (input_buf[0]) {
                            'H' => try state.editMoveHome(),
                            'F' => try state.editMoveEnd(),
                            else => {},
                        }
                    },
                    else => {},
                }
            },
            else => {
                var utf8_buf: [4]u8 = undefined;
                const utf8_len = std.unicode.utf8ByteSequenceLength(c) catch continue;

                utf8_buf[0] = c;
                if (utf8_len > 1 and (try term.read(in, utf8_buf[1..utf8_len])) < utf8_len - 1) return null;

                try state.editInsert(utf8_buf[0..utf8_len]);
            },
        }
    }
}

/// Read a line with custom line editing mechanics. This includes hints,
/// completions and history
fn linenoiseRaw(ln: *Linenoise, in: File, out: File, prompt: []const u8) !?[]const u8 {
    defer out.writeAll("\n") catch {};

    const orig = try enableRawMode(in, out);
    defer disableRawMode(in, out, orig);

    return try linenoiseEdit(ln, in, out, prompt);
}

/// Read a line with no special features (no hints, no completions, no history)
fn linenoiseNoTTY(allocator: Allocator, stdin: File) !?[]const u8 {
    var reader = stdin.reader();
    const max_line_len = std.math.maxInt(usize);
    return reader.readUntilDelimiterAlloc(allocator, '\n', max_line_len) catch |e| switch (e) {
        error.EndOfStream => return null,
        else => return e,
    };
}

pub const Linenoise = struct {
    allocator: Allocator,
    history: History,
    multiline_mode: bool = false,
    mask_mode: bool = false,
    is_tty: bool = false,
    term_supported: bool = false,
    hints_callback: ?HintsCallback = null,
    completions_callback: ?CompletionsCallback = null,

    const Self = @This();

    /// Initialize a linenoise struct
    pub fn init(allocator: Allocator) Self {
        var self = Self{
            .allocator = allocator,
            .history = History.empty(allocator),
        };
        self.examineStdIo(allocator);
        return self;
    }

    /// Free all resources occupied by this struct
    pub fn deinit(self: *Self) void {
        self.history.deinit();
    }

    /// Re-examine (currently) stdin and environment variables to
    /// check if line editing and prompt printing should be
    /// enabled or not.
    pub fn examineStdIo(self: *Self, allocator: Allocator) void {
        const stdin_file = std.io.getStdIn();
        self.is_tty = stdin_file.isTty();
        self.term_supported = !isUnsupportedTerm(allocator);
    }

    /// Reads a line from the terminal. Caller owns returned memory
    pub fn linenoise(self: *Self, prompt: []const u8) !?[]const u8 {
        const stdin_file = std.io.getStdIn();
        const stdout_file = std.io.getStdOut();

        if (self.is_tty and !self.term_supported) {
            try stdout_file.writeAll(prompt);
        }

        return if (self.is_tty and self.term_supported)
            try linenoiseRaw(self, stdin_file, stdout_file, prompt)
        else
            try linenoiseNoTTY(self.allocator, stdin_file);
    }
};

test "all" {
    _ = @import("history.zig");
}
