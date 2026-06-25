---@class TaskStore
---@field state TaskStoreState
---@field options TaskStoreOptions
local M = {}

---@class TaskStoreState
local default_state = {
  options = {},
  ---@type nil | string
  file = nil,
  ---@alias Tasks string[]
  tasks = {}
}

function M:create_file()
  -- Resolve to an absolute path so the file is independent of the cwd.
  local name = vim.fn.fnamemodify(self.options.file_name, ":p")

  -- Adopt an existing file rather than truncating it.
  if vim.uv.fs_stat(name) then
    return name
  end

  local f = io.open(name, "w")
  assert(f, "couldn't create " .. name)
  f:write("")
  f:close()
  return name
end

---@param force? boolean force creation of file
function M:find_file(force)
  local options = self.options
  local match, file = next(vim.fs.find({options.file_name}, {upward=true, limit=1}))

  if match == nil and force then
    file = self:create_file()
  end

  if match == nil then
    return nil
  end

  local is_readable = vim.fn.filereadable(file) == 1
  assert(is_readable, string.format("file not %s readable", file))

  return file
end

function M:import_file()
  self.file = self:find_file()
  return self.file and vim.fn.readfile(self.file) or nil
end

--- Re-read tasks from disk in place for the render path. A file unreachable
--- from the cwd but still on disk keeps the tasks (a transient miss must not
--- drop the list); a deleted file clears them to mirror it.
function M:reload()
  local file = self:find_file()

  if file then
    self.file = file
    self.tasks = vim.fn.readfile(file)
  elseif self.file and not vim.uv.fs_stat(self.file) then
    self.file = nil
    self.tasks = {}
  end

  return self
end

function M:sync(force)
  -- Forget a deleted file so it is recreated below instead of erroring.
  if self.file and not vim.uv.fs_stat(self.file) then
    self.file = nil
  end

  if not self.file and (self.options.auto_create_file or force) then
    self.file = self:create_file()
    assert(self.file, "file not set despite saving")
  elseif not self.file then
    return self
  end

  -- 0 (not writable) is still truthy in Lua, so compare explicitly.
  if vim.fn.filewritable(self.file) ~= 1 then
    error(string.format("Cannot write file %s", self.file))
  end

  -- Write to a temp file and rename it over the target so a reader never sees a
  -- truncated file. Resolve symlinks first and write through to the real path,
  -- so a symlinked tasks file keeps its link instead of being replaced.
  local target = vim.uv.fs_realpath(self.file) or self.file
  local mode = (vim.uv.fs_stat(target) or {}).mode
  local tmp = string.format("%s.%d.tmp", target, vim.fn.getpid())
  vim.fn.writefile(self.tasks, tmp)
  if mode then pcall(vim.uv.fs_chmod, tmp, mode % 4096) end
  local ok, err = vim.uv.fs_rename(tmp, target)
  if not ok then
    vim.uv.fs_unlink(tmp)
    error(string.format("Cannot write file %s: %s", target, err))
  end

  return self
end

function M:current()
  return self.tasks[1]
end

function M:get()
  return self.tasks
end

---@param tasks Tasks
function M:set(tasks)
  self.tasks = tasks
  return self:sync()
end

function M:count()
  return #self:get()
end

function M:add(str, to_front)
  if to_front then
    table.insert(self.tasks, 1, str)
  else
    table.insert(self.tasks, str)
  end

  return self:sync()
end

function M:add_next(str)
  table.insert(self.tasks, 2, str)
  return self:sync()
end

function M:shift()
  return table.remove(self.tasks, 1), self:sync()
end

---initialize task store
M.init = function(options)
  ---@type TaskStoreState
  local state = {
    options = options,
    tasks = {}
  }

  local o = vim.tbl_deep_extend("keep", state, default_state)
  local instance = setmetatable(o, { __index = M })

  -- Load without writing back: init runs on every render, so writing here could
  -- overwrite the file with an empty read. Only mutations write.
  instance.tasks = instance:import_file() or {}
  return instance
end

function M:has_items()
  return self:count() > 0
end

return M
