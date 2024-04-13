local api = vim.api
local fn = vim.fn

local M = {}
local opts = {}

local old_cur = nil
local au_group = nil

function M.on_cursor_moved()
  local cur = fn.winline() + api.nvim_win_get_position(0)[1]
  if old_cur then
    local jump = math.abs(cur - old_cur)
    if jump >= opts.min_jump then
      M.show_specs()
    end
  end
  old_cur = cur
end

function M.should_show_specs(start_win_id)
  if not api.nvim_win_is_valid(start_win_id) then
    return false
  end

  if fn.getcmdpos() ~= 0 then
    return false
  end

  if
    type(opts.ignore_filetypes) ~= 'table'
    or type(opts.ignore_buftypes) ~= 'table'
  then
    return true
  end

  local buftype, filetype, ok
  ok, buftype = pcall(api.nvim_get_option_value, 'buftype', { buf = 0 })

  if ok and opts.ignore_buftypes[buftype] then
    return false
  end

  ok, filetype = pcall(api.nvim_get_option_value, 'filetype', { buf = 0 })

  if ok and opts.ignore_filetypes[filetype] then
    return false
  end

  return true
end

function M.show_specs(popup)
  local start_win_id = api.nvim_get_current_win()

  if not M.should_show_specs(start_win_id) then
    return
  end

  if popup == nil then
    popup = {}
  end

  local _opts = vim.tbl_deep_extend('force', opts, { popup = popup })

  local cursor_col = fn.wincol() - 1
  local cursor_row = fn.winline() - 1
  local bufh = api.nvim_create_buf(false, true)
  local win_id = api.nvim_open_win(bufh, false, {
    relative = 'win',
    width = 1,
    height = 1,
    col = cursor_col,
    row = cursor_row,
    style = 'minimal',
  })
  api.nvim_set_option_value(
    'winhl',
    'Normal:' .. _opts.popup.winhl,
    { win = win_id }
  )
  api.nvim_set_option_value('winblend', _opts.popup.blend, { win = win_id })

  local cnt = 0
  local config = api.nvim_win_get_config(win_id)
  local timer = vim.uv.new_timer()
  local closed = false

  vim.uv.timer_start(
    timer,
    _opts.popup.delay_ms,
    _opts.popup.inc_ms,
    vim.schedule_wrap(function()
      if closed or api.nvim_get_current_win() ~= start_win_id then
        if not closed then
          pcall(vim.uv.close, timer)
          pcall(api.nvim_win_close, win_id, true)

          -- Callbacks might stack up before the timer actually gets closed, track that state
          -- internally here instead
          closed = true
        end

        return
      end

      if api.nvim_win_is_valid(win_id) then
        local bl = _opts.popup.fader(_opts.popup.blend, cnt)
        local dm = _opts.popup.resizer(_opts.popup.width, cursor_col, cnt)

        if bl ~= nil then
          api.nvim_set_option_value('winblend', bl, { win = win_id })
        end
        if dm ~= nil then
          config.col = dm[2]
          api.nvim_win_set_config(win_id, config)
          api.nvim_win_set_width(win_id, dm[1])
        end
        if bl == nil and dm == nil then -- Done blending and resizing
          vim.uv.close(timer)
          api.nvim_win_close(win_id, true)
        end
        cnt = cnt + 1
      end
    end)
  )
end

--[[ ▁▁▂▂▃▃▄▄▅▅▆▆▇▇██ ]]
--

function M.linear_fader(blend, cnt)
  if blend + cnt <= 100 then
    return cnt
  else
    return nil
  end
end

--[[ ⌣/⌢\⌣/⌢\⌣/⌢\⌣/⌢\ ]]
--

function M.sinus_fader(blend, cnt)
  if cnt <= 100 then
    return math.ceil((math.sin(cnt * (1 / blend)) * 0.5 + 0.5) * 100)
  else
    return nil
  end
end

--[[ ▁▁▁▁▂▂▂▃▃▃▄▄▅▆▇ ]]
--

function M.exp_fader(blend, cnt)
  if blend + math.floor(math.exp(cnt / 10)) <= 100 then
    return blend + math.floor(math.exp(cnt / 10))
  else
    return nil
  end
end

--[[ ▁▂▃▄▅▆▇█▇▆▅▄▃▂▁ ]]
--

function M.pulse_fader(blend, cnt)
  if cnt < (100 - blend) / 2 then
    return cnt
  elseif cnt < 100 - blend then
    return 100 - cnt
  else
    return nil
  end
end

--[[ ▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁ ]]
--

function M.empty_fader(_, _)
  return nil
end

--[[ ░░▒▒▓█████▓▒▒░░ ]]
--

function M.shrink_resizer(width, ccol, cnt)
  if width - cnt > 0 then
    return { width - cnt, ccol - (width - cnt) / 2 + 1 }
  else
    return nil
  end
end

--[[ ████▓▓▓▒▒▒▒░░░░ ]]
--

function M.slide_resizer(width, ccol, cnt)
  if width - cnt > 0 then
    return { width - cnt, ccol }
  else
    return nil
  end
end

--[[ ███████████████ ]]
--

function M.empty_resizer(width, ccol, cnt)
  if cnt < 100 then
    return { width, ccol - width / 2 }
  else
    return nil
  end
end

local DEFAULT_OPTS = {
  show_jumps = true,
  min_jump = 30,
  popup = {
    delay_ms = 10,
    inc_ms = 5,
    blend = 10,
    width = 20,
    winhl = 'Pmenu',
    fader = M.exp_fader,
    resizer = M.shrink_resizer,
  },
  ignore_filetypes = {},
  ignore_buftypes = {
    nofile = true,
  },
}

function M.setup(user_opts)
  opts = vim.tbl_deep_extend('force', DEFAULT_OPTS, user_opts)
  M.create_autocmds()
end

function M.toggle()
  if au_group then
    M.clear_autocmds()
  else
    M.create_autocmds()
  end
end

function M.create_autocmds()
  if not au_group then
    au_group = api.nvim_create_augroup('specs', {})
  end
  if opts.show_jumps then
    api.nvim_create_autocmd('CursorMoved', {
      group = au_group,
      callback = function()
        require('specs').on_cursor_moved()
      end,
    })
  end
end

function M.clear_autocmds()
  if au_group then
    api.nvim_del_augroup_by_id(au_group)
  end
  au_group = false
end

return M
