local Config = require('neo_glance.config')
local Winbar = require('neo_glance.ui.winbar')
local util = require('neo_glance.util')

local _g_util = require('_glance.utils')

---@class NeoGlanceUiPreview
---@field winid number
---@field bufnr number
---@field parent_bufnr number
---@field parent_winid number
---@field current_location NeoGlanceLocation|NeoGlanceLocationItem|nil
---@field winbar NeoGlanceUiWinbar
local Preview = {}
Preview.__index = Preview

local touched_buffers = {}

local winhl = {
  'Normal:GlancePreviewNormal',
  'CursorLine:GlancePreviewCursorLine',
  'SignColumn:GlancePreviewSignColumn',
  'EndOfBuffer:GlancePreviewEndOfBuffer',
  'LineNr:GlancePreviewLineNr',
}

-- Fails to set winhighlight in 0.7.2 for some reason
if vim.fn.has('nvim-0.8') == 1 then
  table.insert(winhl, 'GlanceNone:GlancePreviewMatch')
end

local border_style = nil
local winbar_enable = false
local win_opts = {
  winbar = nil,
  winfixwidth = true,
  winfixheight = true,
  cursorbind = false,
  scrollbind = false,
  winhighlight = table.concat(winhl, ','),
}

local float_win_opts = {
  'number',
  'relativenumber',
  'cursorline',
  'cursorcolumn',
  'foldcolumn',
  'spell',
  'list',
  'signcolumn',
  'colorcolumn',
  'fillchars',
  'winhighlight',
  'statuscolumn',
}

local function clear_hl(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, Config.namespace, 0, -1)
  end
end

---@param opts {config:NeoGlanceConfig}
---@return NeoGlanceUiPreview
function Preview:init(opts)
  self:configure(opts.config)

  local scope = {
    winid = nil,
    bufnr = nil,
    parent_winid = nil,
    parent_bufnr = nil,
    current_location = nil,
    winbar = nil,
  }

  return setmetatable(scope, self)
end

function Preview:get_popup_opts(opts)
  return util.merge({
    enter = false,
    focusable = true,
    border = {
      style = border_style,
    },
    win_options = win_opts,
  }, opts or {})
end

---@param opts {winid:number,bufnr:number,parent_bufnr:number,parent_winid:number}
---@return NeoGlanceUiPreview
function Preview:create(opts)
  opts = opts or {}
  local scope = {
    winid = opts.winid,
    bufnr = opts.bufnr,
    parent_winid = opts.parent_winid,
    parent_bufnr = opts.parent_bufnr,
    current_location = nil,
    winbar = nil,
  }

  if winbar_enable then
    scope.winbar = Winbar:new(opts.winid, {
      { name = 'filename', hl = 'GlanceWinBarFilename' },
      { name = 'filepath', hl = 'GlanceWinBarFilepath' },
    })
  end

  return setmetatable(scope, self)
end

---@param bufnr number
---@param keymaps table
function Preview:on_attach_buffer(bufnr, keymaps)
  if bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr) then
    local throttled_on_change, on_change_timer = _g_util.throttle_leading(function()
      local is_active_buffer = self.current_location and bufnr == self.current_location.bufnr
      local is_listed = vim.fn.buflisted(bufnr) == 1

      if is_active_buffer and not is_listed then
        vim.api.nvim_buf_set_option(bufnr, 'buflisted', true)
        vim.api.nvim_buf_set_option(bufnr, 'bufhidden', '')
      end
    end, 1000)

    local autocmd_id = vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
      group = 'NeoGlance',
      buffer = bufnr,
      callback = throttled_on_change,
    })

    self.clear_autocmd = function()
      pcall(vim.api.nvim_del_autocmd, autocmd_id)
      if on_change_timer then
        on_change_timer:close()
        on_change_timer = nil
      end
    end

    local keymap_opts = {
      buffer = bufnr,
      noremap = true,
      nowait = true,
      silent = true,
    }

    for key, action in pairs(keymaps) do
      vim.keymap.set('n', key, action, keymap_opts)
    end
  end
end

function Preview:on_detach_buffer(bufnr, keymaps)
  if type(self.clear_autocmd) == 'function' then
    self.clear_autocmd()
    self.clear_autocmd = nil
  end

  if bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr) then
    for lhs, _ in pairs(keymaps) do
      pcall(vim.api.nvim_buf_del_keymap, bufnr, 'n', lhs)
    end
  end
