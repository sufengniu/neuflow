
----------------------------------------------------------------------
--- Class: Core
--
-- This class provides a set of methods to abstract the Dataflow Computer
-- hardware.
--
-- This file only contais the low-level functions to manipulate
-- the grid, and the bytecode
--
local Core = torch.class('neuflow.Core')

function Core:__init(args)
   -- if system specified, using platform-specific header
   self.platform = args.platform -- can be: ibm_asic | xilinx_ml605 | pico_m503
   if not self.platform then
      self.platform = 'generic'
      print('<neuflow.Core> WARNING: no platform set, using generic settings')
   end
   if self.platform ~= 'generic' then
      torch.include('neuflow', 'defines_' .. self.platform .. '.lua')
   end

   -- parse args:
   self.msg_level = args.msg_level or 'concise'  -- 'detailled', 'none' or 'concise'
   self.period_ns = args.period_ns or 1e9/oFlower.clock_freq
   self.sys_period_ns = args.sys_period_ns or 1e9/grid.clock_freq
   self.uart_freq = args.uart_freq or 57600
   self.offset_code = args.offset_code
   self.disassemble = args.disassemble

   grid.nb_grids = args.nb_grids or grid.nb_grids
   grid.nb_convs = args.nb_convs or grid.nb_convs
   grid.nb_mappers = args.nb_mappers or grid.nb_mappers
   grid.kernel_width = args.ker_size or grid.kernel_width
   grid.kernel_height = args.ker_size or grid.kernel_height

   streamer.stride_b = args.memory_stride_b or streamer.stride_b
   streamer.stride_w = streamer.stride_b / streamer.word_b
   memory.size_b = args.memory_size or memory.size_b
   memory.size_w = memory.size_b / streamer.word_b
   memory.size_r = memory.size_b / streamer.stride_b
   oFlower.cache_size_b = args.cache_size or oFlower.cache_size_b

   -- linker
   self.linker = neuflow.Linker {
      init_offset =  self.offset_code,
      disassemble =  self.disassemble
   }

   -- memory manager
   self.mem = neuflow.Memory {
      prog_name = args.prog_name,
      init_offset =  self.offset_code,
   }

   -- loop data structure
   self.ladmin = self:LoopAdministrator()

   -- convolver state
   self.nb_kernels_loaded = {} for i=1,grid.nb_convs do self.nb_kernels_loaded[i] = 0 end

   -- load all methods from CoreUser
   for k,method in pairs(neuflow.CoreUser) do
      self[k] = method
   end

   -- info
   c = sys.COLORS
   print(c.none .. '++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++')
   print('Targetting the ' .. c.Green .. 'neuFlow'.. c.none .. ' core '
         .. '[arch = ' .. c.Cyan .. 'openFlow' .. c.none .. ']')
   print(string.format(' + Platform:        %s', self.platform))
   print(string.format(' + NumericCoding:   Q%d.%d [%f:%f:%f]', num.int_, num.frac_,
                       num.min, num.res, num.max))
   print(string.format(' + NonLinMappers:   %dx%d [x%d MACs]', grid.nb_grids, grid.nb_mappers, grid.mapper_segs))
   print(string.format(' + ConvGrids:       %dx%d [x%dx%d MACs]', grid.nb_grids, grid.nb_convs,
                       grid.kernel_height, grid.kernel_width))
   print(string.format(' + StreamALUs:      %dx%d [x1 (MAC+DIV)]', grid.nb_grids, grid.nb_alus))
   print(string.format(' + GridPorts:       %d', grid.nb_ios))
   print(string.format(' + AllPorts:        %d', streamer.nb_ports))
   print(string.format(' + ExtMemSize:      %dMB', memory.size_b / MB))
   print(string.format(' + CpuCacheSize:    %dkB', oFlower.cache_size_b / kB))
   print(string.format(' + UartSpeed:       %dbauds', self.uart_freq))
   print(string.format(' + CpuClkSpeed:     %fGHz', 1/self.period_ns))
   print(string.format(' + GridClkSpeed:    %fGHz', 1/self.sys_period_ns))
   print(string.format(' + ExtMemClkSpeed:  %fGHz', memory.clock_freq / GHz))
   if memory.is_dual then
      print(string.format(' + ExtMemBandwidthWrite: %fGiB/s', memory.bandwidth_b / GB))
      print(string.format(' + ExtMemBandwidthRead:  %fGiB/s', memory.bandwidth_b / GB))
   else
      print(string.format(' + ExtMemBandwidth: %fGiB/s', memory.bandwidth_b / GB))
   end
   print(string.format(' + Max GOP/s:       '..c.Red..'%f'..c.none,
                       (2*(grid.nb_grids*grid.nb_convs*grid.kernel_width*grid.kernel_height
                           + grid.nb_mappers + grid.nb_alus)
                     /self.sys_period_ns)))
   print('++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++')
end

function Core:bootSequence(args)
   self:nop(64)
   self:print('booting...')
   self:print(banner)
   self:configureGrid()

   local ports_to_configure = {}
   for i = 1,streamer.nb_ports-1 do table.insert(ports_to_configure,i) end
   self:configureStreamer(0, 16*1024*1024, 1024, ports_to_configure)

   if ((args.selftest ~= nil) and (args.selftest == true)) then
      self:self_test()
      self:print('----------------------------------------------------------')
      self:print('----------------------------------------------------------')
   end
   self:message('boot sequence done... going on with user code!')
   self:print('----------------------------------------------------------')
end

function Core:executionTimeSensitive(code)
   -- start sentinel
   self.linker:appendSentinel('start')

   code()

   -- end sentinel
   self.linker:appendSentinel('end')
end

function Core:startProcess()
   print('WARNING: Core:startProcess depreciated. Use executionTimeSensitive instead')
   self.linker:appendSentinel('start')
end

function Core:endProcess()
   print('WARNING: Core:endProcess depreciated. Use executionTimeSensitive instead')
   self.linker:appendSentinel('end')
end

function Core:loopRepeat(times, code, ...)
   if times ~=  0 then

      -- start loop
      local loop = {}
      if times > 0 then
         loop.reg = self:allocRegister()
         self:setreg(loop.reg, times)
      end
      loop.tag = self:makeGotoTag()
      self:nop()
      self.ladmin:push(loop)

      -- if there is code execute it
      if code then code(...) end

      -- end loop
      local breaks = self.ladmin:getBreaks()
      local loop = self.ladmin:pop()
      if times > 0 then
         self:addi(loop.reg, -1, loop.reg)
         self:gotoTagIfNonZero(loop.tag, loop.reg)
      else
         self:gotoTag(loop.tag)
      end
      self:loopBreakResolve(breaks)
   end
end

--[[ loopUntilZero

   *mode* is true or false depending on if it loops until reg is zero or until
   it is not zero. *code* is the loop body to be executed/looped over in the
   form of a function.  The code MUST return the register that is going to be
   tested.
--]]
function Core:loopUntilZero(mode, code, ...)
   self:loopUntilStart()

   if mode then
      self:loopUntilEndIfZero(code(...))
   else
      self:loopUntilEndIfNonZero(code(...))
   end
end

function Core:loopUntilStart()
   local loop = {}
   loop.tag = self:makeGotoTag()
   self:nop()

   self.ladmin:push(loop)
end

function Core:loopUntilEndIfNonZero(reg)
   local breaks = self.ladmin:getBreaks()
   local loop = self.ladmin:pop()

   self:gotoTagIfNonZero(loop.tag, reg)

   self:loopBreakResolve(breaks)
