
----------------------------------------------------------------------
--- Class: Camera
--
-- This class provides a set of methods to exchange data/info with the Camera.
--
local Camera = torch.class('neuflow.Camera')

function Camera:__init(args)
   -- args:
   self.nf = args.nf
   self.core = args.nf.core
   self.msg_level = args.msg_level or 'none'  -- 'detailled' or 'none' or 'concise'
   self.frames = {}

   self.nb_frames = 4 -- number of frames in running buffer
   -- self.Aw_ = 640
   -- self.Ah_ = 480
   -- self.Bw_ = 640
   -- self.Bh_ = 480
   self.size = {
      ['B'] = {['width'] = 640, ['height'] = 480, ['component'] = 3},
      ['A'] = {['width'] = 640, ['height'] = 480, ['component'] = 3}
   }

   self.mask = {
      ['counter']     = {['A'] = 0x0000000c, ['B'] = 0x000c0000},
      ['status']      = {['A'] = 0x00000001, ['B'] = 0x00010000},
   }

   self.conf = {
      ['acquisition'] = {
         ['value'] = {['ON'] = 0x1, ['OFF'] = 0x0},
         ['mask'] = 0x1,
         ['index'] = 10},
      ['definition'] = {
         ['value'] = {['QVGA'] = 0x1, ['VGA'] = 0x0},
         ['mask'] = 0x1,
         ['index'] = 0},
      ['framerate'] = {
         ['value'] = {['60FPS'] = 0x1, ['30FPS'] = 0x0},
         ['mask'] = 0x1,
         ['index'] = 1},
      ['color'] = {
         ['value'] = {['COLOR'] = 0x0, ['B&W'] = 0x1},
         ['mask'] = 0x1,
         ['index'] = 2},
      ['domain'] = {
         ['value'] = {['RGB'] = 0x1, ['YUV'] = 0x0},
         ['mask'] = 0x1,
         ['index'] = 3},
      ['scan'] = {
         ['value'] = {['INTERLACED'] = 0x0, ['PROGRESSIVE'] = 0x1},
         ['mask'] = 0x1,
         ['index'] = 4},
      ['grab'] = {
         ['value'] = {['ONESHOT'] = 0x1, ['CONTINUOUS'] = 0x0},
         ['mask'] = 0x1,
         ['index'] = 8},
      ['power'] = {
         ['value'] = {['ON'] = 0x1, ['OFF'] = 0x0},
         ['mask'] = 0x1,
         ['index'] = 11},
      ['iic'] = {
         ['value'] = {['ON'] = 0x1, ['OFF'] = 0x0},
         ['mask'] = 0x1,
         ['index'] = 12}
   }

   -- Memorize here the camera register value
   self.reg_ctrl = 0x00000000
   self.reg_status = 0x00000000

   self.cam_param = {
      ['A'] = {['port_addrs'] = dma.camera_A_port_id, ['offset'] = 0},
      ['B'] = {['port_addrs'] = dma.camera_B_port_id, ['offset'] = 16}
   }

   -- compulsory
   if (self.core == nil) then
      error('<neuflow.Camera> ERROR: requires a Dataflow Core')
   end
end

function Camera:config(cameraID, param, value)
   local temp_mask
   local temp_offset
   local lcameraID
   if #cameraID == 1 then
      lcameraID = {cameraID}
   else
      lcameraID = cameraID
   end

   for i = 1,#lcameraID do
      temp_offset = self.conf[param].index + self.cam_param[lcameraID[i]].offset
      -- Unset all dedicated bits of the config paramater
      temp_mask = bit.bnot(bit.lshift(self.conf[param].mask,temp_offset))
      self.reg_ctrl = bit.band(self.reg_ctrl, temp_mask)
      -- Set the new value in reg_ctrl
      temp_mask = bit.lshift(self.conf[param].value[value],temp_offset)
      self.reg_ctrl = bit.bor(self.reg_ctrl, temp_mask)

      -- Adjust camera memory size to definition
      if param == 'definition' then
         if value == 'QVGA' then
            self.size[lcameraID[i]].width = 320
            self.size[lcameraID[i]].height = 240
         else
            self.size[lcameraID[i]].width = 640
            self.size[lcameraID[i]].height = 480
         end
      end
      if param == 'color' then
         if value == 'B&W' then
            self.size[lcameraID[i]].component = 1
         else
            self.size[lcameraID[i]].component = 3
         end
      end
   end

   return self.reg_ctrl
end


function Camera:initCamera(cameraID, alloc_frames)

   self.frames[cameraID] = alloc_frames
   print('<neuflow.Camera> : init Camera ' .. cameraID)

   -- puts the cameras in standby
   local reg_ctrl = self.core:allocRegister()
   self:config(cameraID,'power','ON')
   self.core:setreg(reg_ctrl, self.reg_ctrl)
   self.core:iowrite(oFlower.io_gpios, reg_ctrl)
   --self.core:sleep(1)
   self.core:message('Camera: Init done')
