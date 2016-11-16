-- usage facades: DATA_ROOT=/data/efros/isola/facades/data_for_GAN_AE/ which_direction=BtoA display_id=20 name=experiment_random_zs_facades_anno2photo continue_train=0 th train_random_zs.lua 
-- usage cityscapes: DATA_ROOT=/data/efros/isola/cityscapes/data_for_GAN_AE/ which_direction=BtoA display_id=20 name=experiment_random_zs_cityscapes_anno2photo continue_train=0 th train_random_zs_even_deeper.lua 
-- usage BSDS: DATA_ROOT=/data/efros/isola/BSDS/data_for_GAN_AE/ which_direction=AtoB display_id=20 name=experiment_random_zs_BSDS_anno2photo continue_train=0 niter=250 th train_random_zs_even_deeper.lua 

require 'torch'
require 'nn'
require 'optim'
require 'ConcatNoise'
util = paths.dofile('util.lua')
require 'image'
require 'models'


opt = {
   DATA_ROOT = '',         -- path to images (should have subfolders 'train', 'val', etc)
   batchSize = 1,          -- # images in batch
   loadSize = 286,         -- scale images to this size
   fineSize = 256,         --  then crop to this size
   nz = 4000,              -- #  of dim for Z
   ngf = 64,               -- #  of gen filters in first conv layer
   ndf = 64,               -- #  of discrim filters in first conv layer
   input_nc = 3,           -- #  of input image channels
   output_nc = 3,          -- #  of output image channels
   niter = 50,             -- #  of iter at starting learning rate
   lr = 0.0002,            -- initial learning rate for adam
   beta1 = 0.5,            -- momentum term of adam
   ntrain = math.huge,     -- #  of examples per epoch. math.huge for full dataset
   flip = 1,               -- if flip the images for data argumentation
   display = 1,            -- display samples while training. 0 = false
   display_id = 10,        -- display window id.
   gpu = 1,                -- gpu = 0 is CPU mode. gpu=X is GPU mode on GPU X
   name = '',
   which_direction = 'AtoB',
   phase = 'train',
   preprocess = 'regular',
   --preload_data = true,
   nThreads = 2,           -- threads for loading data
   save_freq = 50,         -- save a model every save_freq epochs
   latest_freq = 5,        -- save the latest model every latest_freq epochs
   save_iters = 5000,           -- save the latest model every save_iters iterations 
   print_freq = 50,        -- print the debug information every print_freq iterations
   display_freq = 100,      -- display the current results every display_freq iterations
   save_display_freq = 5000, -- save the current display of results every save_display_freq_iterations
   continue_train=1,  -- if continue training, load the latest model: 1: true, 0: false
   serial_batches = 0,        -- if 1, takes images in order to make batches, otherwise takes them randomly
   serial_batch_iter = 1,     -- iter into serial image list
   checkpoints_dir = '/data/efros/isola/pix2pix/checkpoints',
   cudnn = 1, -- set to 0 to not use cudnn
   condition_GAN = 1, -- set to 0 to use unconditional GAN
   use_GAN = 1, -- set to 0 to turn off GAN term
   use_L1 = 1, -- set to 0 to turn off L1 term
   use_content = 0, -- set to 0 to turn off content loss
   which_model_netD = 'basic_v1',
   which_model_netG = 'unet',
   n_layers_D = 0, -- only used if which_model_netD=='n_layers'
}

-- one-line argument parser. parses enviroment variables to override the defaults
for k,v in pairs(opt) do opt[k] = tonumber(os.getenv(k)) or os.getenv(k) or opt[k] end
print(opt)

local input_nc = opt.input_nc
local output_nc = opt.output_nc
-- translation direction
local idx_A = nil
local idx_B = nil

if opt.which_direction=='AtoB' then
	idx_A = {1, input_nc}
	idx_B = {input_nc+1, input_nc+output_nc}
elseif opt.which_direction=='BtoA' then
	idx_A = {input_nc+1, input_nc+output_nc}
	idx_B = {1, input_nc}
else
	error(string.format('bad direction %s',opt.which_direction))
end

if opt.display == 0 then opt.display = false end

opt.manualSeed = torch.random(1, 10000) -- fix seed
print("Random Seed: " .. opt.manualSeed)
torch.manualSeed(opt.manualSeed)
torch.setdefaulttensortype('torch.FloatTensor')

