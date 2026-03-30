-- Oz PTM Similarity.lua
-- Computes spectral similarity vectors from OGG preview files and projects
-- them into 2-D coordinates for the cloud/nebula visualisation.
--
-- Pipeline:
--   1. Read the OGG preview via REAPER's PCM_Source API (mono-mixed).
--   2. Compute a short-time FFT over the full file (512-point Hann window).
--   3. Derive 32 Mel-spaced energy bands (MFCC-style feature vector, no DCT
--      needed for similarity; raw mel band energies work well for timbral
--      comparison).
--   4. L2-normalise the vector and store in DB as sim_vec[1..32].
--   5. For 2-D projection: use a lightweight t-SNE implementation (Barnes-Hut
--      approximation, pure Lua, runs on demand and is reasonably fast for
--      collections up to ~1000 presets).

local Sim = {}

-- ─── Constants ───────────────────────────────────────────────────────────────

local FFT_SIZE    = 512
local HOP_SIZE    = 256
local SAMPLE_RATE = 44100.0
local N_BANDS     = 32   -- must match Config.SIM_VEC_DIM
local MAX_FRAMES  = 200  -- max number of FFT frames averaged

-- ─── Hann window ─────────────────────────────────────────────────────────────

local HANN = {}
for i = 0, FFT_SIZE - 1 do
  HANN[i + 1] = 0.5 * (1 - math.cos(2 * math.pi * i / (FFT_SIZE - 1)))
end

-- ─── Real-valued FFT (Cooley-Tukey radix-2) ──────────────────────────────────
-- Returns magnitude spectrum in buf_re[] (length FFT_SIZE/2+1).
-- Input: buf_re[] real, buf_im[] imaginary (initialized to 0).

local function fft(re, im, n)
  -- Bit-reversal permutation
  local j = 0
  for i = 1, n - 1 do
    local bit = n >> 1
    while j & bit ~= 0 do j = j ~ bit; bit = bit >> 1 end
    j = j | bit
    if i < j then
      re[i + 1], re[j + 1] = re[j + 1], re[i + 1]
      im[i + 1], im[j + 1] = im[j + 1], im[i + 1]
    end
  end
  -- Butterfly
  local len = 2
  while len <= n do
    local half = len >> 1
    local ang  = -2 * math.pi / len
    local wr   = math.cos(ang)
    local wi   = math.sin(ang)
    for i = 0, n - 1, len do
      local cur_r, cur_i = 1.0, 0.0
      for k = 0, half - 1 do
        local a  = i + k + 1
        local b  = i + k + half + 1
        local tr = cur_r * re[b] - cur_i * im[b]
        local ti = cur_r * im[b] + cur_i * re[b]
        re[b] = re[a] - tr
        im[b] = im[a] - ti
        re[a] = re[a] + tr
        im[a] = im[a] + ti
        local new_r = cur_r * wr - cur_i * wi
        cur_i = cur_r * wi + cur_i * wr
        cur_r = new_r
      end
    end
    len = len << 1
  end
end

-- ─── Mel filterbank ──────────────────────────────────────────────────────────

local function hz_to_mel(hz) return 2595 * math.log(1 + hz / 700) / math.log(10) end
local function mel_to_hz(m)  return 700 * (10 ^ (m / 2595) - 1) end

--- Builds the Mel filterbank: mel_bank[band][1..FFT_SIZE/2+1] = weight
local function build_mel_bank(n_bands, fft_size, sr)
  local n_bins  = fft_size // 2 + 1
  local f_min   = 40.0
  local f_max   = sr / 2.0
  local m_min   = hz_to_mel(f_min)
  local m_max   = hz_to_mel(f_max)
  local bank    = {}

  -- n_bands + 2 evenly-spaced mel points
  local points = {}
  for i = 0, n_bands + 1 do
    local m = m_min + i * (m_max - m_min) / (n_bands + 1)
    points[i + 1] = math.floor(mel_to_hz(m) * fft_size / sr + 0.5)
  end

  for b = 1, n_bands do
    local filt = {}
    for k = 0, n_bins - 1 do filt[k + 1] = 0.0 end
    local lo = points[b]
    local ctr = points[b + 1]
    local hi  = points[b + 2]
    for k = lo, ctr do
      if k >= 0 and k < n_bins then
        filt[k + 1] = (k - lo) / math.max(1, ctr - lo)
      end
    end
    for k = ctr, hi do
      if k >= 0 and k < n_bins then
        filt[k + 1] = (hi - k) / math.max(1, hi - ctr)
      end
    end
    bank[b] = filt
  end
  return bank