end

-- Not stable for now because of the camera settings. Use getLastFrame instead
function Camera:getLastFrameSafe(cameraID)
   local outputs = {}
   local lcameraID

   if #cameraID == 1 then
      lcameraID = {cameraID}
   else
      lcameraID = cameraID
   end

   for i = 1,#lcameraID do
      table.insert(outputs, self.frames[lcameraID[i]])

      self.core:closePortSafe(self.cam_param[lcameraID[i]].port_addrs)
   end
   return outputs
end

function Camera:getLastFrame(cameraID)
   local outputs = {}

   local reg_acqst = self.core:allocRegister()
   local reg_tmp = self.core:allocRegister()
   local lcameraID

   local mask_status = 0x00000000
   if #cameraID == 1 then
      lcameraID = {cameraID}
   else
      lcameraID = cameraID
   end
   for i = 1,#lcameraID do
      mask_status = bit.bor(mask_status, self.mask.status[lcameraID[i]])
   end
   self.core:loopUntilStart()
   self.core:ioread(oFlower.io_gpios, reg_acqst)
   self.core:bitandi(reg_acqst, mask_status, reg_tmp)
   self.core:compi(reg_tmp, 0x00000000, reg_tmp)
   self.core:loopUntilEndIfNonZero(reg_tmp)

   for i = 1,#lcameraID do
      table.insert(outputs, self.frames[lcameraID[i]])
      self.core:closePort(self.cam_param[lcameraID[i]].port_addrs)
   end

   return outputs
end

function Camera:captureOneFrame(cameraID)
   local lcameraID

   local reg_ctrl = self.core:allocRegister()
   local reg_acqst = self.core:allocRegister()
   local reg_tmp = self.core:allocRegister()

   local mask_ctrl = 0x00000000
   local mask_status = 0x00000000

   -- Enable camera acquisition
   if #cameraID == 1 then
      lcameraID = {cameraID}
   else
      lcameraID = cameraID
   end

   for i = 1,#lcameraID do
      self.core:openPortWr(self.cam_param[lcameraID[i]].port_addrs, self.frames[lcameraID[i]])
      mask_status = bit.bor(mask_status, self.mask.status[lcameraID[i]])
   end

   -- trigger acquisition
   mask_ctrl = self:config(cameraID, 'acquisition', 'ON')
   self.core:setreg(reg_ctrl, mask_ctrl)
   self.core:iowrite(oFlower.io_gpios, reg_ctrl)

   -- loop until acquisition has started
   self.core:loopUntilStart()
   self.core:ioread(oFlower.io_gpios, reg_acqst)
   self.core:bitandi(reg_acqst, mask_status, reg_tmp)
   self.core:compi(reg_tmp, mask_status, reg_tmp)
   self.core:loopUntilEndIfNonZero(reg_tmp)

   -- Once the acquisition start. Disable the acquisition for the next frame
   mask_ctrl = self:config(cameraID, 'acquisition', 'OFF')
   self.core:setreg(reg_ctrl, mask_ctrl)
   self.core:iowrite(oFlower.io_gpios, reg_ctrl)
end

function Camera:enableCameras(cameraID)
   local lcameraID
   if #cameraID == 1 then
      lcameraID = {cameraID}
   else
      lcameraID = cameraID
   end

   for i=1,#lcameraID do
      local image_tensor = torch.Tensor(self.size[lcameraID[i]].height, self.size[lcameraID[i]].width*self.size[lcameraID[i]].component)
      local image_segment = self.core.mem:allocPersistentData(image_tensor, '2D')

      self:initCamera(lcameraID[i], image_segment)
   end
   self.core:sleep(1)
end

function Camera:startRBCameras() -- Start camera and send images to Running Buffer

   print('<neuflow.Camera> : enable Camera: ' .. self.size['A'].width * self.size['A'].component .. 'x' .. self.size['A'].height)

   local image_tensor_A = torch.Tensor(self.size['A'].height, self.size['A'].width*self.size['A'].component)
   local image_segment_A = self.core.mem:allocPersistentData(image_tensor_A, '2D')

   local image_tensor_B = torch.Tensor(self.size['B'].height, self.size['B'].width*self.size['B'].component)
   local image_segment_B = self.core.mem:allocPersistentData(image_tensor_B, '2D')

   -- The two cameras have to be initialized in the same time if an IIC configuration occured.
   self:initCamera('B', image_segment_B)
   self:initCamera('A', image_segment_A)

   self.core:sleep(2)

   -- Global setup for DMA port (camera A and B) to make continuous
   local stride_bit_shift = math.log(1024) / math.log(2)

   self.core:send_selectModule(blast_bus.area_streamer, blast_bus.addr_mem_streamer_0+dma.camera_A_port_id, 1)
   self.core:send_setup(0, 16*1024*1024, stride_bit_shift, 1)

   self.core:send_selectModule(blast_bus.area_streamer, blast_bus.addr_mem_streamer_0+dma.camera_B_port_id, 1)
   self.core:send_setup(0, 16*1024*1024, stride_bit_shift, 1)

   -- Open the streamer ports for writing
   self.core:openPortWr(dma.camera_B_port_id, self.frames['B'])
   self.core:openPortWr(dma.camera_A_port_id, self.frames['A'])

   --self.core:sleep(0.1)
   -- Start cameras sending images
   local reg_ctrl = self.core:allocRegister()
   local mask_ctrl = self:config({'B','A'}, 'acquisition', 'ON')

   -- trigger acquisition
   self.core:setreg(reg_ctrl, mask_ctrl)
   self.core:iowrite(oFlower.io_gpios, reg_ctrl)
