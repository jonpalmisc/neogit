local M = {}

local git = require("neogit.lib.git")
local util = require("neogit.lib.util")

local LogViewBuffer = require("neogit.buffers.log_view")
local ReflogViewBuffer = require("neogit.buffers.reflog_view")
local FuzzyFinderBuffer = require("neogit.buffers.fuzzy_finder")

local a = require("neogit.lib.async")

--- Runs `git log` and parses the commits
---@param popup table Contains the argument list
---@param flags table extra CLI flags like --branches or --remotes
---@return CommitLogEntry[]
local function commits(popup, flags)
  return git.log.list(
    util.merge(popup:get_arguments(), flags),
    popup:get_internal_arguments().graph,
    popup.state.env.files,
    false,
    popup:get_internal_arguments().color
  )
end

---@param popup table
---@param flags table|fun(): table
---@param header string|fun(flags: table): string
---@return fun(offset: number): CommitLogEntry[], string
local function log_query(popup, flags, header)
  return function(offset)
    local resolved_flags = type(flags) == "function" and flags() or flags
    local query_flags = offset > 0 and util.merge(resolved_flags, { ("--skip=%s"):format(offset) })
      or resolved_flags
    local resolved_header = type(header) == "function" and header(resolved_flags) or header

    return commits(popup, query_flags), resolved_header
  end
end

---@param popup table
---@param flags table|fun(): table
---@param header string|fun(flags: table): string
local function open_log(popup, flags, header)
  LogViewBuffer.new(popup:get_internal_arguments(), popup.state.env.files, log_query(popup, flags, header))
    :open()
end

function M.log_current(popup)
  open_log(popup, {}, function()
    return "Commits in " .. (git.branch.current() or ("(detached) " .. git.log.message("HEAD")))
  end)
end

function M.log_related(popup)
  open_log(popup, git.branch.related, function(flags)
    return "Commits in " .. table.concat(flags, ", ")
  end)
end

function M.log_head(popup)
  open_log(popup, { "HEAD" }, "Commits in HEAD")
end

function M.log_local_branches(popup)
  open_log(popup, function()
    return { git.branch.is_detached() and "" or "HEAD", "--branches" }
  end, "Commits in --branches")
end

function M.log_other(popup)
  local options = util.merge(git.refs.list_branches(), git.refs.heads(), git.refs.list_tags())
  local branch = FuzzyFinderBuffer.new(options):open_async()
  if branch then
    open_log(popup, { branch }, "Commits in " .. branch)
  end
end

function M.log_all_branches(popup)
  open_log(popup, function()
    return { git.branch.is_detached() and "" or "HEAD", "--branches", "--remotes" }
  end, "Commits in --branches --remotes")
end

function M.log_all_references(popup)
  open_log(popup, function()
    return { git.branch.is_detached() and "" or "HEAD", "--all" }
  end, "Commits in --all")
end

function M.reflog_current(popup)
  ReflogViewBuffer.new(
    git.reflog.list(git.branch.current(), popup:get_arguments()),
    "Reflog for " .. git.branch.current()
  )
    :open()
end

function M.reflog_head(popup)
  ReflogViewBuffer.new(git.reflog.list("HEAD", popup:get_arguments()), "Reflog for HEAD"):open()
end

function M.reflog_other(popup)
  local branch = FuzzyFinderBuffer.new(git.refs.list_local_branches()):open_async()
  if branch then
    ReflogViewBuffer.new(git.reflog.list(branch, popup:get_arguments()), "Reflog for " .. branch):open()
  end
end

-- TODO: Prefill the fuzzy finder with the filepath under cursor, if there is one
---comment
function M.limit_to_files()
  local fn = function(popup, option)
    if option.value ~= "" then
      popup.state.env.files = nil
      return ""
    end

    local eventignore = vim.o.eventignore
    vim.o.eventignore = "WinLeave"
    local files = FuzzyFinderBuffer.new(git.files.all_tree { with_dir = true }):open_async {
      allow_multi = true,
      refocus_status = false,
    }
    vim.o.eventignore = eventignore

    if not files or vim.tbl_isempty(files) then
      popup.state.env.files = nil
      return ""
    end

    popup.state.env.files = files
    files = util.map(files, function(file)
      return string.format([[ "%s"]], file)
    end)

    return table.concat(files, "")
  end

  return a.wrap(fn, 2)
end

return M