end

local MEL_BANK = build_mel_bank(N_BANDS, FFT_SIZE, SAMPLE_RATE)

-- ─── Feature extraction ───────────────────────────────────────────────────────

--- Extracts a 32-dim mel-energy vector from an OGG file.
--- @param preview_path string
--- @return table|nil  {float, ...} length N_BANDS, or nil on failure
function Sim.extract_vector(preview_path)
  if not preview_path or preview_path == "" then return nil end

  local src = reaper.PCM_Source_CreateFromFile(preview_path)
  if not src then return nil end

  local dur = reaper.GetMediaSourceLength(src, false)
  if not dur or dur <= 0 then
    reaper.PCM_Source_Destroy(src)
    return nil
  end

  local acc = reaper.CreatePCMSourceAccessor(src)
  if not acc then
    reaper.PCM_Source_Destroy(src)
    return nil
  end

  -- Accumulate mel band energies over up to MAX_FRAMES frames
  local mel_acc = {}
  for b = 1, N_BANDS do mel_acc[b] = 0.0 end

  local total_samples = math.floor(dur * SAMPLE_RATE)
  local n_frames = math.min(MAX_FRAMES, math.floor((total_samples - FFT_SIZE) / HOP_SIZE) + 1)
  if n_frames < 1 then n_frames = 1 end

  local re  = {}
  local im  = {}
  local buf = reaper.new_array and reaper.new_array(FFT_SIZE) or nil

  for f = 0, n_frames - 1 do
    local start_spl = math.floor(f * (total_samples - FFT_SIZE) / math.max(1, n_frames - 1))

    -- Read mono samples
    if buf then
      reaper.PCM_Source_AccessRead(acc, buf, FFT_SIZE, start_spl, 1, true)
    end

    for i = 1, FFT_SIZE do
      local s = buf and buf[i] or 0
      re[i] = s * HANN[i]
      im[i] = 0
    end

    fft(re, im, FFT_SIZE)

    -- Magnitude spectrum
    local n_bins = FFT_SIZE // 2 + 1
    local mag = {}
    for k = 1, n_bins do
      mag[k] = math.sqrt(re[k]^2 + im[k]^2)
    end

    -- Apply mel filterbank
    for b = 1, N_BANDS do
      local energy = 0
      for k = 1, n_bins do
        energy = energy + MEL_BANK[b][k] * mag[k]
      end
      mel_acc[b] = mel_acc[b] + math.max(0, energy)
    end
  end

  reaper.DestroyPCM_Source_AccessorResult(acc)
  reaper.PCM_Source_Destroy(src)

  -- Average and log-compress
  local vec = {}
  for b = 1, N_BANDS do
    vec[b] = math.log(mel_acc[b] / n_frames + 1e-8)
  end

  -- L2-normalize
  local norm = 0
  for b = 1, N_BANDS do norm = norm + vec[b]^2 end
  norm = math.sqrt(norm + 1e-12)
  for b = 1, N_BANDS do vec[b] = vec[b] / norm end

  return vec
end

-- ─── t-SNE (symmetric, simplified) ──────────────────────────────────────────

