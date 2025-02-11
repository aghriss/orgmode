local instance = {}
local utils = require('orgmode.utils')
local fs = require('orgmode.utils.fs')
local defaults = require('orgmode.config.defaults')
---@type table<string, OrgMapEntry>
local mappings = require('orgmode.config.mappings')

---@class OrgConfig:OrgDefaultConfig
---@field opts table
---@field todo_keywords table
local Config = {}

---@param opts? table
function Config:new(opts)
  local data = {
    opts = vim.tbl_deep_extend('force', defaults, opts or {}),
    todo_keywords = nil,
    ts_hl_enabled = nil,
  }
  setmetatable(data, self)
  return data
end

function Config:__index(key)
  if self.opts[key] then
    return self.opts[key]
  end
  return rawget(getmetatable(self), key)
end

---@param opts table
---@return OrgConfig
function Config:extend(opts)
  self.todo_keywords = nil
  opts = opts or {}
  self:_deprecation_notify(opts)
  if not self:_are_priorities_valid(opts) then
    opts.org_priority_highest = self.opts.org_priority_highest
    opts.org_priority_lowest = self.opts.org_priority_lowest
    opts.org_priority_default = self.opts.org_priority_default
  end
  self.opts = vim.tbl_deep_extend('force', self.opts, opts)
  if self.org_startup_indented then
    self.org_adapt_indentation = not self.org_indent_mode_turns_off_org_adapt_indentation
  end
  return self
end