-- create data loader
local data_loader = paths.dofile('data/data.lua')
print('#threads...' .. opt.nThreads)
local data = data_loader.new(opt.nThreads, opt)
print("Dataset Size: ", data:size())
tmp_d, tmp_paths = data:getBatch()

----------------------------------------------------------------------------
local function weights_init(m)
   local name = torch.type(m)
   if name:find('Convolution') then
      m.weight:normal(0.0, 0.02)
      m.bias:fill(0)
   elseif name:find('BatchNormalization') then
      if m.weight then m.weight:normal(1.0, 0.02) end
      if m.bias then m.bias:fill(0) end
   end
end

local nz = opt.nz
local ndf = opt.ndf
local ngf = opt.ngf
local real_label = 1
local fake_label = 0

function defineG(input_nc, output_nc, ngf, nz)
   
	if     opt.which_model_netG == "encoder_decoder" then netG = defineG_encoder_decoder(input_nc, output_nc, ngf, nz, 3)
	elseif opt.which_model_netG == "unet" then netG = defineG_unet(input_nc, output_nc, ngf)
	elseif opt.which_model_netG == "unet2" then netG = defineG_unet2(input_nc, output_nc, ngf)
	elseif opt.which_model_netG == "unet_upsample" then netG = defineG_unet_upsample(input_nc, output_nc, ngf)
	else error("unsupported netG model")
	end
   
   netG:apply(weights_init)
   
   return netG
end

function defineD(input_nc, output_nc, ndf)

	local netD = nil
	if opt.condition_GAN==1 then
		input_nc_tmp = input_nc
	else
		input_nc_tmp = 0 -- only penalizes structure in output channels
	end
	
	if     opt.which_model_netD == "basic" then netD = defineD_basic(input_nc_tmp, output_nc, ndf)
	elseif opt.which_model_netD == "basic_v1" then netD = defineD_basic_v1(input_nc_tmp, output_nc, ndf)
	elseif opt.which_model_netD == "n_layers" then netD = defineD_n_layers(input_nc_tmp, output_nc, ndf, opt.n_layers_D)
	elseif opt.which_model_netD == "basic_dilated" then netD = defineD_basic_dilated(input_nc_tmp, output_nc, ndf)
	elseif opt.which_model_netD == "unet" then netD = defineD_unet(input_nc_tmp, output_nc, ndf)
	else error("unsupported netD model")
	end
	
	netD:apply(weights_init)
	
	return netD
end


-- load saved models and finetune
if opt.continue_train == 1 then
   print('loading previously trained netG...')
   netG = util.load(paths.concat(opt.checkpoints_dir, opt.name, 'latest_net_G.t7'), opt)
   print('loading previously trained netD...')
   netD = util.load(paths.concat(opt.checkpoints_dir, opt.name, 'latest_net_D.t7'), opt)
else
  print('define model netG...')
  netG = defineG(input_nc, output_nc, ngf, nz)
  print('define model netD...')
  netD = defineD(input_nc, output_nc, ndf)
end

print(netG)
print(netD)
local content_layer = 'relu4_2'
local feature_extractor = nn.Sequential()
if opt.use_content == 1 then
  require 'loadcaffe'
  require 'VGG_preprocess'
  cnn = loadcaffe.load('../models/vgg.prototxt', '../models/vgg.caffemodel', 'cudnn')
--  local feature_extractor = nn.Sequential()
  
  feature_extractor:add(nn.SpatialUpSamplingBilinear({oheight=224, owidth=224}))
  feature_extractor:add(nn.VGG_postprocess())
  
  for i = 1, #cnn do
    local layer = cnn:get(i):clone()
    local name = layer.name
    local layer_type = torch.type(layer)
    feature_extractor:add(layer)
    if name == content_layer then
      print("Setting up content layer: ", layer.name)
      break
    end
  end
  cnn = nil
  collectgarbage()
  print(feature_extractor)
--  os.exit()
end