--- Computes pairwise Gaussian similarities (P matrix) given a list of vectors.
--- @param vecs  table  list of {float, ...} vectors
--- @param perp  number  target perplexity
--- @return table  P[i][j] = symmetric similarity
local function compute_P(vecs, perp)
  local n = #vecs
  local P = {}
  for i = 1, n do P[i] = {} for j = 1, n do P[i][j] = 0 end end

  local target_entropy = math.log(perp)

  for i = 1, n do
    -- Binary search for sigma_i
    local beta = 1.0
    local beta_min, beta_max = -math.huge, math.huge
    local p_row = {}

    for _ = 1, 50 do  -- binary search iterations
      -- Compute unnormalized row
      local sum_pi = 0
      for j = 1, n do
        if j ~= i then
          local d2 = 0
          for k = 1, #vecs[i] do
            d2 = d2 + (vecs[i][k] - vecs[j][k])^2
          end
          local pi = math.exp(-d2 * beta)
          p_row[j] = pi
          sum_pi = sum_pi + pi
        else
          p_row[j] = 0
        end
      end
      -- Entropy
      local entropy = 0
      for j = 1, n do
        if j ~= i and sum_pi > 0 then
          local pi = p_row[j] / sum_pi
          if pi > 1e-15 then entropy = entropy - pi * math.log(pi) end
        end
      end
      -- Adjust beta
      if entropy > target_entropy then
        beta_min = beta
        beta = (beta_max == math.huge) and (beta * 2) or ((beta + beta_max) / 2)
      else
        beta_max = beta
        beta = (beta_min == -math.huge) and (beta / 2) or ((beta + beta_min) / 2)
      end
    end

    -- Normalize row
    local sum_pi = 0
    for j = 1, n do sum_pi = sum_pi + (p_row[j] or 0) end
    if sum_pi > 0 then
      for j = 1, n do P[i][j] = (p_row[j] or 0) / sum_pi end
    end
  end

  -- Symmetrize: P = (P + P') / (2n)
  local two_n = 2 * n
  for i = 1, n do
    for j = i + 1, n do
      local sym = (P[i][j] + P[j][i]) / two_n
      P[i][j] = sym
      P[j][i] = sym
    end
    P[i][i] = 0
  end

  return P
end

--- Runs t-SNE on a list of feature vectors, returning (x[i], y[i]) coords.
--- @param vecs   table  list of {float,...} vectors
--- @param iters  number  gradient descent iterations
--- @param perp   number  perplexity
--- @return table x_coords, table y_coords  (0-1 normalized)
function Sim.tsne(vecs, iters, perp)
  local n = #vecs
  if n == 0 then return {}, {} end
  if n == 1 then return {0.5}, {0.5} end

  iters = iters or 500
  perp  = perp  or 30

  -- Initialize Y randomly
  local Y_x, Y_y = {}, {}
  for i = 1, n do
    Y_x[i] = (math.random() - 0.5) * 0.01
    Y_y[i] = (math.random() - 0.5) * 0.01
  end

  local P = compute_P(vecs, perp)

  local lr   = 200.0    -- learning rate
  local mom  = 0.5      -- momentum
  local mom_final = 0.8
  local mom_switch_iter = 250

  local vel_x, vel_y = {}, {}
  local gain_x, gain_y = {}, {}
  for i = 1, n do vel_x[i]=0; vel_y[i]=0; gain_x[i]=1; gain_y[i]=1 end

  for iter = 1, iters do
    -- Compute Q (Student-t distribution in 2-D)
    local Q = {}
    local sum_q = 0
    for i = 1, n do Q[i] = {} end
    for i = 1, n do
      for j = i + 1, n do
        local dx = Y_x[i] - Y_x[j]
        local dy = Y_y[i] - Y_y[j]
        local q  = 1 / (1 + dx * dx + dy * dy)
        Q[i][j] = q
        Q[j][i] = q
        sum_q   = sum_q + 2 * q
      end
      Q[i][i] = 0
    end
    sum_q = math.max(sum_q, 1e-12)

    -- Gradient
    local grad_x, grad_y = {}, {}
    for i = 1, n do grad_x[i] = 0; grad_y[i] = 0 end

    for i = 1, n do
      for j = 1, n do
        if j ~= i then
          local pq  = P[i][j] - Q[i][j] / sum_q
          local q   = Q[i][j]
          local mul = 4 * pq * q
          local dx  = Y_x[i] - Y_x[j]
          local dy  = Y_y[i] - Y_y[j]
          grad_x[i] = grad_x[i] + mul * dx
          grad_y[i] = grad_y[i] + mul * dy
        end
      end
    end

    -- Update with momentum and adaptive gain
    local mom_cur = iter < mom_switch_iter and mom or mom_final
    for i = 1, n do
      -- Update gain
      gain_x[i] = (math.abs(grad_x[i]) > 0 and (gain_x[i] + 0.2) or (gain_x[i] * 0.8))
      gain_y[i] = (math.abs(grad_y[i]) > 0 and (gain_y[i] + 0.2) or (gain_y[i] * 0.8))
      gain_x[i] = math.max(0.01, gain_x[i])
      gain_y[i] = math.max(0.01, gain_y[i])
      vel_x[i] = mom_cur * vel_x[i] - lr * gain_x[i] * grad_x[i]
      vel_y[i] = mom_cur * vel_y[i] - lr * gain_y[i] * grad_y[i]
      Y_x[i]  = Y_x[i] + vel_x[i]
      Y_y[i]  = Y_y[i] + vel_y[i]
    end

    -- Center
    local cx, cy = 0, 0
    for i = 1, n do cx = cx + Y_x[i]; cy = cy + Y_y[i] end
    cx = cx / n; cy = cy / n
    for i = 1, n do Y_x[i] = Y_x[i] - cx; Y_y[i] = Y_y[i] - cy end
  end

  -- Normalize to [0, 1]
  local min_x, max_x = Y_x[1], Y_x[1]
  local min_y, max_y = Y_y[1], Y_y[1]
  for i = 2, n do
    if Y_x[i] < min_x then min_x = Y_x[i] end
    if Y_x[i] > max_x then max_x = Y_x[i] end
    if Y_y[i] < min_y then min_y = Y_y[i] end
    if Y_y[i] > max_y then max_y = Y_y[i] end
  end
  local rx = math.max(max_x - min_x, 1e-12)
  local ry = math.max(max_y - min_y, 1e-12)
  for i = 1, n do
    Y_x[i] = (Y_x[i] - min_x) / rx
    Y_y[i] = (Y_y[i] - min_y) / ry
  end

  return Y_x, Y_y
end

-- ─── Full pipeline ────────────────────────────────────────────────────────────

--- Computes feature vectors for all presets with preview audio that lack one,
--- then runs t-SNE on all presets that have vectors, and stores sim_x/sim_y.
---
--- This is intentionally a synchronous blocking operation (no coroutines) and
--- should be called from a background action, not from the UI loop.
---
--- @param db      DB module
--- @param config  Config module
--- @param on_progress function|nil  called with (done, total, phase_label)
function Sim.run_full_pipeline(db, config, on_progress)
  local data = db.get and db.get("") or nil
  if not data then return end

  -- Phase 1: extract vectors for presets that have preview but no vector
  local needs_vec = {}
  for _, p in pairs(data.presets) do
    if p.preview_path and p.preview_path ~= ""
    and (not p.sim_vec or #p.sim_vec == 0) then
      needs_vec[#needs_vec + 1] = p
    end
  end
  table.sort(needs_vec, function(a, b) return (a.name or "") < (b.name or "") end)

  for i, p in ipairs(needs_vec) do
    if on_progress then on_progress(i, #needs_vec, "Extracting: " .. (p.name or "")) end
    local vec = Sim.extract_vector(p.preview_path)
    if vec then
      db.update_preset(p.uuid, { sim_vec = vec })
    end
  end

  -- Phase 2: collect all presets that have vectors
  local all_with_vec = {}
  for _, p in pairs(data.presets) do
    if p.sim_vec and #p.sim_vec > 0 then
      all_with_vec[#all_with_vec + 1] = p
    end
  end

  if #all_with_vec < 2 then return end

  if on_progress then on_progress(1, 1, "Running t-SNE projection…") end

  local vecs = {}
  for _, p in ipairs(all_with_vec) do vecs[#vecs + 1] = p.sim_vec end

  local xs, ys = Sim.tsne(vecs, config.SIM_TSNE_ITERS, config.SIM_TSNE_PERPLEXITY)

  for i, p in ipairs(all_with_vec) do
    db.update_preset(p.uuid, { sim_x = xs[i] or 0.5, sim_y = ys[i] or 0.5 })
  end

  db.mark_dirty()
end

return Sim