function Config:_are_priorities_valid(opts)
  local high = opts.org_priority_highest
  local low = opts.org_priority_lowest
  local default = opts.org_priority_default

  if high or low or default then
    -- assert that all three options are set
    if not (high and low and default) then
      utils.echo_warning(
        'org_priority_highest, org_priority_lowest and org_priority_default can only be set together.'
          .. 'Falling back to default priorities'
      )
      return false
    end

    -- numbers
    if type(high) == 'number' and type(low) == 'number' and type(default) == 'number' then
      if high < 0 or low < 0 or default < 0 then
        utils.echo_warning(
          'org_priority_highest, org_priority_lowest and org_priority_default cannot be negative.'
            .. 'Falling back to default priorities'
        )
        return false
      end
      if high > low then
        utils.echo_warning(
          'org_priority_highest cannot be bigger than org_priority_lowest. Falling back to default priorities'
        )
        return false
      end
      if default < high or default > low then
        utils.echo_warning(
          'org_priority_default must be bigger than org_priority_highest and smaller than org_priority_lowest.'
            .. 'Falling back to default priorities'
        )
        return false
      end
    -- one-char strings
    elseif
      (type(high) == 'string' and #high == 1)
      and (type(low) == 'string' and #low == 1)
      and (type(default) == 'string' and #default == 1)
    then
      if not high:match('%a') or not low:match('%a') or not default:match('%a') then
        utils.echo_warning(
          'org_priority_highest, org_priority_lowest and org_priority_default must be letters.'
            .. 'Falling back to default priorities'
        )
        return false
      end

      high = string.byte(high)
      low = string.byte(low)
      default = string.byte(default)
      if high > low then
        utils.echo_warning(
          'org_priority_highest cannot be bigger than org_priority_lowest. Falling back to default priorities'
        )
        return false
      end
      if default < high or default > low then
        utils.echo_warning(
          'org_priority_default must be bigger than org_priority_highest and smaller than org_priority_lowest.'
            .. 'Falling back to default priorities'
        )
        return false
      end
    else
      utils.echo_warning(
        'org_priority_highest, org_priority_lowest and org_priority_default must be either of type'
          .. "'number' or of type 'string' of length one. All three options need to agree on this type."
          .. 'Falling back to default priorities'
      )
      return false
    end
  end

  return true
end

function Config:_deprecation_notify(opts)
  local messages = {}
  if
    opts.mappings
    and opts.mappings.org
    and (opts.mappings.org.org_increase_date or opts.mappings.org.org_decrease_date)
  then
    table.insert(
      messages,
      'org_increase_date/org_decrease_date mappings are deprecated in favor of org_timestamp_up/org_timestamp_down (More granular increase/decrease).'
    )
    table.insert(messages, 'See https://github.com/nvim-orgmode/orgmode/blob/tree-sitter/DOCS.md#changelog')
    if opts.mappings.org.org_increase_date then
      opts.mappings.org.org_timestamp_up = opts.mappings.org.org_increase_date
    end
    if opts.mappings.org.org_decrease_date then
      opts.mappings.org.org_timestamp_down = opts.mappings.org.org_decrease_date
    end
  end

  if opts.org_indent_mode and type(opts.org_indent_mode) == 'string' then
    table.insert(
      messages,
      '"org_indent_mode" is deprecated in favor of "org_startup_indented". Check the documentation about the new option.'
    )
    opts.org_startup_indented = (opts.org_indent_mode == 'indent')
  end

  if #messages > 0 then
    -- Schedule so it gets printed out once whole init.vim is loaded
    vim.schedule(function()
      utils.echo_warning(table.concat(messages, '\n'))
    end)
  end
end

---@return number
function Config:get_week_start_day_number()
  return utils.convert_from_isoweekday(1)
end

---@return number
function Config:get_week_end_day_number()
  return utils.convert_from_isoweekday(7)
end

---@return string|number
function Config:get_agenda_span()
  local span = self.opts.org_agenda_span
  local valid_spans = { 'day', 'month', 'week', 'year' }
  if type(span) == 'string' and not vim.tbl_contains(valid_spans, span) then
    utils.echo_warning(
      string.format(
        'Invalid agenda span %s. Valid spans: %s. Falling back to week',
        span,
        table.concat(valid_spans, ', ')
      )
    )
    span = 'week'
  end
  if type(span) == 'number' and span < 0 then
    utils.echo_warning(
      string.format(
        'Invalid agenda span number %d. Must be 0 or more. Falling back to week',
        span,
        table.concat(valid_spans, ', ')
      )
    )
    span = 'week'
  end
  return span
end

function Config:get_todo_keywords()
  if self.todo_keywords then
    return vim.deepcopy(self.todo_keywords)
  end
  local parse_todo = function(val)
    local value, shortcut = val:match('(.*)%((.)[^%)]*%)$')
    if value and shortcut then
      return { value = value, shortcut = shortcut, custom_shortcut = true }
    end
    return { value = val, shortcut = val:sub(1, 1):lower(), custom_shortcut = false }
  end
  local types = { TODO = {}, DONE = {}, ALL = {}, KEYS = {}, FAST_ACCESS = {}, has_fast_access = false }
  local type = 'TODO'
  local has_separator = vim.tbl_contains(self.opts.org_todo_keywords, '|')
  for i, word in ipairs(self.opts.org_todo_keywords) do
    if word == '|' then
      type = 'DONE'
    else
      if not has_separator and i == #self.opts.org_todo_keywords then
        type = 'DONE'
      end
      local data = parse_todo(word)
      if not types.has_fast_access and data.custom_shortcut then
        types.has_fast_access = true
      end
      table.insert(types[type], data.value)
      table.insert(types.ALL, data.value)
      types.KEYS[data.value] = {
        type = type,
        shortcut = data.shortcut,
        len = data.value:len(),
      }
      table.insert(types.FAST_ACCESS, {
        value = data.value,
        type = type,
        shortcut = data.shortcut,
      })
    end
  end
  self.todo_keywords = types
  return types
end

--- Setup mappings for a given category and buffer
---@param category string Mapping category name (e.g. `agenda`, `capture`, `org`)
---@param buffer number? Buffer id
---@see orgmode.config.mappings
function Config:setup_mappings(category, buffer)
  if category == 'org' and vim.bo.filetype == 'org' and not vim.b.org_old_cr_mapping then
    vim.b.org_old_cr_mapping = utils.get_keymap({
      mode = 'i',
      lhs = '<CR>',
      buffer = buffer,
    })
  end
  if self.opts.mappings.disable_all then
    return
  end

  local map_entries = mappings[category]
  local default_mappings = defaults.mappings[category] or {}
  local user_mappings = vim.tbl_get(self.opts.mappings, category) or {}
  local opts = {}
  if buffer then
    opts.buffer = buffer
  end

  if self.opts.mappings.prefix then
    opts.prefix = self.opts.mappings.prefix
  end

  for name, map_entry in pairs(map_entries) do
    map_entry:attach(default_mappings[name], user_mappings[name], opts)
  end
end

--- Setup the foldlevel for a given org file
function Config:setup_foldlevel()
  if self.org_startup_folded == 'overview' then
    vim.opt_local.foldlevel = 0
  elseif self.org_startup_folded == 'content' then
    vim.opt_local.foldlevel = 1
  elseif self.org_startup_folded == 'showeverything' then
    vim.opt_local.foldlevel = 99
  elseif self.org_startup_folded ~= 'inherit' then
    utils.echo_warning("Invalid option passed for 'org_startup_folded'!")
    self.opts.org_startup_folded = 'overview'
    self:setup_foldlevel()
  end
end

---@return string|nil
function Config:parse_archive_location(file, archive_loc)
  if self:is_archive_file(file) then
    return nil
  end

  archive_loc = archive_loc or self.opts.org_archive_location
  -- TODO: Support archive to headline
  local parts = vim.split(archive_loc, '::')
  local archive_location = vim.trim(parts[1])
  if not archive_location:find('%%s') then
    return vim.fn.fnamemodify(archive_location, ':p')
  end

  local file_path = vim.fn.fnamemodify(file, ':p:h')
  local file_name = vim.fn.fnamemodify(file, ':t')
  local archive_filename = string.format(archive_location, file_name)

  -- If org_archive_location is defined as relative path (example: "archive/%s_archive")
  -- then we need to prepend the file path to it
  local is_full_path = fs.substitute_path(archive_filename)

  if not is_full_path then
    return string.format('%s/%s', file_path, archive_filename)
  end

  return vim.fn.fnamemodify(archive_filename, ':p')
end

function Config:is_archive_file(file)
  return vim.fn.fnamemodify(file, ':e') == 'org_archive'
end

function Config:exclude_tags(tags)
  if vim.tbl_isempty(self.opts.org_tags_exclude_from_inheritance) then
    return tags
  end

  return vim.tbl_filter(function(tag)
    return not vim.tbl_contains(self.opts.org_tags_exclude_from_inheritance, tag)
  end, tags)
end

function Config:get_inheritable_tags(headline)
  if not headline.tags or not self.opts.org_use_tag_inheritance then
    return {}
  end
  if vim.tbl_isempty(self.opts.org_tags_exclude_from_inheritance) then
    return { unpack(headline.tags) }
  end

  return vim.tbl_filter(function(tag)
    return not vim.tbl_contains(self.opts.org_tags_exclude_from_inheritance, tag)
  end, headline.tags)
end

function Config:setup_ts_predicates()
  local todo_keywords = self:get_todo_keywords().KEYS

  vim.treesitter.query.add_predicate('org-is-todo-keyword?', function(match, _, source, predicate)
    local node = match[predicate[2]]
    if node then
      local text = vim.treesitter.get_node_text(node, source)
      return todo_keywords[text] and todo_keywords[text].type == predicate[3] or false
    end

    return false
  end, true)

  vim.treesitter.query.add_directive('org-set-block-language!', function(match, _, bufnr, pred, metadata)
    local lang_node = match[pred[2]]
    if not lang_node then
      return
    end
    local text = vim.treesitter.get_node_text(lang_node, bufnr)
    if not text or vim.trim(text) == '' then
      return
    end

    local map = {
      ['emacs-lisp'] = 'lisp',
      ['js'] = 'javascript',
      ['ts'] = 'typescript',
      ['md'] = 'markdown',
    }

    metadata['injection.language'] = map[text] or text
  end, true)
end

function Config:ts_highlights_enabled()
  if self.ts_hl_enabled ~= nil then
    return self.ts_hl_enabled
  end
  self.ts_hl_enabled = false
  local hl_module = require('nvim-treesitter.configs').get_module('highlight')
  if not hl_module or not hl_module.enable then
    return false
  end
  if hl_module.disable then
    if type(hl_module.disable) == 'function' and hl_module.disable('org', vim.api.nvim_get_current_buf()) then
      return false
    end

    if type(hl_module.disable) == 'table' and vim.tbl_contains(hl_module.disable, 'org') then
      return false
    end
  end
  self.ts_hl_enabled = true
  return self.ts_hl_enabled
end

---@param content table
---@param option? string
---@param prepend_content? any
---@return table
function Config:respect_blank_before_new_entry(content, option, prepend_content)
  if self.opts.org_blank_before_new_entry[option or 'heading'] then
    table.insert(content, 1, prepend_content or '')
  end
  return content
end

---@param amount number
---@return string
function Config:get_indent(amount)
  if self.org_adapt_indentation then
    return string.rep(' ', amount)
  end
  return ''
end

---@param content string|string[]
---@param amount number
---@return string|string[]
function Config:apply_indent(content, amount)
  local indent = self:get_indent(amount)

  if indent == '' then
    return content
  end

  if type(content) ~= 'table' then
    return indent .. content
  end

  for i, line in ipairs(content) do
    content[i] = indent .. line
  end
  return content
end

---@param bufnr number
---@return boolean
function Config:hide_leading_stars(bufnr)
  if self.org_hide_leading_stars then
    return true
  end

  if vim.b[bufnr].org_indent_mode and self.org_indent_mode_turns_on_hiding_stars then
    return true
  end

  return false
end

---@type OrgConfig
instance = Config:new()
return instance
