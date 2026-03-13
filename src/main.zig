const rl = @import("raylib");
const std = @import("std");

const Opcode = packed struct(u16) {
    n: u4,
    y: u4,
    x: u4,
    t: u4,

    pub fn nn(self: Opcode) u8 {
        return (@as(u8, self.y) << 4) | self.n;
    }

    pub fn nnn(self: Opcode) u12 {
        return (@as(u12, self.x) << 8) | (@as(u12, self.y) << 4) | self.n;
    }
};

const Chip8 = struct {
    registers: [16]u8,
    memory: [4096]u8,
    index: u16,
    pc: u16,
    stack: [16]u16,
    stack_count: u4,
    sp: u8,
    delay_timer: u8,
    sound_timer: u8,
    keypad: [16]bool,
    video: [32][64]bool,
    opcode: u16,
    prng: std.Random.DefaultPrng,

    fn init(allocator: std.mem.Allocator, filename: []const u8) !Chip8 {
        var chip8 = Chip8{
            .registers = [_]u8{0} ** 16,
            .memory = [_]u8{0} ** 4096,
            .index = 0,
            .pc = 0x200,
            .stack = [_]u16{0} ** 16,
            .stack_count = 0,
            .sp = 0,
            .delay_timer = 0,
            .sound_timer = 0,
            .keypad = [_]bool{false} ** 16,
            .video = [_][64]bool{[_]bool{false} ** 64} ** 32,
            .opcode = 0,
            .prng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp())),
        };

        const file = try std.fs.cwd().openFile(filename, .{});
        defer file.close();

        const stat = try file.stat();
        const size: usize = @intCast(stat.size);
        const buffer = try file.readToEndAlloc(allocator, size);
        defer allocator.free(buffer);

        for (buffer, 0..) |v, i| {
            chip8.memory[0x200 + i] = v;
        }

        chip8.pc = 0x200;
        std.debug.print("Loaded rom\n", .{});

        const fontset = [80]u8{
            0xF0, 0x90, 0x90, 0x90, 0xF0, // 0
            0x20, 0x60, 0x20, 0x20, 0x70, // 1
            0xF0, 0x10, 0xF0, 0x80, 0xF0, // 2
            0xF0, 0x10, 0xF0, 0x10, 0xF0, // 3
            0x90, 0x90, 0xF0, 0x10, 0x10, // 4
            0xF0, 0x80, 0xF0, 0x10, 0xF0, // 5
            0xF0, 0x80, 0xF0, 0x90, 0xF0, // 6
            0xF0, 0x10, 0x20, 0x40, 0x40, // 7
            0xF0, 0x90, 0xF0, 0x90, 0xF0, // 8
            0xF0, 0x90, 0xF0, 0x10, 0xF0, // 9
            0xF0, 0x90, 0xF0, 0x90, 0x90, // A
            0xE0, 0x90, 0xE0, 0x90, 0xE0, // B
            0xF0, 0x80, 0x80, 0x80, 0xF0, // C
            0xE0, 0x90, 0x90, 0x90, 0xE0, // D
            0xF0, 0x80, 0xF0, 0x80, 0xF0, // E
            0xF0, 0x80, 0xF0, 0x80, 0x80, // F
        };

        for (fontset, 0..) |v, i| {
            chip8.memory[0x50 + i] = v;
        }

        std.debug.print("Loaded fontset\n", .{});

        return chip8;
    }

    fn op_00e0(self: *Chip8) void {
        std.debug.print("00e0 clear screen\n", .{});
        for (&self.video) |*row| {
            @memset(row, false);
        }
    }

    fn op_00ee(self: *Chip8) void {
        std.debug.print("00ee return\n", .{});
        self.stack_count -= 1;
        self.pc = self.stack[self.stack_count];
    }

    fn op_1nnn(self: *Chip8, address: u16) void {
        std.debug.print("1nnn jump\n", .{});
        self.pc = address;
    }

    fn op_2nnn(self: *Chip8, address: u16) void {
        std.debug.print("2nnn jump subroutine\n", .{});
        self.stack[self.stack_count] = self.pc;
        self.stack_count += 1;
        self.pc = address;
    }

    fn op_3xnn(self: *Chip8, vx: u4, nn: u8) void {
        std.debug.print("3xnn skip condiitionally\n", .{});
        if (self.registers[vx] == nn) {
            self.pc += 2;
        }
    }

    fn op_4xnn(self: *Chip8, vx: u4, nn: u8) void {
        std.debug.print("4xnn skip condiitionally\n", .{});
        if (self.registers[vx] != nn) {
            self.pc += 2;
        }
    }

    fn op_5xy0(self: *Chip8, vx: u4, vy: u4) void {
        std.debug.print("5xy0 skip condiitionally\n", .{});
        if (self.registers[vx] == self.registers[vy]) {
            self.pc += 2;
        }
    }

    fn op_6xnn(self: *Chip8, register: u4, value: u8) void {
        std.debug.print("6xnn set register\n", .{});
        self.registers[register] = value;
    }

    fn op_7xnn(self: *Chip8, vx: u4, nn: u8) void {
        std.debug.print("7xnn add to register\n", .{});
        const result = @addWithOverflow(self.registers[vx], nn);
        // if (result[1] != 0) {
        //     self.registers[0xf] = 1;
        self.registers[vx] = result[0];
        // }
    }

    fn op_8xy0(self: *Chip8, vx: u4, vy: u4) void {
        std.debug.print("8xy0 set\n", .{});
        self.registers[vx] = self.registers[vy];
    }

    fn op_8xy1(self: *Chip8, vx: u4, vy: u4) void {
        std.debug.print("8xy1 or\n", .{});

        self.registers[vx] = self.registers[vx] | self.registers[vy];
    }

    fn op_8xy2(self: *Chip8, vx: u4, vy: u4) void {
        std.debug.print("8xy2 and\n", .{});

        self.registers[vx] = self.registers[vx] & self.registers[vy];
    }

    fn op_8xy3(self: *Chip8, vx: u4, vy: u4) void {
        std.debug.print("8xy3 xor\n", .{});

        self.registers[vx] = self.registers[vx] ^ self.registers[vy];
    }

    fn op_8xy4(self: *Chip8, vx: u4, vy: u4) void {
        std.debug.print("8xy4 add\n", .{});

        const result = @addWithOverflow(self.registers[vx], self.registers[vy]);
        if (result[1] != 0) {
            self.registers[0xf] = 1;
        }

        self.registers[vx] = result[0];
    }

    fn op_8xy5(self: *Chip8, vx: u4, vy: u4) void {
        std.debug.print("8xy5 substract\n", .{});
        const val_x = self.registers[vx];
        const val_y = self.registers[vy];
        const result = @subWithOverflow(val_x, val_y);

        self.registers[vx] = result[0];
        self.registers[0xf] = if (val_x >= val_y) 1 else 0;
    }

    fn op_8xy6(self: *Chip8, vx: u4, vy: u4) void {
        std.debug.print("8xy6 shift\n", .{});

        _ = vy; // TODO: make setting vx to vy configurable
        self.registers[0xF] = self.registers[vx] & 0x01;
        self.registers[vx] >>= 1;
    }

    fn op_8xye(self: *Chip8, vx: u4, vy: u4) void {
        std.debug.print("8xy6 shift\n", .{});

        _ = vy; // TODO: make setting vx to vy configurable
        self.registers[0xF] = (self.registers[vx] & 0x80) >> 7;
        self.registers[vx] <<= 1;
    }

    fn op_8xy7(self: *Chip8, vx: u4, vy: u4) void {
        std.debug.print("8xy7 substract\n", .{});

        if (self.registers[vy] > self.registers[vx]) {
            self.registers[0xf] = 1;
        } else {
            self.registers[0xf] = 0;
        }

        const result = @subWithOverflow(self.registers[vy], self.registers[vx]);
        self.registers[vx] = result[0];
    }

    fn op_9xy0(self: *Chip8, vx: u4, vy: u4) void {
        std.debug.print("9xy0 skip condiitionally\n", .{});
        if (self.registers[vx] != self.registers[vy]) {
            self.pc += 2;
        }
    }

    fn op_annn(self: *Chip8, value: u16) void {
        std.debug.print("annn set index\n", .{});
        self.index = value;
    }

    fn op_bnnn(self: *Chip8, address: u16) void {
        self.pc = address + self.registers[0];
    }

    fn op_cxnn(self: *Chip8, vx: u4, nn: u8) void {
        std.debug.print("cxnn random \n", .{});

        const num = self.prng.random().int(u8);
        self.registers[vx] = num & nn;
    }

    fn op_dxyn(self: *Chip8, vx: u4, vy: u4, n: u4) void {
        std.debug.print("dxyn draw\n", .{});
        const x_start = self.registers[vx] % 64;
        const y_start = self.registers[vy] % 32;
        self.registers[0xf] = 0;

        for (0..n) |row_offset| {
            const y = y_start + row_offset;
            if (y >= 32) break;

            const sprite_byte = self.memory[self.index + row_offset];

            for (0..8) |col_offset| {
                const x = x_start + col_offset;
                if (x >= 64) break;

                const sprite_pixel = (sprite_byte >> @as(u3, @truncate(7 - col_offset))) & 1;

                if (sprite_pixel == 1) {
                    if (self.video[y][x]) {
                        self.video[y][x] = false;
                        self.registers[0xf] = 1;
                    } else {
                        self.video[y][x] = true;
                    }
                }
            }
        }
    }

    fn op_ex9e(self: *Chip8, vx: u4) void {
        std.debug.print("ex9e skip if key\n", .{});

        if (self.keypad[self.registers[vx]]) {
            self.pc += 2;
        }
    }

    fn op_exa1(self: *Chip8, vx: u4) void {
        std.debug.print("ex9e skip if not key\n", .{});

        if (!self.keypad[self.registers[vx]]) {
            self.pc += 2;
        }
    }

    fn op_fx07(self: *Chip8, vx: u4) void {
        std.debug.print("fx07 timer\n", .{});

        self.registers[vx] = self.delay_timer;
    }

    fn op_fx15(self: *Chip8, vx: u4) void {
        std.debug.print("fx15 set timer\n", .{});

        self.delay_timer = self.registers[vx];
    }

    fn op_fx18(self: *Chip8, vx: u4) void {
        std.debug.print("fx18 set sound timer\n", .{});

        self.sound_timer = self.registers[vx];
    }

    fn op_fx1e(self: *Chip8, vx: u4) void {
        std.debug.print("fx1e add index\n", .{});

        self.index += self.registers[vx];
    }

    fn op_fx0a(self: *Chip8, vx: u4) void {
        std.debug.print("fx0a wait key\n", .{});

        const k = self.wait_for_input();
        if (k != null) {
            self.registers[vx] = k.?;
        } else {
            self.pc -= 2;
        }
    }

    fn op_fx29(self: *Chip8, vx: u4) void {
        std.debug.print("fx29 font\n", .{});

        self.index = 0x50 + self.registers[vx] * 5;
    }

    fn op_fx33(self: *Chip8, vx: u4) void {
        std.debug.print("fx33 unimplemented\n", .{});

        self.memory[self.index] = self.registers[vx] / 100;
        self.memory[self.index + 1] = (self.registers[vx] / 10) % 10;
        self.memory[self.index + 2] = self.registers[vx] % 10;
    }

    fn op_fx55(self: *Chip8, vx: u4) void {
        std.debug.print("fx55 memory\n", .{});

        for (0..vx + 1) |v| {
            self.memory[self.index + v] = self.registers[v];
        }
    }

    fn op_fx65(self: *Chip8, vx: u4) void {
        std.debug.print("fx65 memory\n", .{});

        for (0..vx + 1) |v| {
            self.registers[v] = self.memory[self.index + v];
        }
    }

    fn cycle(self: *Chip8) void {
        const raw_opcode = std.mem.readInt(u16, self.memory[self.pc..][0..2], .big);
        const op: Opcode = @bitCast(raw_opcode);
        self.pc += 2;

        switch (op.t) {
            0x0 => switch (op.nn()) {
                0xe0 => self.op_00e0(),
                0xee => self.op_00ee(),
                else => std.debug.print("unknown 0x0 subopcode\n", .{}),
            },
            0x1 => self.op_1nnn(op.nnn()),
            0x2 => self.op_2nnn(op.nnn()),
            0x3 => self.op_3xnn(op.x, op.nn()),
            0x4 => self.op_4xnn(op.x, op.nn()),
            0x5 => self.op_5xy0(op.x, op.y),
            0x6 => self.op_6xnn(op.x, op.nn()),
            0x7 => self.op_7xnn(op.x, op.nn()),
            0x8 => switch (op.n) {
                0x0 => self.op_8xy0(op.x, op.y),
                0x1 => self.op_8xy1(op.x, op.y),
                0x2 => self.op_8xy2(op.x, op.y),
                0x3 => self.op_8xy3(op.x, op.y),
                0x4 => self.op_8xy4(op.x, op.y),
                0x5 => self.op_8xy5(op.x, op.y),
                0x6 => self.op_8xy6(op.x, op.y),
                0xe => self.op_8xye(op.x, op.y),
                else => std.debug.print("unknown 0x8 subopcode\n", .{}),
            },
            0x9 => self.op_9xy0(op.x, op.y),
            0xa => self.op_annn(op.nnn()),
            0xb => self.op_bnnn(op.nnn()),
            0xc => self.op_cxnn(op.x, op.nn()),
            0xd => self.op_dxyn(op.x, op.y, op.n),
            0xe => switch (op.nn()) {
                0x9e => self.op_ex9e(op.x),
                0xa1 => self.op_exa1(op.x),
                else => std.debug.print("unknown 0xe subopcode\n", .{}),
            },
            0xf => switch (op.nn()) {
                0x07 => self.op_fx07(op.x),
                0x0a => self.op_fx0a(op.x),
                0x15 => self.op_fx15(op.x),
                0x18 => self.op_fx18(op.x),
                0x1e => self.op_fx1e(op.x),
                0x29 => self.op_fx29(op.x),
                0x33 => self.op_fx33(op.x),
                0x55 => self.op_fx55(op.x),
                0x65 => self.op_fx65(op.x),
                else => std.debug.print("unknown 0xf subopcode\n", .{}),
            },
            //else => std.debug.print("unknown opcode\n", .{}),
        }
    }

    const key_map = [16]rl.KeyboardKey{
        .kp_1, .kp_2, .kp_3, .kp_4,
        .q,    .w,    .e,    .r,
        .a,    .s,    .d,    .f,
        .z,    .x,    .c,    .v,
    };

    fn input(self: *Chip8) void {
        for (key_map, 0..) |key, i| {
            self.keypad[i] = rl.isKeyDown(key);
        }
    }

    fn wait_for_input(self: *Chip8) ?u8 {
        for (key_map, 0..) |key, i| {
            if (rl.isKeyPressed(key)) return @intCast(i);
        }
        _ = self;
        return null;
    }
};

pub fn main() anyerror!void {
    const screenWidth = 750;
    const screenHeight = 400;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    rl.initWindow(screenWidth, screenHeight, "raylib-zig [core] example - basic window");
    defer rl.closeWindow();

    rl.setTargetFPS(60);

    var chip = try Chip8.init(allocator, args[1]);

    while (!rl.windowShouldClose()) {
        chip.input();

        if (chip.delay_timer > 0) {
            chip.delay_timer -= 1;
        }
        if (chip.sound_timer > 0) {
            chip.sound_timer -= 1;
        }

        for (0..10) |_| {
            chip.cycle();
        }

        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(.white);

        for (chip.video, 0..) |row, y| {
            for (row, 0..) |value, x| {
                if (value) {
                    rl.drawRectangle(@intCast(x * 10), @intCast(y * 10), 10, 10, .black);
                }
            }
        }

        for (chip.registers, 0..) |v, i| {
            var buf: [3]u8 = undefined;
            const hex_text = try std.fmt.bufPrintZ(&buf, "{x:0>2}", .{v});
            rl.drawText(hex_text, 645, @intCast(10 + 20 * i), 20, .red);
        }
    }
}
