const std = @import("std");
const Allocator = std.mem.Allocator;
const zua = @import("zua.zig");
const Instruction = zua.opcodes.Instruction;
const Node = zua.ast.Node;
const Function = zua.object.Function;
const Constant = zua.object.Constant;
const Lexer = zua.lex.Lexer;
const Parser = zua.parse.Parser;
const max_stack_size = zua.parse.max_stack_size;
const OpCode = zua.opcodes.OpCode;
const Token = zua.lex.Token;

/// LUAI_MAXVARS from lconf.h
pub const max_vars = 200;

pub fn compile(allocator: Allocator, source: []const u8) !Function {
    var lexer = Lexer.init(source, source);
    var parser = Parser.init(&lexer);
    var tree = try parser.parse(allocator);
    defer tree.deinit();

    var arena_allocator = std.heap.ArenaAllocator.init(allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    var compiler = Compiler{
        .source = source,
        .arena = arena,
        .allocator = allocator,
        .func = undefined,
    };
    defer compiler.deinit();

    const main_func = try compiler.genChunk(tree.chunk());

    return Function{
        .name = "",
        .code = try allocator.dupe(Instruction, main_func.code.items),
        .constants = try allocator.dupe(Constant, main_func.constants.items),
        .allocator = allocator,
        .max_stack_size = main_func.max_stack_size,
        .varargs = main_func.varargs,
    };
}

pub const Compiler = struct {
    source: []const u8,
    arena: Allocator,
    allocator: Allocator,
    func: *Func,

    pub const Error = error{CompileError} || Allocator.Error;

    pub fn deinit(self: *Compiler) void {
        // TODO
        _ = self;
    }

    /// State for an incomplete/to-be-compiled function
    /// Analogous to FuncState in PUC Lua
    pub const Func = struct {
        max_stack_size: u8 = 2, // registers 0/1 are always valid
        free_register: u8 = 0, // TODO what should this type actually be?
        cur_exp: ExpDesc = .{ .desc = .{ .void = {} } },
        code: std.ArrayList(Instruction),
        constants: std.ArrayList(Constant),
        constants_map: Constant.Map,
        varargs: Function.VarArgs,
        prev: ?*Func,
        num_active_local_vars: u8 = 0,
        active_local_vars: [max_vars]usize = undefined,
        local_vars: std.ArrayList(LocalVar),

        pub const LocalVar = struct {
            name_token: Token,
            active_instruction_index: usize,
            dead_instruction_index: usize,
        };

        pub fn checkstack(self: *Func, n: u8) !void {
            const newstack = self.free_register + n;
            if (newstack > self.max_stack_size) {
                if (newstack >= max_stack_size) {
                    @panic("TODO function or expression too complex");
                }
                self.max_stack_size = newstack;
            }
        }

        pub fn reserveregs(self: *Func, n: u8) !void {
            try self.checkstack(n);
            self.free_register += n;
        }

        pub fn exp2nextreg(self: *Func, e: *ExpDesc) !u8 {
            try self.dischargevars(e);
            try self.freeexp(e);
            try self.reserveregs(1);
            const reg = self.free_register - 1;
            try self.exp2reg(e, reg);
            return reg;
        }

        pub fn exp2anyreg(self: *Func, e: *ExpDesc) !u8 {
            try self.dischargevars(e);
            if (e.desc == .nonreloc) {
                const reg = e.desc.nonreloc.result_register;
                // exp is already in a register
                if (!e.hasjumps()) return reg;
                // reg is not a local?
                if (reg >= self.num_active_local_vars) {
                    try self.exp2reg(e, reg);
                    return reg;
                }
            }
            return try self.exp2nextreg(e);
        }

        pub fn dischargevars(self: *Func, e: *ExpDesc) !void {
            switch (e.desc) {
                .local_register => {
                    const reg = e.desc.local_register;
                    e.desc = .{ .nonreloc = .{ .result_register = reg } };
                },
                .upvalue_index => {
                    //const index = try self.emitABC(.getupval, 0, @intCast(u18, e.val.?), 0);
                    //e.val = @intCast(isize, index);
                    e.desc = .{ .relocable = .{ .instruction_index = 0 } };
                    @panic("TODO");
                },
                .global => |global| {
                    const instruction_index = try self.emitInstruction(
                        // result register is to-be-determined
                        Instruction.GetGlobal.init(0, global.name_constant_index),
                    );
                    e.desc = .{ .relocable = .{ .instruction_index = instruction_index } };
                },
                .indexed => |indexed_desc| {
                    self.freereg(indexed_desc.key_register_or_constant_index);
                    self.freereg(indexed_desc.table_register);
                    const instruction_index = try self.emitInstruction(
                        // result register is to-be-determined
                        Instruction.GetTable.init(0, indexed_desc.table_register, indexed_desc.key_register_or_constant_index),
                    );
                    e.desc = .{ .relocable = .{ .instruction_index = instruction_index } };
                },
                .vararg, .call => {
                    try self.setoneret(e);
                },
                else => {}, // there is one value available (somewhere)
            }
        }

        pub fn setoneret(self: *Func, e: *ExpDesc) !void {
            if (e.desc == .call) {
                const instruction: *Instruction.Call = @ptrCast(self.getcode(e));
                e.desc = .{ .nonreloc = .{ .result_register = instruction.getResultRegStart() } };
            } else if (e.desc == .vararg) {
                const instruction: *Instruction.VarArg = @ptrCast(self.getcode(e));
                instruction.setNumReturnValues(1);

                const instruction_index = e.desc.vararg.instruction_index;
                e.desc = .{ .relocable = .{ .instruction_index = instruction_index } };
            }
        }

        pub fn freeexp(self: *Func, e: *ExpDesc) !void {
            if (e.desc == .nonreloc) {
                self.freereg(e.desc.nonreloc.result_register);
            }
        }

        pub fn freereg(self: *Func, reg: u9) void {
            if (!zua.opcodes.rkIsConstant(reg) and reg >= self.num_active_local_vars) {
                self.free_register -= 1;
                std.debug.assert(reg == self.free_register);
            }
        }

        pub fn getcode(self: *Func, e: *ExpDesc) *Instruction {
            const index: usize = switch (e.desc) {
                .jmp, .relocable, .call, .vararg => |desc| desc.instruction_index,
                else => unreachable,
            };
            return &self.code.items[index];
        }

        pub fn exp2reg(self: *Func, e: *ExpDesc, reg: u8) !void {
            try self.discharge2reg(e, reg);
            if (e.desc == .jmp) {
                //self.concat(...)
                @panic("TODO");
            }
            if (e.hasjumps()) {
                @panic("TODO");
            }
            e.* = .{
                .desc = .{
                    .nonreloc = .{ .result_register = reg },
                },
                .patch_list = .{},
            };
        }

        /// Afterwards, `e.desc` will be of type `nonreloc` unless `e.desc` starts
        /// as `void` or `jmp`, in which case `e` will be unchanged
        pub fn discharge2reg(self: *Func, e: *ExpDesc, reg: u8) !void {
            try self.dischargevars(e);
            switch (e.desc) {
                .nil => {
                    _ = try self.emitNil(reg, 1);
                },
                .false, .true => {
                    _ = try self.emitInstruction(Instruction.LoadBool.init(reg, e.desc == .true, false));
                },
                .constant_index => {
                    _ = try self.emitInstruction(Instruction.LoadK.init(reg, e.desc.constant_index));
                },
                .number => {
                    // Need to add number constants to the constant table here instead of
                    // in genLiteral because not every constant is needed in the final
                    // bytecode, i.e. `return 1 + 2` should be resolved to only need the
                    // constant `3` (1 and 2 are not in the final bytecode)
                    const index = try self.putConstant(Constant{ .number = e.desc.number });
                    _ = try self.emitInstruction(Instruction.LoadK.init(reg, index));
                },
                .relocable => {
                    const instruction = self.getcode(e);
                    const instructionABC: *Instruction.ABC = @ptrCast(instruction);
                    std.debug.assert(instructionABC.op.setsRegisterInA());
                    instructionABC.*.a = reg;
                },
                .nonreloc => {
                    if (reg != e.desc.nonreloc.result_register) {
                        const result_register = e.desc.nonreloc.result_register;
                        _ = try self.emitABC(.move, reg, result_register, 0);
                    }
                },
                .void, .jmp => return, // nothing to do
                else => unreachable,
            }
            e.desc = .{ .nonreloc = .{ .result_register = reg } };
        }

        pub fn discharge2anyreg(self: *Func, e: *ExpDesc) !void {
            if (e.desc != .nonreloc) {
                try self.reserveregs(1);
                const reg = self.free_register - 1;
                try self.discharge2reg(e, reg);
            }
        }

        /// luaK_ret equivalent
        pub fn emitReturn(self: *Func, first_return_reg: u8, num_returns: ?u9) !usize {
            return self.emitInstruction(Instruction.Return.init(first_return_reg, num_returns));
        }

        pub fn emitNil(self: *Func, register_range_start: u8, n: usize) !?usize {
            std.debug.assert(n >= 1);
            // TODO other branches
            if (true) { // TODO fs->pc > fs->lasttarget
                if (self.pc() == 0) { // function start?
                    if (register_range_start >= self.num_active_local_vars) {
                        return null; // positions are already clean
                    }
                }
            }
            const register_range_end: u9 = @intCast(register_range_start + n - 1);
            if (self.emitInstruction(Instruction.LoadNil.init(register_range_start, register_range_end))) |index| {
                return index;
            } else |err| {
                return err;
            }
        }

        /// Appends a new instruction to the Func's code and returns the
        /// index of the added instruction
        pub fn emitInstruction(self: *Func, instruction: anytype) !usize {
            try self.code.append(@bitCast(instruction));
            return self.pc() - 1;
        }

        /// Appends a new instruction to the Func's code and returns the
        /// index of the added instruction
        /// luaK_codeABC equivalent
        pub fn emitABC(self: *Func, op: OpCode, a: u8, b: u9, c: u9) !usize {
            return self.emitInstruction(Instruction.ABC.init(op, a, b, c));
        }

        /// Appends a new instruction to the Func's code and returns the
        /// index of the added instruction
        /// luaK_codeABx equivalent
        pub fn emitABx(self: *Func, op: OpCode, a: u8, bx: u18) !usize {
            return self.emitInstruction(Instruction.ABx.init(op, a, bx));
        }

        pub fn putConstant(self: *Func, constant: Constant) Error!u18 {
            const result = try self.constants_map.getOrPut(constant);
            if (result.found_existing) {
                return @intCast(result.value_ptr.*);
            } else {
                const index = self.constants.items.len;
                result.value_ptr.* = index;
                try self.constants.append(constant);

                if (index > Instruction.ABx.max_bx) {
                    // TODO: "constant table overflow"
                    return error.CompileError;
                }

                return @intCast(index);
            }
        }

        pub fn new_localvar(self: *Func, name_token: Token, var_index: usize) Error!void {
            const active_local_var_index = self.num_active_local_vars + var_index;
            if (active_local_var_index >= max_vars) {
                @panic("TODO too many local vars error");
            }
            self.active_local_vars[active_local_var_index] = try self.registerlocalvar(name_token);
        }

        pub fn registerlocalvar(self: *Func, name_token: Token) Error!usize {
            try self.local_vars.append(.{
                .name_token = name_token,
                // to be filled in later
                .active_instruction_index = undefined,
                .dead_instruction_index = undefined,
            });
            return self.local_vars.items.len - 1;
        }

        pub fn adjust_assign(self: *Func, num_vars: usize, num_values: usize, e: *ExpDesc) !void {
            var extra: isize = @as(isize, @intCast(num_vars)) - @as(isize, @intCast(num_values));
            if (e.hasmultret()) {
                extra += 1;
                if (extra < 0) extra = 0;
                try self.setreturns(e, @intCast(extra));
                if (extra > 1) {
                    try self.reserveregs(@intCast(extra - 1));
                }
            } else {
                if (e.desc != .void) {
                    _ = try self.exp2nextreg(e);
                }
                if (extra > 0) {
                    const reg = self.free_register;
                    try self.reserveregs(@intCast(extra));
                    _ = try self.emitNil(reg, @intCast(extra));
                }
            }
        }

        pub fn setreturns(self: *Func, e: *ExpDesc, num_results: ?u9) !void {
            if (e.desc == .call) {
                const instruction: *Instruction.Call = @ptrCast(self.getcode(e));
                instruction.setNumReturnValues(num_results);
            } else if (e.desc == .vararg) {
                const instruction: *Instruction.VarArg = @ptrCast(self.getcode(e));
                instruction.setNumReturnValues(num_results);
                instruction.setFirstReturnValueRegister(self.free_register);
                try self.reserveregs(1);
            }
        }

        pub fn setmultret(self: *Func, e: *ExpDesc) !void {
            return self.setreturns(e, null);
        }

        pub fn adjustlocalvars(self: *Func, num_vars: usize) !void {
            self.num_active_local_vars += @intCast(num_vars);
            var num_vars_remaining = num_vars;
            while (num_vars_remaining > 0) : (num_vars_remaining -= 1) {
                const local_var = self.getlocvar(self.num_active_local_vars - num_vars_remaining);
                local_var.active_instruction_index = self.pc();
            }
        }

        pub fn removevars(self: *Func, to_level: u8) !void {
            while (self.num_active_local_vars > to_level) {
                self.num_active_local_vars -= 1;
                const local_var = self.getlocvar(self.num_active_local_vars);
                local_var.dead_instruction_index = self.pc();
            }
        }

        pub fn getlocvar(self: *Func, active_local_var_index: usize) *LocalVar {
            const local_var_index = self.active_local_vars[active_local_var_index];
            return &self.local_vars.items[local_var_index];
        }

        /// searchvar equivalent
        /// Returns the index to the active local var, if found
        pub fn findLocalVarByToken(self: *Func, name_token: Token, source: []const u8) ?usize {
            if (self.num_active_local_vars == 0) return null;

            const name_to_find = source[name_token.start..name_token.end];
            var i: usize = self.num_active_local_vars - 1;
            while (true) : (i -= 1) {
                const cur_name_token = self.getlocvar(i).name_token;
                const cur_name = source[cur_name_token.start..cur_name_token.end];
                if (std.mem.eql(u8, cur_name, name_to_find)) {
                    return i;
                }
                if (i == 0) break;
            }
            return null;
        }

        pub fn exp2val(self: *Func, e: *ExpDesc) !void {
            if (e.hasjumps()) {
                _ = try self.exp2anyreg(e);
            } else {
                try self.dischargevars(e);
            }
        }

        pub fn exp2RK(self: *Func, e: *ExpDesc) !u9 {
            try self.exp2val(e);
            switch (e.desc) {
                .number, .true, .false, .nil => {
                    if (self.constants.items.len <= zua.opcodes.rk_max_constant_index) {
                        const constant: Constant = switch (e.desc) {
                            .nil => Constant{ .nil = {} },
                            .true, .false => Constant{ .boolean = e.desc == .true },
                            .number => Constant{ .number = e.desc.number },
                            else => unreachable,
                        };
                        const index = try self.putConstant(constant);
                        return zua.opcodes.constantIndexToRK(@intCast(index));
                    }
                },
                .constant_index => {
                    if (e.desc.constant_index <= zua.opcodes.rk_max_constant_index) {
                        return zua.opcodes.constantIndexToRK(@intCast(e.desc.constant_index));
                    }
                },
                else => {},
            }
            // not a constant in the right range, put it in a register
            return @intCast(try self.exp2anyreg(e));
        }

        pub fn indexed(self: *Func, table: *ExpDesc, key: *ExpDesc) !void {
            const key_register_or_constant_index = try self.exp2RK(key);
            // TODO can this be some other type here?
            const table_register = table.desc.nonreloc.result_register;
            table.desc = .{
                .indexed = .{
                    .table_register = table_register,
                    .key_register_or_constant_index = key_register_or_constant_index,
                },
            };
        }

        /// luaK_self equivalent
        pub fn handleSelf(self: *Func, e: *ExpDesc, key: *ExpDesc) !void {
            _ = try self.exp2anyreg(e);
            try self.freeexp(e);
            const setup_reg_start = self.free_register;
            try self.reserveregs(2);
            // TODO: Is it possible for this to be something other than nonreloc?
            const table_reg = e.desc.nonreloc.result_register;
            const key_rk = try self.exp2RK(key);
            _ = try self.emitInstruction(
                Instruction.Self.init(setup_reg_start, table_reg, key_rk),
            );
            try self.freeexp(key);
            e.desc = .{ .nonreloc = .{ .result_register = setup_reg_start } };
        }

        pub fn storevar(self: *Func, var_e: *ExpDesc, e: *ExpDesc) !void {
            switch (var_e.desc) {
                .local_register => |local_register| {
                    try self.freeexp(e);
                    try self.exp2reg(e, local_register);
                    return;
                },
                .upvalue_index => {
                    @panic("TODO");
                },
                .global => |global| {
                    const source_reg = try self.exp2anyreg(e);
                    const name_constant_index = global.name_constant_index;
                    _ = try self.emitInstruction(
                        Instruction.SetGlobal.init(name_constant_index, source_reg),
                    );
                },
                .indexed => {
                    @panic("TODO");
                },
                else => unreachable,
            }
            try self.freeexp(e);
        }

        pub fn setlist(self: *Func, base: u8, num_values: usize, to_store: ?usize) !void {
            const setlist_inst = Instruction.SetList.init(base, num_values, to_store);
            _ = try self.emitInstruction(setlist_inst);

            // if the batch number can't fit in the C field, then
            // we use an entire 'instruction' to represent it, but the instruction
            // is just the value itself (no opcode, etc)
            if (setlist_inst.isBatchNumberStoredInNextInstruction()) {
                const flush_batch_num = Instruction.SetList.numValuesToFlushBatchNum(num_values);
                _ = try self.emitInstruction(@as(u32, @intCast(flush_batch_num)));
            }

            self.free_register = base + 1;
        }

        pub fn codenot(self: *Func, e: *ExpDesc) !void {
            try self.dischargevars(e);
            switch (e.desc) {
                .nil, .false => {
                    e.desc = .{ .true = {} };
                },
                .constant_index, .number, .true => {
                    e.desc = .{ .false = {} };
                },
                .jmp => @panic("TODO"),
                .relocable, .nonreloc => {
                    try self.discharge2anyreg(e);
                    try self.freeexp(e);
                    const value_reg = e.desc.nonreloc.result_register;
                    const instruction_index = try self.emitInstruction(
                        // result register is to-be-determined
                        Instruction.Not.init(0, value_reg),
                    );
                    e.desc = .{ .relocable = .{ .instruction_index = instruction_index } };
                },
                else => unreachable,
            }
            if (e.hasjumps()) {
                @panic("TODO");
            }
        }

        pub fn prefix(self: *Func, un_op: Token, e: *ExpDesc) !void {
            switch (un_op.id) {
                .keyword_not => try self.codenot(e),
                .single_char => switch (un_op.char.?) {
                    '-' => {
                        if (!e.isnumeral()) {
                            _ = try self.exp2anyreg(e);
                        }
                        try self.codearith(.unm, e, null);
                    },
                    '#' => {
                        _ = try self.exp2anyreg(e);
                        try self.codearith(.len, e, null);
                    },
                    else => unreachable,
                },
                else => unreachable,
            }
        }

        pub fn infix(self: *Func, bin_op: Token, e: *ExpDesc) !void {
            switch (bin_op.id) {
                .keyword_and => @panic("TODO"),
                .keyword_or => @panic("TODO"),
                .concat => _ = try self.exp2nextreg(e),
                .single_char => switch (bin_op.char.?) {
                    '+', '-', '*', '/', '%', '^' => {
                        if (!e.isnumeral()) {
                            _ = try self.exp2RK(e);
                        }
                        return;
                    },
                    else => {},
                },
                else => {},
            }
            _ = try self.exp2RK(e);
        }

        pub fn posfix(self: *Func, bin_op: Token, e1: *ExpDesc, e2: *ExpDesc) !void {
            switch (bin_op.id) {
                .keyword_and => @panic("TODO"),
                .keyword_or => @panic("TODO"),
                .concat => {
                    try self.exp2val(e2);
                    if (e2.desc == .relocable and self.getcode(e2).op == .concat) {
                        const new_start_reg = e1.desc.nonreloc.result_register;
                        var concat_inst: *Instruction.Concat = @ptrCast(self.getcode(e2));
                        // Needs to remain consecutive
                        std.debug.assert(new_start_reg + 1 == concat_inst.getStartReg());
                        try self.freeexp(e1);
                        concat_inst.setStartReg(new_start_reg);
                        e1.desc = .{ .relocable = .{ .instruction_index = e2.desc.relocable.instruction_index } };
                    } else {
                        // operand must be on the 'stack'
                        // Note: Doing this avoids hitting unreachable when concatting
                        // two number literals, since it would force a literal into
                        // a register here (so the numeral check when const folding will fail).
                        _ = try self.exp2nextreg(e2);
                        try self.codearith(.concat, e1, e2);
                    }
                },
                .single_char => switch (bin_op.char.?) {
                    '+', '-', '*', '/', '%', '^' => try self.codearith(Instruction.BinaryMath.tokenToOpCode(bin_op), e1, e2),
                    '>' => @panic("TODO"),
                    '<' => @panic("TODO"),
                    else => unreachable,
                },
                .eq => @panic("TODO"),
                .ne => @panic("TODO"),
                .le => @panic("TODO"),
                .ge => @panic("TODO"),
                else => unreachable,
            }
        }

        pub fn codearith(self: *Func, op: OpCode, e1: *ExpDesc, e2: ?*ExpDesc) !void {
            if (try self.constfolding(op, e1, e2)) {
                return;
            } else {
                const o2 = if (e2 != null) try self.exp2RK(e2.?) else 0;
                const o1 = try self.exp2RK(e1);
                if (o1 > o2) {
                    try self.freeexp(e1);
                    if (e2 != null) {
                        try self.freeexp(e2.?);
                    }
                } else {
                    if (e2 != null) {
                        try self.freeexp(e2.?);
                    }
                    try self.freeexp(e1);
                }
                const instruction_index = try self.emitInstruction(
                    // result register is to-be-determined
                    Instruction.BinaryMath.init(op, 0, o1, o2),
                );
                e1.desc = .{ .relocable = .{ .instruction_index = instruction_index } };
            }
        }

        pub fn constfolding(self: *Func, op: OpCode, e1: *ExpDesc, e2: ?*ExpDesc) !bool {
            _ = self;
            // can only fold number literals
            if (e2 == null and !e1.isnumeral()) return false;
            if (e2 != null and (!e1.isnumeral() or !e2.?.isnumeral())) return false;

            const v1: f64 = e1.desc.number;
            const v2: f64 = if (e2 != null) e2.?.desc.number else 0;
            var r: f64 = 0;

            switch (op) {
                .add => r = v1 + v2,
                .sub => r = v1 - v2,
                .mul => r = v1 * v2,
                .div => {
                    if (v2 == 0) return false; // don't divide by 0
                    r = v1 / v2;
                },
                .mod => {
                    if (v2 == 0) return false; // don't mod by 0
                    r = @mod(v1, v2);
                },
                .pow => r = std.math.pow(f64, v1, v2),
                .unm => r = -v1,
                .len => return false,
                else => unreachable,
            }
            // TODO numisnan

            e1.desc.number = r;
            return true;
        }

        /// Current instruction pointer
        pub fn pc(self: *Func) usize {
            return self.code.items.len;
        }
    };

    pub const ExpDesc = struct {
        desc: union(ExpDesc.Kind) {
            void: void,
            nil: void,
            true: void,
            false: void,
            constant_index: u18,
            number: f64,
            local_register: u8,
            upvalue_index: usize,
            global: struct {
                name_constant_index: u18,
            },
            indexed: struct {
                table_register: u8,
                key_register_or_constant_index: u9,
            },
            jmp: InstructionIndex,
            relocable: InstructionIndex,
            nonreloc: struct {
                result_register: u8,
            },
            call: InstructionIndex,
            vararg: InstructionIndex,
        },
        // TODO the types here should be revisited
        patch_list: struct {
            exit_when_true: ?usize = null,
            exit_when_false: ?usize = null,
        } = .{},

        // A wrapper struct for usize so that it can have a descriptive name
        // and each tag that uses it can share the same type
        pub const InstructionIndex = struct {
            instruction_index: usize,
        };

        pub const Kind = enum {
            void,
            nil,
            true,
            false,
            constant_index,
            number,
            local_register,
            upvalue_index,
            global,
            indexed,
            jmp,
            relocable,
            nonreloc,
            call,
            vararg,
        };

        pub fn hasjumps(self: *ExpDesc) bool {
            return self.patch_list.exit_when_true != null or self.patch_list.exit_when_false != null;
        }

        pub fn hasmultret(self: *ExpDesc) bool {
            return self.desc == .call or self.desc == .vararg;
        }

        pub fn isnumeral(self: *ExpDesc) bool {
            return self.desc == .number and !self.hasjumps();
        }
    };

    pub fn genChunk(self: *Compiler, chunk: *Node.Chunk) Error!*Func {
        const main_func: *Func = try self.arena.create(Func);
        main_func.* = .{
            .code = std.ArrayList(Instruction).init(self.arena),
            .constants = std.ArrayList(Constant).init(self.arena),
            .constants_map = Constant.Map.init(self.arena),
            .local_vars = std.ArrayList(Func.LocalVar).init(self.arena),
            .varargs = .{ .is_var_arg = true }, // main func is always vararg
            .prev = null,
        };

        self.func = main_func;

        for (chunk.body) |node| {
            try self.genNode(node);

            std.debug.assert(self.func.max_stack_size >= self.func.free_register);
            std.debug.assert(self.func.free_register >= self.func.num_active_local_vars);

            self.func.free_register = self.func.num_active_local_vars;
        }

        try self.func.removevars(0);

        // In the PUC Lua implementation, this final return is added in close_func.
        // It is added regardless of whether or not there is already a return, e.g.
        // a file with just `return 1` in it will actually have 2 return instructions
        // (one for the explicit return and then this one)
        _ = try self.func.emitReturn(0, 0);

        return main_func;
    }

    pub fn genNode(self: *Compiler, node: *Node) Error!void {
        switch (node.id) {
            .chunk => unreachable, // should call genChunk directly, it should always be the root of a tree
            .call => try self.genCall(@fieldParentPtr(Node.Call, "base", node)),
            .assignment_statement => try self.genAssignmentStatement(@fieldParentPtr(Node.AssignmentStatement, "base", node)),
            .literal => try self.genLiteral(@fieldParentPtr(Node.Literal, "base", node)),
            .identifier => try self.genIdentifier(@fieldParentPtr(Node.Identifier, "base", node)),
            .return_statement => try self.genReturnStatement(@fieldParentPtr(Node.ReturnStatement, "base", node)),
            .field_access => try self.genFieldAccess(@fieldParentPtr(Node.FieldAccess, "base", node)),
            .index_access => try self.genIndexAccess(@fieldParentPtr(Node.IndexAccess, "base", node)),
            .table_constructor => try self.genTableConstructor(@fieldParentPtr(Node.TableConstructor, "base", node)),
            .table_field => unreachable, // should never be called outside of genTableConstructor
            .binary_expression => try self.genBinaryExpression(@fieldParentPtr(Node.BinaryExpression, "base", node)),
            .grouped_expression => try self.genGroupedExpression(@fieldParentPtr(Node.GroupedExpression, "base", node)),
            .unary_expression => try self.genUnaryExpression(@fieldParentPtr(Node.UnaryExpression, "base", node)),
            else => unreachable, // TODO
        }
    }

    pub fn genUnaryExpression(self: *Compiler, unary_expression: *Node.UnaryExpression) Error!void {
        try self.genNode(unary_expression.argument);
        try self.func.prefix(unary_expression.operator, &self.func.cur_exp);
    }

    pub fn genBinaryExpression(self: *Compiler, binary_expression: *Node.BinaryExpression) Error!void {
        try self.genNode(binary_expression.left);
        try self.func.infix(binary_expression.operator, &self.func.cur_exp);
        var left_exp = self.func.cur_exp;

        try self.genNode(binary_expression.right);
        try self.func.posfix(binary_expression.operator, &left_exp, &self.func.cur_exp);

        // posfix modifies the left_exp for its result, meaning we need to set it as the current
        // TODO this seems like a kind of dumb way to do this, revisit this
        self.func.cur_exp = left_exp;
    }

    pub fn genGroupedExpression(self: *Compiler, grouped_expression: *Node.GroupedExpression) Error!void {
        return self.genNode(grouped_expression.expression);
    }

    pub fn genTableConstructor(self: *Compiler, table_constructor: *Node.TableConstructor) Error!void {
        const instruction_index = try self.func.emitABC(.newtable, 0, 0, 0);
        self.func.cur_exp = .{ .desc = .{ .relocable = .{ .instruction_index = instruction_index } } };
        const table_reg = try self.func.exp2nextreg(&self.func.cur_exp);

        var num_keyed_values: zua.object.FloatingPointByteIntType = 0;
        var num_array_values: zua.object.FloatingPointByteIntType = 0;
        var unflushed_array_values: u8 = 0;
        var array_value_exp: ExpDesc = .{ .desc = .{ .void = {} } };
        for (table_constructor.fields) |field_node_base| {
            const prev_exp = self.func.cur_exp;

            // this is here so that the last array value does not get exp2nextreg called
            // on it, because we need to handle it differently if it has an unknown number
            // of returns
            if (array_value_exp.desc != .void) {
                _ = try self.func.exp2nextreg(&array_value_exp);
                array_value_exp = .{ .desc = .{ .void = {} } };

                if (unflushed_array_values >= Instruction.SetList.fields_per_flush) {
                    try self.func.setlist(table_reg, num_array_values, unflushed_array_values);
                    unflushed_array_values = 0;
                }
            }

            const field_node = @fieldParentPtr(Node.TableField, "base", field_node_base);
            try self.genTableField(field_node);
            if (field_node.key == null) {
                num_array_values += 1;
                unflushed_array_values += 1;
                array_value_exp = self.func.cur_exp;
            } else {
                num_keyed_values += 1;
            }

            self.func.cur_exp = prev_exp;
        }

        if (unflushed_array_values > 0) {
            if (array_value_exp.hasmultret()) {
                try self.func.setmultret(&array_value_exp);
                try self.func.setlist(table_reg, num_array_values, null);
                // don't count this when pre-allocating the table, since
                // we don't know how many elements will actually be added
                num_array_values -= 1;
            } else {
                if (array_value_exp.desc != .void) {
                    _ = try self.func.exp2nextreg(&array_value_exp);
                }
                try self.func.setlist(table_reg, num_array_values, unflushed_array_values);
            }
        }

        if (table_constructor.fields.len > 0) {
            const newtable_instruction: *Instruction.NewTable = @ptrCast(&self.func.code.items[instruction_index]);
            newtable_instruction.setArraySize(num_array_values);
            newtable_instruction.setTableSize(num_keyed_values);
        }
    }

    pub fn genTableField(self: *Compiler, table_field: *Node.TableField) Error!void {
        if (table_field.key == null) {
            try self.genNode(table_field.value);
        } else {
            const table_reg = self.func.cur_exp.desc.nonreloc.result_register;
            const prev_free_reg = self.func.free_register;

            try self.genNode(table_field.key.?);
            const key_rk = try self.func.exp2RK(&self.func.cur_exp);

            try self.genNode(table_field.value);
            const val_rk = try self.func.exp2RK(&self.func.cur_exp);

            _ = try self.func.emitInstruction(Instruction.SetTable.init(table_reg, key_rk, val_rk));

            self.func.free_register = prev_free_reg;
        }
    }

    pub fn genAssignmentStatement(self: *Compiler, assignment_statement: *Node.AssignmentStatement) Error!void {
        if (assignment_statement.is_local) {
            for (assignment_statement.variables, 0..) |variable_node, i| {
                // we can be certain that this is an identifier when assigning with the local keyword
                const identifier_node = @fieldParentPtr(Node.Identifier, "base", variable_node);
                const name_token = identifier_node.token;
                try self.func.new_localvar(name_token, i);
            }
            try self.genExpList1(assignment_statement.values);

            if (assignment_statement.values.len == 0) {
                self.func.cur_exp = .{
                    .desc = .{ .void = {} },
                };
            }
            try self.func.adjust_assign(assignment_statement.variables.len, assignment_statement.values.len, &self.func.cur_exp);
            try self.func.adjustlocalvars(assignment_statement.variables.len);
        } else {
            // TODO check_conflict
            // TODO checklimit 'variables in assignment'
            const var_exps = try self.arena.alloc(ExpDesc, assignment_statement.variables.len);
            defer self.arena.free(var_exps);

            for (assignment_statement.variables, 0..) |variable_node, i| {
                try self.genNode(variable_node);
                // store the ExpDesc's for use later
                var_exps[i] = self.func.cur_exp;
            }
            try self.genExpList1(assignment_statement.values);

            var last_taken_care_of = false;
            if (assignment_statement.values.len != assignment_statement.variables.len) {
                try self.func.adjust_assign(assignment_statement.variables.len, assignment_statement.values.len, &self.func.cur_exp);
                if (assignment_statement.values.len > assignment_statement.variables.len) {
                    // remove extra values
                    self.func.free_register -= @intCast(assignment_statement.values.len - assignment_statement.variables.len);
                }
            } else {
                try self.func.setoneret(&self.func.cur_exp);
                try self.func.storevar(&var_exps[var_exps.len - 1], &self.func.cur_exp);
                last_taken_care_of = true;
            }

            // traverse in reverse order to maintain compatibility with
            // PUC Lua bytecode order
            var unstored_index: usize = assignment_statement.variables.len - 1;
            if (last_taken_care_of and unstored_index > 0) unstored_index -= 1;
            const finished: bool = unstored_index == 0 and last_taken_care_of;
            while (!finished) : (unstored_index -= 1) {
                self.func.cur_exp = .{ .desc = .{ .nonreloc = .{ .result_register = self.func.free_register - 1 } } };
                try self.func.storevar(&var_exps[unstored_index], &self.func.cur_exp);
                if (unstored_index == 0) break;
            }
        }
    }

    /// helper function equivalent to explist1 in lparser.c
    fn genExpList1(self: *Compiler, nodes: []*Node) Error!void {
        for (nodes, 0..) |node, i| {
            try self.genNode(node);
            // skip the last one
            if (i != nodes.len - 1) {
                _ = try self.func.exp2nextreg(&self.func.cur_exp);
            }
        }
    }

    pub fn genReturnStatement(self: *Compiler, return_statement: *Node.ReturnStatement) Error!void {
        var first_return_reg: u8 = 0;
        var num_return_values: ?u9 = @intCast(return_statement.values.len);

        if (num_return_values.? > 0) {
            try self.genExpList1(return_statement.values);

            if (self.func.cur_exp.hasmultret()) {
                try self.func.setmultret(&self.func.cur_exp);
                // tail call?
                if (self.func.cur_exp.desc == .call and num_return_values.? == 1) {
                    const instruction: *Instruction.Call = @ptrCast(self.func.getcode(&self.func.cur_exp));
                    instruction.instruction.op = .tailcall;
                    std.debug.assert(instruction.getResultRegStart() == self.func.num_active_local_vars);
                }
                first_return_reg = self.func.num_active_local_vars;
                num_return_values = null;
            } else {
                if (num_return_values.? == 1) {
                    first_return_reg = try self.func.exp2anyreg(&self.func.cur_exp);
                } else {
                    _ = try self.func.exp2nextreg(&self.func.cur_exp);
                    first_return_reg = self.func.num_active_local_vars;
                    std.debug.assert(num_return_values.? == self.func.free_register - first_return_reg);
                }
            }
        }

        _ = try self.func.emitReturn(first_return_reg, num_return_values);
    }

    pub fn genCall(self: *Compiler, call: *Node.Call) Error!void {
        try self.genNode(call.expression);
        var is_self_call = false;
        if (call.expression.id == .field_access) {
            const field_access_node = @fieldParentPtr(Node.FieldAccess, "base", call.expression);
            is_self_call = field_access_node.separator.isChar(':');
        }
        if (!is_self_call) {
            _ = try self.func.exp2nextreg(&self.func.cur_exp);
        }
        const func_exp = self.func.cur_exp;
        std.debug.assert(func_exp.desc == .nonreloc);
        const base: u8 = @intCast(func_exp.desc.nonreloc.result_register);

        for (call.arguments) |argument_node| {
            try self.genNode(argument_node);
            _ = try self.func.exp2nextreg(&self.func.cur_exp);
        }
        const nparams = self.func.free_register - (base + 1);

        // assume 1 return value if this is not a statement, will be modified as necessary later
        const num_return_values: u9 = if (call.is_statement) 0 else 1;
        const index = try self.func.emitInstruction(Instruction.Call.init(base, @intCast(nparams), num_return_values));
        self.func.cur_exp = .{ .desc = .{ .call = .{ .instruction_index = index } } };

        // call removes function and arguments, and leaves (unless changed) one result
        self.func.free_register = base + 1;
    }

    pub fn genLiteral(self: *Compiler, literal: *Node.Literal) Error!void {
        switch (literal.token.id) {
            .string => {
                const string_source = self.source[literal.token.start..literal.token.end];
                const buf = try self.arena.alloc(u8, string_source.len);
                defer self.arena.free(buf);
                const parsed = zua.parse_literal.parseString(string_source, buf);
                const index = try self.putConstant(Constant{ .string = parsed });
                self.func.cur_exp.desc = .{ .constant_index = index };
            },
            .number => {
                const number_source = self.source[literal.token.start..literal.token.end];
                const parsed = zua.parse_literal.parseNumber(number_source);
                self.func.cur_exp.desc = .{ .number = parsed };
            },
            .keyword_true => {
                self.func.cur_exp.desc = .{ .true = {} };
            },
            .keyword_false => {
                self.func.cur_exp.desc = .{ .false = {} };
            },
            .keyword_nil => {
                self.func.cur_exp.desc = .{ .nil = {} };
            },
            .ellipsis => {
                const instruction_index = try self.func.emitInstruction(Instruction.VarArg.init(0, 0));
                self.func.cur_exp = .{ .desc = .{ .vararg = .{ .instruction_index = instruction_index } } };
            },
            .name => {
                const name = self.source[literal.token.start..literal.token.end];
                const constant_index = try self.putConstant(Constant{ .string = name });
                self.func.cur_exp = .{ .desc = .{ .constant_index = constant_index } };
            },
            else => unreachable,
        }
    }

    pub fn genIdentifier(self: *Compiler, node: *Node.Identifier) Error!void {
        if (self.func.findLocalVarByToken(node.token, self.source)) |active_local_var_index| {
            self.func.cur_exp = .{ .desc = .{ .local_register = @intCast(active_local_var_index) } };
            // TODO if (!base) markupval()
        } else {
            // TODO upvalues
            const name = self.source[node.token.start..node.token.end];
            const index = try self.putConstant(Constant{ .string = name });
            self.func.cur_exp = .{ .desc = .{ .global = .{ .name_constant_index = index } } };
        }
    }

    pub fn genFieldAccess(self: *Compiler, node: *Node.FieldAccess) Error!void {
        if (node.separator.isChar(':')) {
            try self.genNode(node.prefix);

            const name = self.source[node.field.start..node.field.end];
            const constant_index = try self.putConstant(Constant{ .string = name });
            var key = ExpDesc{ .desc = .{ .constant_index = constant_index } };

            try self.func.handleSelf(&self.func.cur_exp, &key);
        } else {
            try self.genNode(node.prefix);
            _ = try self.func.exp2anyreg(&self.func.cur_exp);

            const name = self.source[node.field.start..node.field.end];
            const constant_index = try self.putConstant(Constant{ .string = name });
            var key = ExpDesc{ .desc = .{ .constant_index = constant_index } };
            try self.func.indexed(&self.func.cur_exp, &key);
        }
    }

    pub fn genIndexAccess(self: *Compiler, node: *Node.IndexAccess) Error!void {
        try self.genNode(node.prefix);
        _ = try self.func.exp2anyreg(&self.func.cur_exp);
        var table_exp = self.func.cur_exp;

        // reset and then restore afterwards
        self.func.cur_exp = ExpDesc{ .desc = .{ .void = {} } };

        try self.genNode(node.index);
        try self.func.exp2val(&self.func.cur_exp);
        try self.func.indexed(&table_exp, &self.func.cur_exp);

        self.func.cur_exp = table_exp;
    }

    pub fn putConstant(self: *Compiler, constant: Constant) Error!u18 {
        var final_constant = constant;
        if (constant == .string and !self.func.constants_map.contains(constant)) {
            // dupe the string so that the resulting Function owns all the memory
            // TODO how should this memory get cleaned up on compile error?
            const dupe = try self.allocator.dupe(u8, constant.string);
            final_constant = Constant{ .string = dupe };
        }
        return self.func.putConstant(final_constant);
    }
};

fn testCompile(source: [:0]const u8) !void {
    var chunk = try compile(std.testing.allocator, source);
    defer chunk.deinit();

    try zua.debug.checkcode(&chunk);

    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    try zua.dump.write(chunk, buf.writer());

    const luacDump = try @import("zuatest").luac.loadAndDumpAlloc(std.testing.allocator, source);
    defer std.testing.allocator.free(luacDump);

    //std.debug.print("\n", .{});
    //chunk.printCode();

    try std.testing.expectEqualSlices(u8, luacDump, buf.items);
}

test "compile hello world" {
    try testCompile("print \"hello world\"");
}

test "compile print multiple literals" {
    try testCompile("print(nil, true)");
    try testCompile("print(nil, true, false, 1)");
}

test "compile return statements" {
    try testCompile("return");
    try testCompile("return false");
    try testCompile("return false, true, \"hello\"");
}

test "compile local statements" {
    try testCompile("local a = 1");
    try testCompile(
        \\local a = "hello world"
        \\print(a)
    );
    try testCompile("local a, b");
    try testCompile("local a, b = 1");
    try testCompile("local a, b = 1, 2, 3");
}

test "loadnil to multiple variables + some quirks" {
    // no loadnil needs to be emitted, since they default to nil
    try testCompile("local a,b,c,d");
    // loadnil gets emitted here though because there's now a loadk
    // instruction before the a,b,c,d locals
    try testCompile("local e = 0; local a,b,c,d");
    // back to no loadnil if the explicit initialization is moved to the end
    try testCompile("local a,b,c,d; local e = 0");
}

test "assigning a local to another local's value" {
    try testCompile("local a, b; b = a");
}

test "assignment from function return values" {
    try testCompile("local a = f()");
    try testCompile(
        \\local a = f()
        \\print(a)
    );
    try testCompile("local a, b = f()");
    try testCompile("local a, b = f(), g()");
}

test "vararg" {
    try testCompile("local a = ...");
    try testCompile("local a, b, c = ...");
    try testCompile(
        \\local a, b, c = ...
        \\print(a, b, c)
    );
    try testCompile("return ...");
}

test "gettable" {
    try testCompile("a.b()");
    try testCompile("a.b(c.a)");
    try testCompile("a[true]()");
    try testCompile("a[1]()");
}

test "self" {
    try testCompile("a:b()");
    try testCompile("a:b(1,2,3)");
}

test "setglobal" {
    try testCompile("a = 1");
    try testCompile("a, b, c = 1, 2, 3");
    try testCompile("a = 1, 2, 3");
    try testCompile("a, b, c = 1");
}

test "getglobal and setglobal" {
    try testCompile("a = 40; local b = a");
}

test "newtable" {
    try testCompile("return {}");
    try testCompile("return {a=1}");
    try testCompile("return {[a]=1}");
    try testCompile("return {a=1, b=2, c=3}");
    try testCompile("return {1}");
    try testCompile("return {1,2,3}");
    try testCompile("return {1, a=2, 3}");
    try testCompile("return {1, 2, a=b, 3}");
    try testCompile("return {a=f()}");
    try testCompile("return {" ++ ("a," ** (Instruction.SetList.fields_per_flush + 1)) ++ "}");
    try testCompile("return {...}");
    try testCompile("return {f()}");
    try testCompile("return {f(), 1, 2, 3}");
    try testCompile("return {..., 1, 2, 3}");

    // massive number of array-like values to overflow the u9 with number of batches
    try testCompile("return {" ++ ("a," ** (std.math.maxInt(u9) * Instruction.SetList.fields_per_flush + 1)) ++ "}");
}

test "binary math operators" {
    try testCompile("return a + b");
    try testCompile("return a + b, b + c");
    try testCompile("return a + b / c * d ^ e % f");
    // const folding (the compiled version will fold this into a single constant)
    try testCompile("return (1 + 2) / 3 * 4 ^ 5 % 6");
}

test "unary minus" {
    try testCompile("return -a");
    try testCompile("return -1");
    try testCompile("return -(1+2)");
}

test "length operator" {
    try testCompile("return #a");
    try testCompile("return #(1+2)");
    try testCompile("return #{}");
}

test "not operator" {
    try testCompile("return not true");
    try testCompile("return not false");
    try testCompile("return not 1");
    try testCompile("return not 0");
    try testCompile("return not ''");
    try testCompile("return not a");
}

test "concat operator" {
    try testCompile("return 'a'..'b'");
    try testCompile("return 'a'..'b'..'c'");
    // this is a runtime error but it compiles
    try testCompile("return 1 .. 2");
}

test "tail call" {
    try testCompile("return f()");
}