local criterionContent = nn.AbsCriterion()
local criterion = nn.BCECriterion()
local criterionAE = nn.AbsCriterion()
---------------------------------------------------------------------------
optimStateG = {
   learningRate = opt.lr,
   beta1 = opt.beta1,
}
optimStateD = {
   learningRate = opt.lr,
   beta1 = opt.beta1,
}


    
----------------------------------------------------------------------------
local real_A = torch.Tensor(opt.batchSize, input_nc, opt.fineSize, opt.fineSize)
local real_B = torch.Tensor(opt.batchSize, output_nc, opt.fineSize, opt.fineSize)
local fake_B = torch.Tensor(opt.batchSize, output_nc, opt.fineSize, opt.fineSize)
local real_AB = torch.Tensor(opt.batchSize, output_nc + input_nc*opt.condition_GAN, opt.fineSize, opt.fineSize)
local fake_AB = torch.Tensor(opt.batchSize, output_nc + input_nc*opt.condition_GAN, opt.fineSize, opt.fineSize)
local errD, errG, errAE, errContent = 0, 0, 0, 0
local epoch_tm = torch.Timer()
local tm = torch.Timer()
local data_tm = torch.Timer()
----------------------------------------------------------------------------

if opt.gpu > 0 then
   print('transferring to gpu...')
   require 'cunn'
   cutorch.setDevice(opt.gpu)
   real_A = real_A:cuda();
   real_B = real_B:cuda(); fake_B = fake_B:cuda();
   real_AB = real_AB:cuda(); fake_AB = fake_AB:cuda();
   if opt.cudnn==1 then
      netG = util.cudnn(netG); netD = util.cudnn(netD);
      feature_extractor = util.cudnn(feature_extractor)
   end
   netD:cuda(); netG:cuda(); criterion:cuda(); criterionAE:cuda();
   criterionContent:cuda()
   feature_extractor:cuda() 
   print('done')
end


local parametersD, gradParametersD = netD:getParameters()
local parametersG, gradParametersG = netG:getParameters()



if opt.display then disp = require 'display' end


function createRealFake()
    -- load real
	data_tm:reset(); data_tm:resume()
	local real_data, data_path = data:getBatch()
	--print(real_data:size())
	--print(data_path)
	data_tm:stop()
--	if which_dirA
--  print('check data format .......')
--  print(idx_A)
--  print(idx_B)
--  print(real_data:size())
--  os.exit()
	real_A:copy(real_data[{ {}, idx_A, {}, {} }])
    real_B:copy(real_data[{ {}, idx_B, {}, {} }])
--  print(real_A:size())
--  print(real_A:min(), real_A:max())
--  print(real_B:size())
--  print(real_B:min(), real_B:max())
  if opt.condition_GAN==1 then
   real_AB = torch.cat(real_A,real_B,2)
  else
   real_AB = real_B -- unconditional GAN, only penalizes structure in B
  end
	
	-- create fake
    fake_B = netG:forward(real_A)
    
--    print(real_AB:size())
--	  print(fake_B:size())
    if opt.condition_GAN==1 then
 	   fake_AB = torch.cat(real_A,fake_B,2)
    else
 	   fake_AB = fake_B -- unconditional GAN, only penalizes structure in B
    end
    local predict_real = netD:forward(real_AB)
    local predict_fake = netD:forward(fake_AB)
--    print('predict_real', predict_real)
--    print('predict_fake', predict_fake)
--    print(fake_AB:size())
--  os.exit()
end

-- create closure to evaluate f(X) and df/dX of discriminator
local fDx = function(x)
--   print('enter fdX')
   netD:apply(function(m) if torch.type(m):find('Convolution') then m.bias:zero() end end)
   netG:apply(function(m) if torch.type(m):find('Convolution') then m.bias:zero() end end)
   
   gradParametersD:zero()
   
   -- Real
   local output = netD:forward(real_AB)
   local label = torch.FloatTensor(output:size()):fill(real_label):cuda()
   local errD_real = criterion:forward(output, label)
   local df_do = criterion:backward(output, label)
   netD:backward(real_AB, df_do)
   
   -- Fake
   local output = netD:forward(fake_AB)
   label:fill(fake_label)
   local errD_fake = criterion:forward(output, label)
   local df_do = criterion:backward(output, label)
   netD:backward(fake_AB, df_do)
   
   errD = (errD_real + errD_fake)/2
   
   return errD, gradParametersD
end