end

function Preview:restore_win_opts()
  for opt, _ in pairs(win_opts) do
    if not vim.tbl_contains(float_win_opts, opt) then
      local value = vim.api.nvim_win_get_option(self.parent_winid, opt)
      vim.api.nvim_win_set_option(self.winid, opt, value)
    end
  end

  for _, opt in ipairs(float_win_opts) do
    local value = vim.api.nvim_win_get_option(self.parent_winid, opt)
    vim.api.nvim_win_set_option(self.winid, opt, value)
  end
end

---@param item NeoGlanceLocation|NeoGlanceLocationItem|nil
---@param group_nodes NuiTree.Node[]
---@param initial? boolean
function Preview:update_buffer(item, group_nodes, initial)
  if not vim.api.nvim_win_is_valid(self.winid) then
    return
  end

  if not item or item.is_group or item.is_unreachable then
    return
  end

  if vim.deep_equal(self.current_location, item) then
    return
  end

  local current_bufnr = (self.current_location or {}).bufnr

  if current_bufnr ~= item.bufnr then
    local config = Config.get_config()

    self:on_detach_buffer(current_bufnr, config.mappings.preview)
    vim.api.nvim_win_set_buf(self.winid, item.bufnr)
    self:restore_win_opts()
    _g_util.win_set_options(self.winid, win_opts)

    if config.winbar.enable and self.winbar then
      local filename = vim.fn.fnamemodify(item.filename, ':t')
      local filepath = vim.fn.fnamemodify(item.filename, ':p:~:h')
      self.winbar:render({ filename = filename, filepath = filepath })
    end

    vim.api.nvim_buf_call(item.bufnr, function()
      if vim.api.nvim_buf_get_option(item.bufnr, 'filetype') == '' then
        vim.cmd('do BufRead')
      end
    end)

    self:on_attach_buffer(item.bufnr, config.mappings.preview)
  end

  vim.api.nvim_win_set_cursor(self.winid, { item.start_line + 1, item.start_col })

  vim.api.nvim_win_call(self.winid, function()
    vim.cmd('norm! zv')
    vim.cmd('norm! zz')
  end)

  self.current_location = item

  if type(group_nodes) == 'table' and not vim.tbl_contains(touched_buffers, item.bufnr) then
    for _, node in pairs(group_nodes) do
      self:hl_buf(node.data)
    end
    table.insert(touched_buffers, item.bufnr)
  end
end

function Preview:clear_hl()
  for _, bufnr in ipairs(touched_buffers) do
    clear_hl(bufnr)
  end
  touched_buffers = {}
end

function Preview:hl_buf(location)
  for row = location.start_line, location.end_line, 1 do
    local start_col = 0
    local end_col = -1

    if row == location.start_line then
      start_col = location.start_col
    end

    if row == location.end_line then
      end_col = location.end_col
    end

    local match_hl = vim.fn.has('nvim-0.8') == 1 and 'None' or 'PreviewMatch'

    vim.api.nvim_buf_add_highlight(location.bufnr, Config.namespace, Config.hl_ns .. match_hl, row, start_col, end_col)
  end
end

function Preview:close()
  local config = Config.get_config()
  self:on_detach_buffer((self.current_location or {}).bufnr, config.mappings.preview)
  -- self:restore_win_opts()

  if vim.api.nvim_win_is_valid(self.winid) then
    vim.api.nvim_win_close(self.winid, true)
  end

  for _, bufnr in ipairs(touched_buffers) do
    -- INFO: know more about this func
    if vim.api.nvim_buf_is_valid(bufnr) and vim.fn.buflisted(bufnr) ~= 1 then
      if vim.fn.has('nvim-0.9.2') == 1 and type(vim.lsp.inlay_hint) == 'function' then
        vim.lsp.inlay_hint(bufnr, false)
      end
      vim.api.nvim_buf_delete(bufnr, { force = true })
    else
      clear_hl(bufnr)
    end
  end

  touched_buffers = {}
end

---@param config NeoGlanceConfig
function Preview:configure(config)
  winbar_enable = config.winbar.enable
  win_opts = vim.tbl_extend('keep', win_opts, config.preview_win_opts or {})
  border_style = Config.get_popup_opts(config, 'GlancePreviewBorderBottom')

  if winbar_enable then
    win_opts.winbar = '...'
  end
end

return Preview