end

function Camera:stopRBCameras() -- Stop camera sending to Running Buffer

   local reg_acqst = self.core:allocRegister()
   local mask_status = bit.bor(self.mask.status['A'], self.mask.status['B'])
   local mask_ctrl = self:config({'A','B'}, 'acquisition', 'OFF')

   -- Once the acquisition stop. Disable the acquisition for the next frame
   self.core:setreg(reg_acqst, mask_ctrl)
   self.core:iowrite(oFlower.io_gpios, reg_acqst)
   self.core:nop(100) -- small delay

   -- wait for the frame to finish being sent
   -- self.core:loopUntilStart()
   -- self.core:ioread(oFlower.io_gpios, reg_acqst)
   -- self.core:bitandi(reg_acqst, mask_status, reg_acqst)
   -- self.core:compi(reg_acqst, 0x00000000, reg_acqst)
   -- self.core:loopUntilEndIfNonZero(reg_acqst)

   -- reset ports setup
   self.core:configureStreamer(0, 16*1024*1024, 1024, {dma.camera_A_port_id, dma.camera_B_port_id})
end

function Camera:copyToHostLatestFrame() -- Get the latest complete frame

   local reg_acqst = self.core:allocRegister()
   self.core:ioread(oFlower.io_gpios, reg_acqst)

   self:streamLatestFrameFromPort('B', reg_acqst, dma.ethernet_read_port_id, 'full')
   self.nf.ethernet:streamFromHost(self.nf.ethernet.ack_stream[1], 'ack_stream')
   self:streamLatestFrameFromPort('A', reg_acqst, dma.ethernet_read_port_id, 'full')

   return torch.Tensor(2, self.size['A'].height, self.size['A'].width)
end

function Camera:streamLatestFrameFromPort(cameraID, reg_acqst, port_addr, port_addr_range)

   function coordinateOffset(coordinate, offset)
      return {
         coordinate = coordinate,
         calc = function(self)
            return self.coordinate:calc() + offset
         end
      }
   end


   local goto_ends = {}
   local reg_count = self.core:allocRegister()

   for ii = (self.nb_frames-1), 1, -1 do
      -- copy camera status into reg but masked for frame count
      self.core:bitandi(reg_acqst, self.mask.counter[cameraID], reg_count)
      self.core:compi(reg_count, ii, reg_count) -- test if current frame is 'ii'

      -- if current frame not eq to 'ii' (reg_count == 0) goto next possible option
      self.core:gotoTagIfZero(nil, reg_count) -- goto next pos
      local goto_next = self.core.linker:getLastReference()

      -- read the last frame in running buffer
      self.core:configPort{
         index  = port_addr,
         action = 'fetch+read+sync+close',
         data   = {
            x = self.frames[cameraID].x,
            y = coordinateOffset(self.frames[cameraID].y, ((ii-1)*self.size[cameraID].height)),
            w = self.size[cameraID].width * self.size[cameraID].component,
            h = self.size[cameraID].height
         },

         range  = port_addr_range
      }

      self.core:gotoTag(nil) -- finish so goto end
      goto_ends[ii] = self.core.linker:getLastReference()

      -- next pos
      goto_next.goto_tag = self.core:makeGotoTag()
      self.core:nop()
   end

   -- if got here only option left is to read the following frame
   self.core:configPort {
      index  = port_addr,
      action = 'fetch+read+sync+close',
      data   = {
         x = self.frames[cameraID].x,
         y = coordinateOffset(self.frames[cameraID].y, ((self.nb_frames-1)*self.size[cameraID].height)),
         w = self.size[cameraID].width * self.size[cameraID].component,
         h = self.size[cameraID].height
      },

      range  = port_addr_range
   }

   -- end point
   local goto_end_tag = self.core:makeGotoTag()
   self.core:nop()

   for i, goto_end in pairs(goto_ends) do
      goto_end.goto_tag = goto_end_tag
   end
end