-- create closure to evaluate f(X) and df/dX of generator
local fGx = function(x)
   netD:apply(function(m) if torch.type(m):find('Convolution') then m.bias:zero() end end)
   netG:apply(function(m) if torch.type(m):find('Convolution') then m.bias:zero() end end)

   gradParametersG:zero()
   
   -- GAN loss
   local df_dg = torch.zeros(fake_B:size()):cuda()
   if opt.use_GAN==1 then
      local output = netD.output -- netD:forward{input_A,input_B} was already executed in fDx, so save computation
      local label = torch.FloatTensor(output:size()):fill(real_label):cuda() -- fake labels are real for generator cost
      errG = criterion:forward(output, label)
      local df_do = criterion:backward(output, label)
      df_dg = netD:updateGradInput(fake_AB, df_do):narrow(2,fake_AB:size(2)-output_nc+1, output_nc)
   else
	   errG = 0--torch.zeros(1)
	   
   end

   -- unary loss
   local df_do_AE = torch.zeros(fake_B:size()):cuda()
   if opt.use_L1==1 then
      errAE = criterionAE:forward(fake_B, real_B)
      df_do_AE = criterionAE:backward(fake_B, real_B)
   else
      errAE = 0--torch.zeros(1)
   end
   
   local df_do_content_features = torch.zeros(fake_B:size()):cuda()
   if opt.use_content == 1 then 
--	   print('feature_extractor')
--	   print(feature_extractor)
	   local f_fake = feature_extractor:forward(fake_B):clone():mul(1.0)
	   local f_real = feature_extractor:forward(real_A):clone():mul(1.0)
--	   print('f_fake_range', f_fake:min(), f_fake:mean(), f_fake:max())
--	   print('f_real_range', f_real:min(), f_real:mean(), f_real:max())
	   errContent = criterionContent:forward(f_fake,f_real)  
--	   print(errContent)
	   local df_do_Content = criterionContent:backward(f_fake,f_real)
	   df_do_content_features = feature_extractor:updateGradInput(fake_B, df_do_Content)
	else
	   errContent = 0--torch.zeros(1)
	end
--	print(real_A:size())
--	print(df_dg:size())
--	print(df_do_AE:size())
--	print(df_do_content_features:size())
	netG:backward(real_A, df_dg + df_do_AE:mul(100) + df_do_content_features:mul(1))-- + df_do_content_features:mul(1))
--  netG:backward(real_A, df_dg + df_do_content_features:mul(1))
  return errG, gradParametersG
end




-- train
local best_err = nil
paths.mkdir(opt.checkpoints_dir)
paths.mkdir(opt.checkpoints_dir .. '/' .. opt.name)

-- save opt
file = torch.DiskFile(paths.concat(opt.checkpoints_dir, opt.name, 'opt.txt'), 'w')
file:writeObject(opt)
file:close()

local counter = 0
for epoch = 1, opt.niter do
   epoch_tm:reset()
   --local counter = 0
   for i = 1, math.min(data:size(), opt.ntrain), opt.batchSize do
      tm:reset()
	  
	  
	  -- load a batch and run G on that batch
	  createRealFake()
	  
      -- (1) Update D network: maximize log(D(x)) + log(1 - D(G(z)))
	  if opt.use_GAN==1 then optim.adam(fDx, parametersD, optimStateD) end
	  
      -- (2) Update G network: maximize log(D(G(z)))
--      print('adam solver')
-- bad argument #2 to '?' (number expected, got userdata)
      optim.adam(fGx, parametersG, optimStateG)