end

function Core:loopUntilEndIfZero(reg)
   local breaks = self.ladmin:getBreaks()
   local loop = self.ladmin:pop()

   self:gotoTagIfZero(loop.tag, reg)

   self:loopBreakResolve(breaks)
end

function Core:loopBreakIfNonZero(reg)
   self:gotoTagIfNonZero(nil, reg)
   self.ladmin:addBreak(self.linker:getLastReference())
end

function Core:loopBreakIfZero(reg)
   self:gotoTagIfZero(nil, reg)
   self.ladmin:addBreak(self.linker:getLastReference())
end

function Core:loopBreakResolve(breaks)
   local end_tag = self:makeGotoTag()
   self:nop()

   for break_instr in pairs(breaks) do
      break_instr.goto_tag = end_tag
   end
end

function Core:addInstruction(args)
   self.linker:appendInstruction(args)
end

function Core:addDataUINT8(binary, uint8)
   assert('table' == type(binary))
   binary[#binary+1] = uint8
end

function Core:addDataUINT16(binary, uint16)
   assert('table' == type(binary))
   binary[#binary+1] = math.floor(uint16/256^0) % 256
   binary[#binary+1] = math.floor(uint16/256^1) % 256
end

function Core:addDataUINT32(binary, uint32)
   assert('table' == type(binary))
   binary[#binary+1] = math.floor(uint32/256^0) % 256
   binary[#binary+1] = math.floor(uint32/256^1) % 256
   binary[#binary+1] = math.floor(uint32/256^2) % 256
   binary[#binary+1] = math.floor(uint32/256^3) % 256
end

function Core:addDataString(binary, str)
   assert('table' == type(binary))
   for i=1,string.len(str) do
      self:addDataUINT8(binary, str:byte(i))
   end
end

function Core:addDataPAD(binary)
   assert('table' == type(binary))
   -- pad the end of binary array to align with instruction size
   local bin_padding = 8 - (#binary % 8)
   if (bin_padding ~= 8) then
      for i=1, bin_padding do
         binary[#binary+1] = 0
      end
   end

   local ii = 0
   while ii < (#binary-1) do
      self:addInstruction {
         bytes = {
            binary[ii+1],
            binary[ii+2],
            binary[ii+3],
            binary[ii+4],
            binary[ii+5],
            binary[ii+6],
            binary[ii+7],
            binary[ii+8]
         }
      }

      ii = ii + 8
   end

   binary = {}
end

-- ALU operations
function Core:bitor(arg1, arg2, result)
   assert('table' == type(arg1) and 'register' == arg1.name)
   assert('table' == type(arg2) and 'register' == arg2.name)
   assert('table' == type(result) and 'register' == result.name)

   self:addInstruction {
      opcode = oFlower.op_or,
      arg8_1 = arg1.index,
      arg8_2 = arg2.index,
      arg8_3 = result.index,
   }
end

function Core:bitand(arg1, arg2, result)
   assert('table' == type(arg1) and 'register' == arg1.name)
   assert('table' == type(arg2) and 'register' == arg2.name)
   assert('table' == type(result) and 'register' == result.name)

   self:addInstruction {
      opcode = oFlower.op_and,
      arg8_1 = arg1.index,
      arg8_2 = arg2.index,
      arg8_3 = result.index,
   }
end

function Core:add(arg1, arg2, result)
   assert('table' == type(arg1) and 'register' == arg1.name)
   assert('table' == type(arg2) and 'register' == arg2.name)
   assert('table' == type(result) and 'register' == result.name)

   self:addInstruction {
      opcode = oFlower.op_add,
      arg8_1 = arg1.index,
      arg8_2 = arg2.index,
      arg8_3 = result.index,
   }
end

function Core:comp(arg1, arg2, result)
   assert('table' == type(arg1) and 'register' == arg1.name)
   assert('table' == type(arg2) and 'register' == arg2.name)
   assert('table' == type(result) and 'register' == result.name)

   self:addInstruction {
      opcode = oFlower.op_comp,
      arg8_1 = arg1.index,
      arg8_2 = arg2.index,
      arg8_3 = result.index,
   }
end

function Core:bitori(arg1, val, result)
   assert('table' == type(arg1) and 'register' == arg1.name)
   assert('number' == type(val))
   assert('table' == type(result) and 'register' == result.name)

   local reg = self:allocRegister()
   self:setreg(reg, val)
   self:addInstruction {
      opcode = oFlower.op_or,
      arg8_1 = arg1.index,
      arg8_2 = reg.index,
      arg8_3 = result.index,
   }
end

function Core:bitandi(arg1, val, result)
   assert('table' == type(arg1) and 'register' == arg1.name)
   assert('number' == type(val))
   assert('table' == type(result) and 'register' == result.name)

   local mask = self:allocRegister()
   self:setreg(mask, val)
   self:addInstruction {
      opcode = oFlower.op_and,
      arg8_1 = arg1.index,
      arg8_2 = mask.index,
      arg8_3 = result.index,
   }
end

function Core:addi(arg1, val, result)
   assert('table' == type(arg1) and 'register' == arg1.name)
   assert('number' == type(val))
   assert('table' == type(result) and 'register' == result.name)

   local reg = self:allocRegister()
   self:setreg(reg, val)
   self:addInstruction {
      opcode = oFlower.op_add,
      arg8_1 = arg1.index,
      arg8_2 = reg.index,
      arg8_3 = result.index,
   }
end

function Core:compi(arg1, val, result)
   assert('table' == type(arg1) and 'register' == arg1.name)
   assert('number' == type(val))
   assert('table' == type(result) and 'register' == result.name)

   local reg = self:allocRegister()
   self:setreg(reg, val)
   self:addInstruction {
      opcode = oFlower.op_comp,
      arg8_1 = arg1.index,
      arg8_2 = reg.index,
      arg8_3 = result.index,
   }
end

function Core:shri(arg1, val, result, mode)
   assert('table' == type(arg1) and 'register' == arg1.name)
   assert('number' == type(val))
   assert('table' == type(result) and 'register' == result.name)
   assert('string' == type(mode))

   -- mode:
   if mode == 'arith' then
      mode = 1
   elseif mode == 'logic' then
      mode = 0
   end

   if val == 1 then
      -- only one instruction
      self:addInstruction {
         opcode = oFlower.op_shr,
         arg8_1 = arg1.index,
         arg8_2 = mode,
         arg8_3 = result.index,
      }
   else
      -- first shift
      self:addInstruction {
         opcode = oFlower.op_shr,
         arg8_1 = arg1.index,
         arg8_2 = mode,
         arg8_3 = result.index,
      }

      -- create loop
      self:loopRepeat(val-1, function()
         -- shift right
         self:addInstruction {
            opcode = oFlower.op_shr,
            arg8_1 = result.index,
            arg8_2 = mode,
            arg8_3 = result.index,
         }
      end);
   end
end

function Core:nop(times)
   if times then
      assert('number' == type(times))

      for i = 1,times do
         self:addInstruction{opcode = oFlower.op_nop}
      end
   else
      self:addInstruction{opcode = oFlower.op_nop}
   end
end

function Core:iowrite(io, reg)
   assert('table' == type(reg) and 'register' == reg.name)
   assert('number' == type(io))

   self:addInstruction {
      opcode = oFlower.op_writeWord,
      arg8_1 = io,
      arg8_2 = reg.index
   }
end

function Core:ioread(io, reg)
   assert('table' == type(reg) and 'register' == reg.name)
   assert('number' == type(io))

   self:addInstruction {
      opcode = oFlower.op_readWord,
      arg8_1 = io,
      arg8_2 = reg.index
   }
end

function Core:setreg(reg, val)
   assert('table' == type(reg) and 'register' == reg.name)
   assert('number' == type(val))

   -- store value in register
   self:addInstruction {
      opcode = oFlower.op_setReg,
      arg8_2 = reg.index,
      arg32_1 = val
   }
end

function Core:makeGotoTag()
   -- the tag points to next instruction after this function is called
   return {
      name = 'gototag',
      ref = self.linker:getLastReference(),
      offset = 1
   }
end

function Core:gotoTag(goto_tag)
   assert(('table' == type(goto_tag) and 'gototag' == goto_tag.name) or nil)

   -- goto instruction
   self:addInstruction {
      goto_tag = goto_tag,
      opcode = oFlower.op_goto,
      arg8_1 = 0,
      arg32_1 = 0
   }
end

function Core:gotoTagIfNonZero(goto_tag, reg)
   assert(('table' == type(goto_tag) and 'gototag' == goto_tag.name) or nil)
   assert('table' == type(reg) and 'register' == reg.name)

   -- goto instruction
   self:addInstruction {
      goto_tag = goto_tag,
      opcode = oFlower.op_goto,
      arg8_1 = 1,
      arg8_2 = reg.index,
      arg32_1 = 0
   }
end

function Core:gotoTagIfZero(goto_tag, reg)
   assert(('table' == type(goto_tag) and 'gototag' == goto_tag.name) or nil)
   assert('table' == type(reg) and 'register' == reg.name)

   -- goto instruction
   self:addInstruction {
      goto_tag = goto_tag,
      opcode = oFlower.op_goto,
      arg8_1 = 2,
      arg8_2 = reg.index,
      arg32_1 = 0
   }
end

function Core:gotoGlobal(globaladdr)
   assert('number' == type(globaladdr))

   -- goto instruction
   self:addInstruction {
      opcode = oFlower.op_goto,
      arg8_1 = 0,
      arg32_1 = globaladdr
   }
end

function Core:gotoGlobalIfNonZero(globaladdr, reg)
   assert('number' == type(globaladdr))
   assert('table' == type(reg) and 'register' == reg.name)

   -- goto instruction
   self:addInstruction {
      opcode = oFlower.op_goto,
      arg8_1 = 1,
      arg8_2 = reg.index,
      arg32_1 = globaladdr
   }
end

function Core:gotoGlobalIfZero(globaladdr, reg)
   assert('number' == type(globaladdr))
   assert('table' == type(reg) and 'register' == reg.name)

   -- goto instruction
   self:addInstruction {
      opcode = oFlower.op_goto,
      arg8_1 = 2,
      arg8_2 = reg.index,
      arg32_1 = globaladdr
   }
end

function Core:gotoRelative(reladdr)
   assert('number' == type(reladdr))

   -- add a tag, to be resolved later
   local goto_tag = self:makeGotoTag()
   goto_tag.offset = goto_tag.offset + reladdr

   -- goto instruction
   self:addInstruction {
      goto_tag = goto_tag,
      opcode = oFlower.op_goto,
      arg8_1 = 0,
      arg32_1 = 0
   }
end

function Core:gotoRelativeIfNonZero(reladdr, reg)
   assert('number' == type(reladdr))
   assert('table' == type(reg) and 'register' == reg.name)

   -- add a tag, to be resolved later
   local goto_tag = self:makeGotoTag()
   goto_tag.offset = goto_tag.offset + reladdr

   -- goto instruction
   self:addInstruction {
      goto_tag = goto_tag,
      opcode = oFlower.op_goto,
      arg8_1 = 1,
      arg8_2 = reg.index,
      arg32_1 = 0
   }
end

function Core:gotoRelativeIfZero(reladdr, reg)
   assert('number' == type(reladdr))
   assert('table' == type(reg) and 'register' == reg.name)

   -- add a tag, to be resolved later
   local goto_tag = self:makeGotoTag()
   goto_tag.offset = goto_tag.offset + reladdr

   -- goto instruction
   self:addInstruction {
      goto_tag = goto_tag,
      opcode = oFlower.op_goto,
      arg8_1 = 2,
      arg8_2 = reg.index,
      arg32_1 = 0
   }
end


-- Configuration operations

function Core:openPortWr(port, data)
   -- Stream image in
   self:activateStreamerPort(port, 'write', data)
end

function Core:openPortRd(port, data)
   -- Stream image out
   self:activateStreamerPort(port, 'read', data)
end

function Core:openPortRdNoSync(port, data)
   -- Stream image out, no sync
   self:activateStreamerPort(port, 'read', data, 'off')
end

function Core:syncPortRd(port)
   -- select port and wait for primed status
   self:send_selectModule(blast_bus.area_streamer, blast_bus.addr_mem_streamer_0+port, 0)
   self:getStatus(blast_bus.status_primed)
   self:send_activate()
end

function Core:closePort(port)
   self:deActivateStreamerPort(port)
end

function Core:closePortSafe(port)
   -- safe closing involves checking the status of the port
   self:send_selectModule(blast_bus.area_streamer, blast_bus.addr_mem_streamer_0+port, 0)
   self:getStatus(blast_bus.status_done)
   self:nop()
   self:deActivateStreamerPort(port)
end

function Core:deActivateStreamerPort(port)
   self:send_selectModule(blast_bus.area_streamer, blast_bus.addr_mem_streamer_0+port, 0)
   self:send_deActivate()
   if (self.msg_level == 'detailled') then
      self:message('deactivating.port.' .. port)
   end
end

function Core:activateStreamerPort(port, mode, data, sync)
   local offset_y = data.y
   local offset_x = data.x
   local length_y = data.h
   local length_x = data.w
   local sync = sync or 'on'

   if (self.msg_level == 'detailled') then
      self:message('activating.port.' .. port .. '.in.mode.' .. mode)
   end

   -- Coordinates
   self:send_selectModule(blast_bus.area_streamer, blast_bus.addr_mem_streamer_0+port, 2)
   self:send_coordinates(offset_x, offset_y, length_x, length_y, mode)

   -- Set mode
   self:send_selectModule(blast_bus.area_streamer, blast_bus.addr_mem_streamer_0+port, 0)
   if mode == 'read' then
      self:send_control_1() -- Prefetch
      if sync == 'on' then
         self:getStatus(blast_bus.status_primed)
         self:send_activate() -- and activate
      end
   elseif mode == 'write' then
      self:send_activate() -- activate directly
   else
      error('<neuflow.Core> ERROR: port mode must be one of: write | read')
   end
end

function Core:setPortTimeouts(timeouts)
   local str = 'port.timeouts.set.to | '
   for i=1,#timeouts do
      str = str .. timeouts[i] .. ' | '
      self:send_selectModule(blast_bus.area_streamer, blast_bus.addr_mem_streamer_0+(i-1), 0)
      self:send_timeout(timeouts[i])
   end
   if (self.msg_level ~= 'none') then
      self:message(str)
   end
end

function Core:configureGrid()
   self:message('configuring.grid')
   if (self.msg_level ~= 'none') then
      self:messagebody('resetting.grid')
   end
   self:send_selectModule(blast_bus.area_tile, blast_bus.addr_broadcast, 0)
   self:send_reset()
   if (self.msg_level ~= 'none') then
      self:messagebody('resetting.connections')
   end
   self:send_selectModule(blast_bus.area_tile, blast_bus.addr_broadcast, blast_bus.subAddr_IO)
   self:send_route__all_dummys()
end

function Core:configureStreamer(offset, length, stride, ports)
   self:message('configuring.streamer')
   -- convert stride to bits to shift
   stride_bit_shift = math.log(stride) / math.log(2)

   if (self.msg_level ~= 'none') then
      self:messagebody('resetting.ports')
   end

   for i = 1,#ports do
      -- Reset the dude in case
      self:send_selectModule(blast_bus.area_streamer, blast_bus.addr_mem_streamer_0 + ports[i], 0)
      self:send_reset()
      self:getStatus(blast_bus.status_unconfigured)

      -- Global setup
      self:send_selectModule(blast_bus.area_streamer, blast_bus.addr_mem_streamer_0 + ports[i], 1)
      self:send_setup(offset, length, stride_bit_shift, 0)

      -- Coordinates (useless now, but to get the port idle)
      self:send_selectModule(blast_bus.area_streamer, blast_bus.addr_mem_streamer_0 + ports[i], 2)
      self:send_coordinates(0, 0, 0, 0, 'write')

      -- Make sure it is configured
      self:getStatus(blast_bus.status_idle)
   end

   -- set timeouts
   local timeouts = {1,64}
   for i = 1,dma.nb_ios do
      table.insert(timeouts, 1)
   end
   for i = 1,grid.nb_ios do
      table.insert(timeouts, 50)
   end
   self:setPortTimeouts(timeouts)
end

function Core:pushConfig(configContent, configWord)
   -- Send config word
   self:addInstruction {
      opcode = oFlower.op_writeConfig,
      arg8_1 = configContent,
      arg32_1 = configWord
   }
end

function Core:getStatus(statusToGet)
   -- is going to poll the status bus until it gets statusToGet
   -- arg 2 is an optional wait time before starting to read the status
   self:addInstruction {
      opcode = oFlower.op_getStatus,
      arg8_1 = statusToGet,
      arg8_2 = 128
   }
end

function Core:messagebody(str)
   -- Printing a message is just a stream to the UART
   self:addInstruction {
      opcode = oFlower.op_writeStream,
      arg8_1 = oFlower.io_uart,
      arg8_3 = oFlower.type_uint8,
      arg32_1 = string.len(str)+6
   }

   -- Then push the text data
   local binary = {}
   self:addDataString(binary, '    ')
   self:addDataString(binary, str)
   self:addDataString(binary, '\n\r')
   self:addDataPAD(binary)
end

function Core:message(str)
   -- Printing a message is just a stream to the UART
   self:addInstruction {
      opcode = oFlower.op_writeStream,
      arg8_1 = oFlower.io_uart,
      arg8_3 = oFlower.type_uint8,
      arg32_1 = string.len(str)+6
   }

   -- Then push the text data
   local binary = {}
   self:addDataString(binary, '--> ')
   self:addDataString(binary, str)
   self:addDataString(binary, '\n\r')
   self:addDataPAD(binary)
end

function Core:print(str)
   -- Printing a message is just a stream to the UART
   self:addInstruction {
      opcode = oFlower.op_writeStream,
      arg8_1 = oFlower.io_uart,
      arg8_3 = oFlower.type_uint8,
      arg32_1 = string.len(str)+2
   }

   -- Then push the text data
   local binary = {}
   self:addDataString(binary, str)
   self:addDataString(binary, '\n\r')
   self:addDataPAD(binary)
end

function Core:printraw(str)
   -- Printing a message is just a stream to the UART
   self:addInstruction {
      opcode = oFlower.op_writeStream,
      arg8_1 = oFlower.io_uart,
      arg8_3 = oFlower.type_uint8,
      arg32_1 = string.len(str)
   }

   -- Then push the text data
   local binary = {}
   self:addDataString(binary, str)
   self:addDataPAD(binary)
end

function Core:writeStringToMem(stream, str)
   -- open port
   self:openPortWr(1, stream)

   -- String length
   local length = math.ceil(string.len(str)/4)

   -- check length
   if (stream.w*stream.h)/2 ~= length then
      error('# ERROR <Core.writeStringToMem> : lengths dont match')
   end

   -- Printing a message is just a stream to the UART
   self:addInstruction {
      opcode = oFlower.op_writeStream,
      arg8_1 = oFlower.io_dma,
      arg8_3 = oFlower.type_uint32,
      arg32_1 = length
   }

   -- Then push the text data
   local binary = {}
   self:addDataString(binary, str)
   self:addDataPAD(binary)

   -- done...
   self:closePort(1)
end

function Core:readStringFromMem(stream)
   -- open port
   self:openPortRd(1, stream)

   -- get cpu reg for use in operation
   local reg_io_dma = self:allocRegister()

   -- String length
   local length = stream.w*stream.h/2

   self:loopRepeat(length, function(reg_io_dma)
      self:ioWaitForReadData(oFlower.io_dma_status)
      self:ioread(oFlower.io_dma, reg_io_dma)
      self:printReg(reg_io_dma)
   end, reg_io_dma);

   -- done...
   self:closePort(1)
end

function Core:ioWaitForReadData(ioCtrl)
   assert('number' == type(ioCtrl))

   local reg = self:allocRegister()
   self:loopUntilStart()

   self:ioread(ioCtrl, reg)
   self:bitandi(reg, 0x00000001, reg)

   self:loopUntilEndIfZero(reg)
end

function Core:ioWaitForWriteData(ioCtrl)
   assert('number' == type(ioCtrl))

   local reg = self:allocRegister()
   self:loopUntilStart()

   self:ioread(ioCtrl, reg)
   self:bitandi(reg, 0x00000002, reg)

   self:loopUntilEndIfZero(reg)
end

function Core:printReg(reg)
   assert('table' == type(reg) and 'register' == reg.name)

   self:loopRepeat(4, function(reg)
      self:ioWaitForWriteData(oFlower.io_uart_status)
      self:iowrite(oFlower.io_uart, reg)
      self:shri(reg, 8, reg, 'logic')
   end, reg);
end

function Core:putChar(reg)
   assert('table' == type(reg) and 'register' == reg.name)

   self:ioWaitForWriteData(oFlower.io_uart_status)
   self:iowrite(oFlower.io_uart, reg)
end

function Core:getCharBlocking(reg)
   assert('table' == type(reg) and 'register' == reg.name)

   self:ioWaitForReadData(oFlower.io_uart_status)
   self:ioread(oFlower.io_uart, reg)
end

function Core:getCharNonBlocking(reg, tries)
   assert('table' == type(reg) and 'register' == reg.name)
   assert('number' == type(tries))

   local reg_stat = self:allocRegister()

   self:setreg(reg, -1)

   self:loopRepeat(tries, function(reg_stat)
      self:ioread(oFlower.io_uart_status, reg_stat)
      self:bitandi(reg_stat, 0x00000001, reg_stat)
      self:loopBreakIfNonZero(reg_stat)
   end, reg_stat);

   self:ioread(oFlower.io_uart, reg)
end

function Core:flushKernel(convolver)
   assert('number' == type(convolver))

   if (self.msg_level == 'detailled') then
      self:message('flushing.kernel.cache')
   end
   self:send_selectModule(blast_bus.area_tile, blast_bus.addr_conv_0+convolver-1,
                          blast_bus.subAddr_operator)
   if (self.nb_kernels_loaded[convolver] > 0) then
      -- kernels are already there, discard the previous kernels
      local nb_discards = self.nb_kernels_loaded[convolver]
      for i=1,nb_discards do
         self:send_control_1()
         self.nb_kernels_loaded[convolver] = self.nb_kernels_loaded[convolver] - 1
      end
   end
end

-- reverts to initial state
function Core:defaults()
   -- Set all ports to Write
   if (self.msg_level == 'detailled') then
      self:message('setting.system.back.to.defaults')
   end
   -- flush kernel cache
   for i = 1,grid.nb_convs do
      self:flushKernel(i)
   end
end

-- Terminate function. Upon reception, the simul is stopped
function Core:terminate()
   -- End of code
   if (self.msg_level ~= 'none') then
      self:message('terminating')
   end
   -- reset system
   self:defaults()
   -- wait for a while
   for i=1,1000 do
      self:nop()
   end
   -- Send end code
   self:addInstruction{opcode = oFlower.op_term}
end

function Core:resetTime()
   local reg = self:allocRegister()
   -- set timer ctrl reg to 'restart'
   self:setreg(reg, 1)
   self:iowrite(oFlower.io_timer_ctrl, reg)
end

function Core:getTime()
   local reg = self:allocRegister()
   -- set timer ctrl reg to ascii readout
   self:setreg(reg, 4 + 2)
   self:iowrite(oFlower.io_timer_ctrl, reg)
   -- print header
   self:printraw('--> CPU time = ')
   -- then print timer's result
   self:addInstruction {
      opcode = oFlower.op_routeStream,
      arg8_1 = oFlower.io_timer,
      arg8_2 = oFlower.io_uart,
      arg8_3 = oFlower.type_uint8,
      arg32_1 = 9
   }  -- nb of digits (depends on the hardware)
   self:printraw(string.format(' x %0dns\n\r', self.period_ns))
end

function Core:sleep(sec)
   assert('number' == type(sec))

   local ticks = math.floor( (sec / (self.period_ns * 1e-9)) / 8 )
   self:loopRepeat(ticks)
end

-- Instuctions:
function Core:sendInstruction(instruction)
   self:pushConfig(blast_bus.content_instruc, instruction)
   self:pushConfig(blast_bus.content_nothing, 0)
   --self:pushConfig(blast_bus.content_nothing, 0)
   --self:pushConfig(blast_bus.content_nothing, 0)
end
function Core:send_config() self:sendInstruction(0) end
function Core:send_setAddr() self:sendInstruction(1) end
function Core:send_activate() self:sendInstruction(2) end
function Core:send_deActivate() self:sendInstruction(3) end
function Core:send_reset() self:sendInstruction(4) end
function Core:send_pulseToggleControls() self:sendInstruction(5) end
function Core:send_control(ctrl) self:sendInstruction(6+ctrl) end
function Core:send_control_0() self:sendInstruction(6) end
function Core:send_control_1() self:sendInstruction(7) end
function Core:send_control_2() self:sendInstruction(8) end
function Core:send_control_3() self:sendInstruction(9) end
function Core:send_control_4() self:sendInstruction(10) end
function Core:send_control_5() self:sendInstruction(11) end
function Core:send_control_6() self:sendInstruction(12) end
function Core:send_control_7() self:sendInstruction(13) end
function Core:send_cacheStart() self:sendInstruction(14) end
function Core:send_cacheFinish() self:sendInstruction(15) end

-- Commands:
function Core:send_selectModule(area, addr, modAddr)
   self:pushConfig(blast_bus.content_command, area*(2^28) + addr*(2^16) + modAddr*(2^8))
   self:pushConfig(blast_bus.content_nothing, 0)
end

function Core:send_selectAndCommand(area, addr, modAddr, command)
   self:pushConfig(blast_bus.content_command, area*(2^28) + addr*(2^16) + modAddr*(2^8) + command)
   self:pushConfig(blast_bus.content_nothing, 0)
end

-- Calculator (clement's) commands:
function Core:send_convolverConfig(dataHeight, dataWidth,
                                   kernelHeight, kernelWidth, mode,
                                   strideHeight, strideWidth)
   strideWidth = strideWidth or kernelWidth
   strideHeight = strideHeight or kernelHeight
   self:pushConfig(blast_bus.content_config, dataWidth*(2^16) + dataHeight)
   self:pushConfig(blast_bus.content_config, kernelWidth*(2^16) + kernelHeight)
   self:pushConfig(blast_bus.content_config, strideHeight*(2^24) + strideWidth*(2^16) + mode)
   for i = 1,4 do
      self:pushConfig(blast_bus.content_nothing, 0)
   end
end

function Core:send_mapperConfig(mode, segments)
   -- odd, even might be boolean up to this point
   -- but here we have to convert them to numbers
   local even
   local odd
   if (mode.even == 1) or (mode.even == true) then
      even = 1
   else even = 0
   end
   if (mode.odd == 1) or(mode.odd == true) then
      odd = 1
   else odd = 0
   end

   mode.even = even
   mode.odd = odd

   for i = 1,grid.mapper_segs do -- That's the entire nb of submappers to configure
      if (segments[i] ~= nil) then
         self:pushConfig(blast_bus.content_config, segments[i].b*(2^16) + segments[i].a)
         self:pushConfig(blast_bus.content_config, mode.odd*(2^17) + mode.even*(2^16)
                                                               + segments[i].min)
      else
         self:pushConfig(blast_bus.content_config, 0)
         self:pushConfig(blast_bus.content_config, 0)
      end
   end
   self:pushConfig(blast_bus.content_nothing, 0)
end

function Core:send_combinerConfig(op)
   if op == 'MAC' then
      self:pushConfig(blast_bus.content_config, 2^25 + 2^24 + 1)
   elseif op == 'DIV' then
      self:pushConfig(blast_bus.content_config, 2^25 + 2^24 + 2^17 + 2)
   elseif op == 'MUL' then
      self:pushConfig(blast_bus.content_config, 2^25 + 2^24 + 2^17 + 3)
   elseif op == 'ADD' then
      self:pushConfig(blast_bus.content_config, 2^25 + 2^24 + 2^17 + 4)
   elseif op == 'SUB' then
      self:pushConfig(blast_bus.content_config, 2^25 + 2^24 + 2^17 + 5)
   elseif op == 'SQUARE' then
      self:pushConfig(blast_bus.content_config, 2^25 + 2^24 + 2^17 + 2^16 + 6)
   else
      error('# ERROR <Core.send_combinerConfig> : unknown operator [%s]', op)
   end
end

function Core:concatConfig(pitch, ...)
   config = 0
   nbSlices = 32 / pitch
   maxInSlice = 2^pitch-1
   local arg = {...}
   for ii = 1,nbSlices do
      if (arg[ii] == nil) then
         config = config + maxInSlice*2^(pitch*(ii-1))
      else
         config = config + arg[ii]*2^(pitch*(ii-1))
      end
   end
   return config
end

---
-- Amazing config function for DMA ports
-- takes a config, or a table of configs as argument
-- a config contains the following fields:
--  + index    port index
--  + range    indexing mode = full | grid (default)
--  + action   direction = prefetch | read | fetch+read | fetch+read+sync+close
--                                  | write | close | sync+close
--  + data     data to read/write
--  + verbose  print info
--
function Core:configPort(args)
   -- parse args
   local configs = args
   if not (type(configs[1]) == 'table') then
      configs = {configs}
   end
   -- at this point configs is a table of configs
   for i,config in ipairs(configs) do
      -- check for index
      if not config.index then
         error('<Core:configPort> a port index needs to be provided')
      elseif not (config.range and config.range == 'full') then
         -- N first ports are invisible to the grid
         config.index = config.index + (dma.nb_ios + oFlower.nb_dmas)
      end
      -- switch to 0-based
      config.index = config.index - 1

      if config.verbose then
         print('# port #'..config.index..' exec: '..config.action)
      end

      -- execute given action
      if config.action == 'prefetch' then
         self:openPortRdNoSync(config.index, config.data)
      elseif config.action == 'sync-prefetch' then
         self:send_selectModule(blast_bus.area_streamer,
                                blast_bus.addr_mem_streamer_0+config.index, 0)
         self:getStatus(blast_bus.status_primed)
      elseif config.action == 'read' then
         self:syncPortRd(config.index)
      elseif config.action == 'activate' then
         self:send_selectModule(blast_bus.area_streamer,
                                blast_bus.addr_mem_streamer_0+config.index, 0)
         self:send_activate()
      elseif config.action == 'fetch+read' then
         self:openPortRd(config.index, config.data)
      elseif config.action == 'fetch+read+sync+close' then
         self:openPortRd(config.index, config.data)
         self:getStatus(blast_bus.status_done)
         self:closePort(config.index)
      elseif config.action == 'write' then
         self:openPortWr(config.index, config.data)
      elseif config.action == 'close' then
         self:closePort(config.index)
      elseif config.action == 'sync+close' then
         self:closePortSafe(config.index)
      else
         error('<Core:configPort> unknown action')
      end
   end
end

---
-- Amazing config function for tiles
-- takes a config, or a table of configs as argument
-- a config contains the following fields:
--
--  + operation                type of tile
--  + address                  address of tile
--  + inputs + 0 + source      for each input, a source (either a global, or a local)
--               + data                        and the data to be streamed in/out
--  + outputs + 0 + dest       same for each output
--                + data
--  + bypass                   bypass bypasses the operator: output[i] <= input[i]
--  + config                   optional config
--  + reset                    reset control
--  + control                  standard tile controls (can be a list)
--  + activate                 activate/deactivate the tile
--  + verbose                  verbose function (print info at compile time)
--
function Core:configTile(args)
   -- parse args
   local configs = args
   if not (type(configs[1]) == 'table') then
      configs = {configs}
   end
   -- at this point configs is a table of configs
   for i,config in ipairs(configs) do
      -- check for address
      if not config.address then
         error('<Core:configTile> a tile address needs to be provided')
      elseif config.operation then
         if config.operation == 'CONV2D' then
            config.address = blast_bus.addr_conv_0 + config.address - 1
         elseif config.operation == 'MAPPING' then
            config.address = blast_bus.addr_mapp_0 + config.address - 1
         else
            config.address = blast_bus.addr_comb_0 + config.address - 1
         end
      end

      -- constants
      local Z = 15 -- undriven line
      local use_out_2 = false
      local use_out_3 = false
      local int_r = 1 -- internal connex rd
      local int_w = 1 -- internal connex wr
      -- connect inputs/outputs
      if config.inputs then
         -- if no outputs fill with empty list
         if not config.outputs then
            config.outputs = {}
         end

         -- operator
         self:send_selectModule(blast_bus.area_tile, config.address, blast_bus.subAddr_operator)

         -- config operator
         if config.operation then
            if config.operation == 'CONV2D' then
               -- extract kernel, data inputs, and outputs
               -- input:
               local input_w = 1
               local input_h = 1
               if config.inputs[1] then
                  input_w = config.inputs[1].data.orig_w
                  input_h = config.inputs[1].data.orig_h
               end
               -- kernel:
               local ker_w = grid.kernel_width
               local ker_h = grid.kernel_height
               if config.inputs[2] then
                  ker_w = config.inputs[2].data.orig_w
                  ker_h = config.inputs[2].data.orig_h
                  ker_data_size = config.inputs[2].data.h * config.inputs[2].data.w
               end
               -- accumulated input:
               local acc_w,acc_h
               if config.inputs[3] then
                  acc_w = config.inputs[3].data.orig_w
                  acc_h = config.inputs[3].data.orig_h
               end
               -- output:
               local output_w = 1
               local output_h = 1
               if config.outputs[1] then
                  output_w = config.outputs[1].data.orig_w
                  output_h = config.outputs[1].data.orig_h
               end

               -- based on all these streams, generate config flags
               local mode = 0
               local stride_h = 1
               local stride_w = 1
               local mode_sameSize = 1
               local mode_accOutput = 2
               local mode_subOutput = 4
               local mode_useBias = 8
               if (input_w == output_w) and (input_h == output_h) then
                  mode = mode + mode_sameSize
               end
               if acc_w ~= nil then
                  if (acc_w ~= output_w) or (acc_h ~= output_h) then
                     error('<Core:configTile> accumulated output')
                  end
                  mode = mode + mode_accOutput
                  use_out_3 = true
               end
               if ker_data_size == (grid.kernel_height*grid.kernel_width+1)
               and config.config
               and config.config.bias == 'on' then
                  mode = mode + mode_useBias
               end
               if (output_h < (input_h-ker_h+1)) or (output_w < (input_w-ker_w+1)) then
                  mode = mode + mode_subOutput
                  stride_h = math.floor( (input_h - ker_h) / (output_h - 1) )
                  stride_w = math.floor( (input_w - ker_w) / (output_w - 1) )
                  --if (stride_h ~= math.floor(stride_h)) or (stride_w ~= math.floor(stride_w)) then
                  --   error('<Core:configTile> inconsistent input/output/kernel sizes')
                  --end
                  use_out_2 = true
               end
               -- send config
               if config.verbose then
                  print('config conv = ', input_h, input_w, ker_h, ker_w, mode, stride_h, stride_w)
               end
               self:send_convolverConfig(input_h, input_w, ker_h, ker_w, mode, stride_h, stride_w)

            elseif config.operation == 'MAPPING' then
               if not config.bypass then
                  -- for the mapper, just pass the params
                  self:send_mapperConfig(config.config.mode, config.config.segments)
               end

            else -- 'ADD', 'MAC', 'DIV' ...
               if not config.bypass then
                  self:send_combinerConfig(config.operation)
               end
            end
         end

         -- crazy hack: the subsampled line is on output 2
         if use_out_2 and not config.outputs[2] then
            config.outputs[2] = {dest = config.outputs[1].dest, data = config.outputs[1].data}
            config.outputs[1] = nil
         end
         -- crazy hack bis: the accumulated line is on output 3
         if use_out_3 and not config.outputs[3] then
            if use_out_1 then
               error('<Config:configTile> cannot use output 2 and 3')
            end
            config.outputs[3] = {dest = config.outputs[1].dest, data = config.outputs[1].data}
            config.outputs[1] = nil
         end

         -- connect to global I/Os ?
         self:send_selectModule(blast_bus.area_tile, config.address, blast_bus.subAddr_IO)
         -- write global lines:
         local w = {Z,Z,Z,Z,Z,Z,Z,Z}
         for i = 1,3 do
            if config.outputs[i] and type(config.outputs[i].dest) == 'number' then
               local port = config.outputs[i].dest
               config.outputs[i].dest = int_w -- replace global dest by local dest
               w[port] = int_w + 7 -- TODO: fix this constant
               int_w = int_w + 1
            end
         end
         if config.verbose then
            print('IO 1:', w[1], w[2], w[3], w[4], w[5], w[6], w[7], w[8])
         end
         self:pushConfig(blast_bus.content_config, self:concatConfig(4, w[1], w[2], w[3], w[4],
                                                                        w[5], w[6], w[7], w[8]))
         -- read global lines:
         local r = {Z,Z,Z}
         for i = 1,3 do
            if config.inputs[i] and type(config.inputs[i].source) == 'number' then
               local port = config.inputs[i].source
               config.inputs[i].source = int_r -- replace global source by local source
               r[int_r] = port-1
               int_r = int_r + 1
            end
         end
         if config.verbose then
            print('IO 2:', r[1], r[2], r[3])
         end
         self:pushConfig(blast_bus.content_config, self:concatConfig(4, r[1], r[2], r[3]))

         -- connect internals
         self:send_selectModule(blast_bus.area_tile, config.address, blast_bus.subAddr_router)
         -- to operator:
         local op = {Z,Z,Z}
         local neighbor = {n=Z,e=Z,s=Z,w=Z}
         local local_io = {Z,Z,Z}
         for i = 1,3 do
            if config.inputs[i] then
               if not config.bypass then
                  if type(config.inputs[i].source) == 'number' then
                     local port = config.inputs[i].source + 7 -- TODO: fix this constant
                     op[i] = port
                  elseif config.inputs[i].source then
                     local src = config.inputs[i].source
                     if src == 'north' or src == 'n' then
                        op[i] = 11
                     elseif src == 'east' or src == 'e' then
                        op[i] = 12
                     elseif src == 'south' or src == 's' then
                        op[i] = 13
                     elseif src == 'west' or src == 'w' then
                        op[i] = 14
                     else
                        error('<Core:configTile> local connections can be: w | e | s | n')
                     end
                  end
               end
            end
         end
         for i = 1,3 do
            if config.outputs[i] then
               if not config.bypass then
                  if type(config.outputs[i].dest) == 'number' then
                     local port = config.outputs[i].dest
                     local_io[port] = i-1
                  elseif config.outputs[i].dest then
                     local dest = config.outputs[i].dest
                     if dest == 'north' or dest == 'n' then
                        neighbor.n = i-1
                     elseif dest == 'east' or dest == 'e' then
                        neighbor.e = i-1
                     elseif dest == 'south' or dest == 's' then
                        neighbor.s = i-1
                     elseif dest == 'west' or dest == 'w' then
                        neighbor.w = i-1
                     else
                        error('<Core:configTile> local connections can be: w | e | s | n')
                     end
                  end
               else
                  -- bypass operator:
                  local dest = config.outputs[i].dest
                  local src = config.inputs[i].source
                  if src == 'north' or src == 'n' then
                     src = 11
                  elseif src == 'east' or src == 'e' then
                     src = 12
                  elseif src == 'south' or src == 's' then
                     src = 13
                  elseif src == 'west' or src == 'w' then
                     src = 14
                  else
                     src = src + 7
                  end
                  if dest == 'north' or dest == 'n' then
                     neighbor.n = src
                  elseif dest == 'east' or dest == 'e' then
                     neighbor.e = src
                  elseif dest == 'south' or dest == 's' then
                     neighbor.s = src
                  elseif dest == 'west' or dest == 'w' then
                     neighbor.w = src
                  else
                     local_io[dest] = src
                  end
               end
            end
         end
         if config.verbose then
            print('router 1:', op[1], op[2], op[3])
         end
         self:pushConfig(blast_bus.content_config, self:concatConfig(4, op[1], op[2], op[3]))

         if config.verbose then
            print('router 2:', local_io[1], local_io[2], local_io[3],
                  neighbor.n, neighbor.e, neighbor.s, neighbor.w)
         end
         self:pushConfig(blast_bus.content_config,
                         self:concatConfig(4, local_io[1], local_io[2], local_io[3],
                                           neighbor.n, neighbor.e, neighbor.s, neighbor.w))
      end

      -- control
      if config.control then
         -- select tile
         self:send_selectModule(blast_bus.area_tile, config.address, blast_bus.subAddr_none)
         -- send controls:
         if type(config.control) == 'number' then
            config.control = {config.control}
         end
         for _,ctrl in ipairs(config.control) do
            self:send_control(ctrl)
         end
      end

      -- activate
      if config.activate ~= nil then
         -- select tile
         self:send_selectModule(blast_bus.area_tile, config.address, blast_bus.subAddr_none)
         -- activate/deactivate
         if config.activate then
            self:send_activate()
         else
            -- deactivate
            self:send_deActivate()
            -- and unconnect IOs
            self:send_selectModule(blast_bus.area_tile, config.address, blast_bus.subAddr_IO)
            self:send_route__all_dummys()
         end
      end
   end
end

-- Shitty router functions
function Core:send_route__all_dummys()
   self:pushConfig(blast_bus.content_config, self:concatConfig(4))
   self:pushConfig(blast_bus.content_config, self:concatConfig(4))
   self:pushConfig(blast_bus.content_nothing, 0)
end

function Core:send_route__0_through_1()
   self:pushConfig(blast_bus.content_config, self:concatConfig(4, 15, 0))
   self:pushConfig(blast_bus.content_config, self:concatConfig(4))
   self:pushConfig(blast_bus.content_nothing, 0)
end

function Core:send_route__01_operator_0()
   self:pushConfig(blast_bus.content_config, self:concatConfig(4, 8, 9))
   self:pushConfig(blast_bus.content_config, self:concatConfig(4, 0))
   self:pushConfig(blast_bus.content_nothing, 0)
end

function Core:send_route__01_operator_1_0()
   self:pushConfig(blast_bus.content_config, self:concatConfig(4, 8, 9))
   self:pushConfig(blast_bus.content_config, self:concatConfig(4, 1))
   self:pushConfig(blast_bus.content_nothing, 0)
end

function Core:send_route__012_012_operator_2_0()
   self:pushConfig(blast_bus.content_config, self:concatConfig(4, 8, 9, 10))
   self:pushConfig(blast_bus.content_config, self:concatConfig(4, 2))
   self:pushConfig(blast_bus.content_nothing, 0)
end

function Core:send_route__01_local_2()
   self:pushConfig(blast_bus.content_config, self:concatConfig(4, 15, 15, 8))
   self:pushConfig(blast_bus.content_config, self:concatConfig(4, 0, 1))
   self:pushConfig(blast_bus.content_nothing, 0)
end

function Core:send_route__01_local_0()
   self:pushConfig(blast_bus.content_config, self:concatConfig(4, 8))
   self:pushConfig(blast_bus.content_config, self:concatConfig(4, 0, 1))
   self:pushConfig(blast_bus.content_nothing, 0)
end

function Core:send_route__01_local()
   self:pushConfig(blast_bus.content_config, self:concatConfig(4))
   self:pushConfig(blast_bus.content_config, self:concatConfig(4, 0, 1))
   self:pushConfig(blast_bus.content_nothing, 0)
end

function Core:send_route__012_012_local_0_3()
   self:pushConfig(blast_bus.content_config, self:concatConfig(4, 15, 15, 15, 8))
   self:pushConfig(blast_bus.content_config, self:concatConfig(4, 0, 1, 2))
   self:pushConfig(blast_bus.content_nothing, 0)
end

function Core:send_route__w_operator_0()
   self:pushConfig(blast_bus.content_config, self:concatConfig(4, 14))
   self:pushConfig(blast_bus.content_config, self:concatConfig(4, 0))
   self:pushConfig(blast_bus.content_nothing, 0)
end

function Core:send_route__n_operator_0()
   self:pushConfig(blast_bus.content_config, self:concatConfig(4, 11))
   self:pushConfig(blast_bus.content_config, self:concatConfig(4, 0))
   self:pushConfig(blast_bus.content_nothing, 0)
end

function Core:send_route__s_operator_0()
   self:pushConfig(blast_bus.content_config, self:concatConfig(4, 13))
   self:pushConfig(blast_bus.content_config, self:concatConfig(4, 0))
   self:pushConfig(blast_bus.content_nothing, 0)
end

function Core:send_route__01_local()
   self:pushConfig(blast_bus.content_config, self:concatConfig(4))
   self:pushConfig(blast_bus.content_config, self:concatConfig(4, 0, 1))
   self:pushConfig(blast_bus.content_nothing, 0)
end

function Core:send_route__012_local()
   self:pushConfig(blast_bus.content_config, self:concatConfig(4))
   self:pushConfig(blast_bus.content_config, self:concatConfig(4, 0, 1, 2))
   self:pushConfig(blast_bus.content_nothing, 0)
end

function Core:send_route__01_operator_s()
   self:pushConfig(blast_bus.content_config, self:concatConfig(4, 8, 9))
   self:pushConfig(blast_bus.content_config, self:concatConfig(4, 15, 15, 15, 15, 15, 0))
   self:pushConfig(blast_bus.content_nothing, 0)
end

function Core:send_route__01_operator_e()
   self:pushConfig(blast_bus.content_config, self:concatConfig(4, 8, 9))
   self:pushConfig(blast_bus.content_config, self:concatConfig(4, 15, 15, 15, 15, 0))
   self:pushConfig(blast_bus.content_nothing, 0)
end

function Core:send_route__01_operator_1_e()
   self:pushConfig(blast_bus.content_config, self:concatConfig(4, 8, 9))
   self:pushConfig(blast_bus.content_config, self:concatConfig(4, 15, 15, 15, 15, 1))
   self:pushConfig(blast_bus.content_nothing, 0)
end

function Core:send_route__012_operator_2_e()
   self:pushConfig(blast_bus.content_config, self:concatConfig(4, 8, 9, 10))
   self:pushConfig(blast_bus.content_config, self:concatConfig(4, 15, 15, 15, 15, 2))
   self:pushConfig(blast_bus.content_nothing, 0)
end

-- Streamer (Berin's) commands:
function Core:send_setup(offset, length, stride, continuous_read)
   self:pushConfig(blast_bus.content_config, offset)
   self:pushConfig(blast_bus.content_config, length)
   self:pushConfig(blast_bus.content_config, stride)
   self:pushConfig(blast_bus.content_config, continuous_read)
   self:pushConfig(blast_bus.content_nothing, 0)
end

function Core:send_timeout(timeout)
   self:pushConfig(blast_bus.content_config, timeout)
end

function Core:send_coordinates(offset_x, offset_y, length_x, length_y, mode)

   if ('number' == type(offset_x)) then
      self:pushConfig(blast_bus.content_config, offset_x)
   else
      self:addInstruction {
         mem_offset = offset_x,
         opcode = oFlower.op_writeConfig,
         arg8_1 = blast_bus.content_config,
         --arg32_1 = offset_x
      }
   end

   if ('number' == type(offset_y)) then
      self:pushConfig(blast_bus.content_config, offset_y)
   else
      self:addInstruction {
         mem_offset = offset_y,
         opcode = oFlower.op_writeConfig,
         arg8_1 = blast_bus.content_config,
         --arg32_1 = offset_y
      }
   end

   self:pushConfig(blast_bus.content_config, length_x)
   self:pushConfig(blast_bus.content_config, length_y)
   if mode == 'read' then
      self:pushConfig(blast_bus.content_config, 1)
   else
      self:pushConfig(blast_bus.content_config, 0)
   end
   self:pushConfig(blast_bus.content_nothing, 0)
end

-- A battery of tests
function Core:self_test()
   self:message('OpenFlower doing selftests')

   self:messagebody('testing reg allocation')
   local reg_myvar = self:allocRegister()
   self:setreg(reg_myvar, 0)

   self:messagebody('testing I/O read')
   self:ioread(oFlower.io_uart, reg_myvar)

   self:messagebody('testing alu (bitwise and)')
   self:bitandi(reg_myvar, 0xFF0000FF, reg_myvar)

   self:messagebody('testing loop x3')

   self:loopRepeat(3, function()
      self:messagebody('...in loop')
   end);

   self:messagebody('testing register readout (should print> abc)')
   local reg_readout = self:allocRegister()
   self:setreg(reg_readout, 0x0A636261)
   self:printReg(reg_readout)

   self:messagebody('testing timer')
   self:getTime()
   self:messagebody('resetting timer')
   self:resetTime()
   self:getTime()

   self:messagebody('testing external mem')
   -- we write a test string to ext mem, and then read it back to ethernet...
   local test_stream = {y=0, x=0, w=16, h=1}
   local test_string = 'Im a string & I come from DDR3\r\n'
   self:writeStringToMem(test_stream, test_string)
   self:readStringFromMem(test_stream)

   self:getTime()
   self:message('all tests passed :-)')
end

--[[ Register Allocator:

   Provides a simple way to administer CPU registers when they are used in
   applications. A closures is created that administers a table of registers
   and keeps track of in use registers using a weak table.
--]]
do
   local _all = {
      oFlower.reg_sys_A,
      oFlower.reg_sys_B,
      oFlower.reg_sys_C,
      oFlower.reg_loops,
      oFlower.reg_A,
      oFlower.reg_B,
      oFlower.reg_C,
      oFlower.reg_D,
      oFlower.reg_E,
      oFlower.reg_F,
   }

   local _inuse = setmetatable({}, {__mode="v"})

   local _find_reg = function()
      for k, reg in pairs( _all ) do
         if not _inuse[k] then
            _inuse[k] = {
               name  = "register",
               index = reg,
            }
            return _inuse[k]
         end
      end
      return nil
   end

   function Core:allocRegister()

      local reg = _find_reg()
      if not reg then
         -- if inuse table full force garbage collection
         collectgarbage()

         reg = _find_reg()
         if not reg then
            error('<neuflow.Core> ERROR: Can not -alloc- reg as they are all in use')
         end
      end

      return reg
   end
end

--[[ Loop Administrator:

   Keeps tracks of the goto_tags for loops, this helps with nested loops etc.
--]]
function Core:LoopAdministrator()
   local admin = {}
   admin._stack = {}
   admin._break = {}

   function admin:push(loop)
      self._stack[#self._stack+1] = loop
   end

   function admin:pop()
      local loop = self._stack[#self._stack]
      self._stack[#self._stack] = nil

      return loop
   end

   function admin:peek()
      return self._stack[#self._stack]
   end

   function admin:addBreak(break_instr)
      local loop = self:peek()
      local breaks_in_loop = self._break[loop] or {}
      breaks_in_loop[#breaks_in_loop+1] = break_instr
      self._break[loop] = breaks_in_loop
   end

   function admin:getBreaks()
      local loop = self:peek()
      local breaks_in_loop = self._break[loop] or {}
      self._break[loop] = nil

      return breaks_in_loop
   end

   return admin
end