--	    os.exit()
	  
      -- display
      counter = counter + 1
      if counter % opt.display_freq == 0 and opt.display then
		createRealFake()
		if opt.preprocess == 'colorization' then 
			local real_A_s = util.scaleBatch(real_A:float(),100,100)
			local fake_B_s = util.scaleBatch(fake_B:float(),100,100)
			local real_B_s = util.scaleBatch(real_B:float(),100,100)
			disp.image(util.deprocessL_batch(real_A_s), {win=opt.display_id, title=opt.name .. ' input', normalize=false})
			disp.image(util.deprocessLAB_batch(real_A_s, fake_B_s), {win=opt.display_id+1, title=opt.name .. ' output', normalize=false})
			disp.image(util.deprocessLAB_batch(real_A_s, real_B_s), {win=opt.display_id+2, title=opt.name .. ' target', normalize=false})
		else
			disp.image(util.deprocess_batch(util.scaleBatch(real_A:float(),100,100)), {win=opt.display_id, title=opt.name .. ' input', normalize=false})
			disp.image(util.deprocess_batch(util.scaleBatch(fake_B:float(),100,100)), {win=opt.display_id+1, title=opt.name .. ' output', normalize=false})
			disp.image(util.deprocess_batch(util.scaleBatch(real_B:float(),100,100)), {win=opt.display_id+2, title=opt.name .. ' target', normalize=false})
		end
      end
	  
	  -- write display visualization to disk
	  --  runs on the first batchSize images in the val set
	  if counter % opt.save_display_freq == 0 and opt.display then
	
		  --local phase=opt.phase
		  local serial_batches=opt.serial_batches
		  --opt.phase='val'
		  opt.serial_batches=1
		  opt.serial_batch_iter=1
		  
		  local image_out = nil
		  local N_save_display = 10
		  for i3=1, torch.floor(N_save_display/opt.batchSize) do
		 
			 createRealFake()
			 print('save to the disk')
			    if opt.preprocess == 'colorization' then 
			      for i2=1, fake_B:size(1) do
              if image_out==nil then image_out = torch.cat(util.deprocessL(real_A[i2]:float()),util.deprocessLAB(real_A[i2]:float(), fake_B[i2]:float()),3)/255.0
            else image_out = torch.cat(image_out, torch.cat(util.deprocessL(real_A[i2]:float()),util.deprocessLAB(real_A[i2]:float(), fake_B[i2]:float()),3)/255.0, 2) end
         end
         
     else
		     for i2=1, fake_B:size(1) do
		      	  if image_out==nil then image_out = torch.cat(util.deprocess(real_A[i2]:float()),util.deprocess(fake_B[i2]:float()),3)
		     	  else image_out = torch.cat(image_out, torch.cat(util.deprocess(real_A[i2]:float()),util.deprocess(fake_B[i2]:float()),3), 2) end
		     end
		  end
		  end
		  image.save(paths.concat(opt.checkpoints_dir,  opt.name , counter .. '_train_res.png'), image_out)
		  
		  opt.serial_batches=serial_batches
		  end
		  --opt.phase=phase
--	  end
	  
      -- logging
      if ((i-1) / opt.batchSize) % opt.print_freq == 0 then
         print(('Epoch: [%d][%8d / %8d]\t Time: %.3f  DataTime: %.3f  '
                   .. '  Err_G: %.4f  Err_D: %.4f  ErrL1: %.4f  ErrContent: %.4f'):format(
                 epoch, ((i-1) / opt.batchSize),
                 math.floor(math.min(data:size(), opt.ntrain) / opt.batchSize),
                 tm:time().real / opt.batchSize, data_tm:time().real / opt.batchSize,
                 errG and errG or -1, errD and errD or -1, errAE and errAE or -1, errContent and errContent or -1))
      end

   if counter % opt.save_iters == 0 then
     print(('save the latest model (epoch %d, iters %d)'):format(epoch, counter))
     torch.save(paths.concat(opt.checkpoints_dir, opt.name, 'latest_net_G.t7'), netG:clearState())
     torch.save(paths.concat(opt.checkpoints_dir, opt.name, 'latest_net_D.t7'), netD:clearState())
   end
   
   end
   
   
   parametersD, gradParametersD = nil, nil -- nil them to avoid spiking memory
   parametersG, gradParametersG = nil, nil
   
   
   if epoch % opt.save_freq == 0 then
      torch.save(paths.concat(opt.checkpoints_dir, opt.name,  epoch .. '_net_G.t7'), netG:clearState())
      torch.save(paths.concat(opt.checkpoints_dir, opt.name, epoch .. '_net_D.t7'), netD:clearState())
   end
   
   -- cache latest modeld
   if epoch % opt.latest_freq == 0 then
     print(('save the latest model (epoch %d, iters %d)'):format(epoch, counter))
     torch.save(paths.concat(opt.checkpoints_dir, opt.name, 'latest_net_G.t7'), netG:clearState())
     torch.save(paths.concat(opt.checkpoints_dir, opt.name, 'latest_net_D.t7'), netD:clearState())
   end
   
   print(('End of epoch %d / %d \t Time Taken: %.3f'):format(
            epoch, opt.niter, epoch_tm:time().real))
   parametersD, gradParametersD = netD:getParameters() -- reflatten the params and get them
   parametersG, gradParametersG = netG:getParameters()
end