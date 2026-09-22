local Buffer = require("neogit.lib.buffer")
local ui = require("neogit.buffers.log_view.ui")
local config = require("neogit.config")
local popups = require("neogit.popups")
local commit_view_maps = require("neogit.config").get_reversed_commit_view_maps()
local CommitViewBuffer = require("neogit.buffers.commit_view")
local util = require("neogit.lib.util")
local a = require("neogit.lib.async")
local notification = require("neogit.lib.notification")
local git = require("neogit.lib.git")
local Watcher = require("neogit.watcher")
local logger = require("neogit.logger")

---@class LogViewBuffer
---@field commits CommitLogEntry[]
---@field remotes string[]
---@field internal_args table
---@field files string[]
---@field buffer Buffer
---@field header string
---@field query_func fun(offset: number): CommitLogEntry[], string
---@field refresh_lock Semaphore
---@field root string
local M = {}
M.__index = M

---Opens a popup for selecting a commit
---@param internal_args table|nil
---@param files string[]|nil list of files to filter by
---@param query_func fun(offset: number): CommitLogEntry[], string
---@return LogViewBuffer
function M.new(internal_args, files, query_func)
  local commits, header = query_func(0)
  local instance = {
    files = files,
    commits = commits,
    remotes = git.remote.list(),
    internal_args = internal_args,
    query_func = query_func,
    buffer = nil,
    refresh_lock = a.control.Semaphore.new(1),
    header = header,
    root = git.repo.worktree_root,
  }

  setmetatable(instance, M)

  return instance
end

local function commit_count(commits)
  return #util.filter_map(commits, function(commit)
    if commit.oid then
      return 1
    end
  end)
end

function M:commit_count()
  return commit_count(self.commits)
end

function M:close()
  if self.buffer then
    self.buffer:close()
    self.buffer = nil
  end

  Watcher.instance(self.root):unregister(self)
  M.instance = nil
end

---@return boolean
function M.is_open()
  return (M.instance and M.instance.buffer and M.instance.buffer:is_visible()) == true
end

M.redraw = a.void(function(self)
  local permit = self.refresh_lock:acquire()

  if not self.buffer or not self.buffer:is_valid() then
    permit:forget()
    return
  end

  logger.debug("[LOG] Beginning redraw")

  local active_oid, view
  self.buffer:win_call(function()
    active_oid = self.buffer.ui:get_commit_under_cursor()
    view = self.buffer:save_view()
  end)
  local previous_count = self:commit_count()
  local commits, header = self.query_func(0)
  local refreshed_count = commit_count(commits)

  while refreshed_count < previous_count do
    local additional = self.query_func(refreshed_count)
    local additional_count = commit_count(additional)
    if additional_count == 0 then
      break
    end

    commits = util.merge(commits, additional)
    refreshed_count = refreshed_count + additional_count
  end

  self.commits = commits
  self.header = header
  self.remotes = git.remote.list()
  self.buffer.ui:render(unpack(ui.View(self.commits, self.remotes, self.internal_args)))
  self.buffer:update_header(self.header)

  if view then
    local item = active_oid and self.buffer.ui:find_component_by_oid(active_oid) or nil
    self.buffer:restore_view(view, item and item.first or nil)
  end

  permit:forget()
  logger.info("[LOG] Redraw complete")
end)

function M:id()
  return "LogViewBuffer"
end

function M:open()
  if M.is_open() then
    M.instance.buffer:focus()
    return
  end

  M.instance = self
  local status_maps = config.get_reversed_status_maps()

  self.buffer = Buffer.create {
    name = "NeogitLogView",
    filetype = "NeogitLogView",
    kind = config.values.log_view.kind,
    context_highlight = false,
    on_detach = function()
      Watcher.instance(self.root):unregister(self)
    end,
    header = self.header,
    scroll_header = false,
    active_item_highlight = true,
    status_column = not config.values.disable_signs and "" or nil,
    mappings = {
      v = {
        [popups.mapping_for("CherryPickPopup")] = popups.open("cherry_pick", function(p)
          p { commits = self.buffer.ui:get_commits_in_selection() }
        end),
        [popups.mapping_for("BranchPopup")] = popups.open("branch", function(p)
          p { commits = self.buffer.ui:get_commits_in_selection() }
        end),
        [popups.mapping_for("CommitPopup")] = popups.open("commit", function(p)
          p { commit = self.buffer.ui:get_commit_under_cursor() }
        end),
        [popups.mapping_for("FetchPopup")] = popups.open("fetch"),
        [popups.mapping_for("MergePopup")] = popups.open("merge", function(p)
          p { commit = self.buffer.ui:get_commit_under_cursor() }
        end),
        [popups.mapping_for("PushPopup")] = popups.open("push", function(p)
          p { commit = self.buffer.ui:get_commit_under_cursor() }
        end),
        [popups.mapping_for("RebasePopup")] = popups.open("rebase", function(p)
          p { commit = self.buffer.ui:get_commit_under_cursor() }
        end),
        [popups.mapping_for("RemotePopup")] = popups.open("remote"),
        [popups.mapping_for("RevertPopup")] = popups.open("revert", function(p)
          p { commits = self.buffer.ui:get_commits_in_selection() }
        end),
        [popups.mapping_for("ResetPopup")] = popups.open("reset", function(p)
          p { commit = self.buffer.ui:get_commit_under_cursor() }
        end),
        [popups.mapping_for("TagPopup")] = popups.open("tag", function(p)
          p { commit = self.buffer.ui:get_commit_under_cursor() }
        end),
        [popups.mapping_for("PullPopup")] = popups.open("pull"),
        [popups.mapping_for("BisectPopup")] = popups.open("bisect", function(p)
          p { commits = self.buffer.ui:get_commits_in_selection() }
        end),
        [popups.mapping_for("DiffPopup")] = popups.open("diff", function(p)
          local items = self.buffer.ui:get_ordered_commits_in_selection()
          p {
            section = { name = "log" },
            item = { name = items },
          }
        end),
      },
      n = {
        [commit_view_maps["OpenCommitLinkInBrowser"]] = function()
          if not vim.ui.open then
            notification.warn("Requires Neovim >= 0.10")
            return
          end

          local oid = self.buffer.ui:get_commit_under_cursor()
          if not oid then
            return
          end

          local uri = git.remote.commit_url(oid)
          if uri then
            notification.info(("Opening %q in your browser."):format(uri))
            vim.ui.open(uri)
          else
            notification.warn("Couldn't determine commit URL to open")
          end
        end,
        [popups.mapping_for("BisectPopup")] = popups.open("bisect", function(p)
          p { commits = { self.buffer.ui:get_commit_under_cursor() } }
        end),
        [popups.mapping_for("CherryPickPopup")] = popups.open("cherry_pick", function(p)
          p { commits = { self.buffer.ui:get_commit_under_cursor() } }
        end),
        [popups.mapping_for("BranchPopup")] = popups.open("branch", function(p)
          p { commits = { self.buffer.ui:get_commit_under_cursor() } }
        end),
        [popups.mapping_for("CommitPopup")] = popups.open("commit", function(p)
          p { commit = self.buffer.ui:get_commit_under_cursor() }
        end),
        [popups.mapping_for("FetchPopup")] = popups.open("fetch"),
        [popups.mapping_for("MergePopup")] = popups.open("merge", function(p)
          p { commit = self.buffer.ui:get_commit_under_cursor() }
        end),
        [popups.mapping_for("PushPopup")] = popups.open("push", function(p)
          p { commit = self.buffer.ui:get_commit_under_cursor() }
        end),
        [popups.mapping_for("RebasePopup")] = popups.open("rebase", function(p)
          p { commit = self.buffer.ui:get_commit_under_cursor() }
        end),
        [popups.mapping_for("RemotePopup")] = popups.open("remote"),
        [popups.mapping_for("RevertPopup")] = popups.open("revert", function(p)
          p { commits = { self.buffer.ui:get_commit_under_cursor() } }
        end),
        [popups.mapping_for("ResetPopup")] = popups.open("reset", function(p)
          p { commit = self.buffer.ui:get_commit_under_cursor() }
        end),
        [popups.mapping_for("TagPopup")] = popups.open("tag", function(p)
          p { commit = self.buffer.ui:get_commit_under_cursor() }
        end),
        [popups.mapping_for("DiffPopup")] = popups.open("diff", function(p)
          local item = self.buffer.ui:get_commit_under_cursor()
          p {
            section = { name = "log" },
            item = { name = item },
          }
        end),
        [popups.mapping_for("PullPopup")] = popups.open("pull"),
        [status_maps["YankSelected"]] = function()
          local yank = self.buffer.ui:get_commit_under_cursor()
          if yank then
            yank = string.format("'%s'", yank)
            vim.cmd.let("@+=" .. yank)
            vim.cmd.echo(yank)
          else
            vim.cmd("echo ''")
          end
        end,
        ["<esc>"] = require("neogit.lib.ui.helpers").close_topmost(self),
        [status_maps["Close"]] = require("neogit.lib.ui.helpers").close_topmost(self),
        [status_maps["GoToFile"]] = function()
          local commit = self.buffer.ui:get_commit_under_cursor()
          if commit then
            CommitViewBuffer.new(commit, self.files):open()
          end
        end,
        [status_maps["PeekFile"]] = function()
          local commit = self.buffer.ui:get_commit_under_cursor()
          if commit then
            local buffer = CommitViewBuffer.new(commit, self.files):open()
            buffer.buffer:win_call(vim.cmd, "normal! gg")

            self.buffer:focus()
          end
        end,
        [status_maps["OpenOrScrollDown"]] = function()
          local commit = self.buffer.ui:get_commit_under_cursor()
          if commit then
            CommitViewBuffer.open_or_scroll_down(commit, self.files)
          end
        end,
        [status_maps["OpenOrScrollUp"]] = function()
          local commit = self.buffer.ui:get_commit_under_cursor()
          if commit then
            CommitViewBuffer.open_or_scroll_up(commit, self.files)
          end
        end,
        [status_maps["PeekUp"]] = function()
          -- Open prev fold
          pcall(vim.cmd, "normal! zc")

          vim.cmd("normal! k")
          for _ = vim.fn.line("."), 0, -1 do
            if vim.fn.foldlevel(".") > 0 then
              break
            end

            vim.cmd("normal! k")
          end

          if CommitViewBuffer.is_open() then
            local commit = self.buffer.ui:get_commit_under_cursor()
            if commit then
              CommitViewBuffer.instance:update(commit, self.files)
            end
          else
            pcall(vim.cmd, "normal! zo")
            vim.cmd("normal! zz")
          end
        end,
        [status_maps["PeekDown"]] = function()
          pcall(vim.cmd, "normal! zc")

          vim.cmd("normal! j")
          for _ = vim.fn.line("."), vim.fn.line("$"), 1 do
            if vim.fn.foldlevel(".") > 0 then
              break
            end

            vim.cmd("normal! j")
          end

          if CommitViewBuffer.is_open() then
            local commit = self.buffer.ui:get_commit_under_cursor()
            if commit then
              CommitViewBuffer.instance:update(commit, self.files)
            end
          else
            pcall(vim.cmd, "normal! zo")
            vim.cmd("normal! zz")
          end
        end,
        ["+"] = a.void(function()
          local permit = self.refresh_lock:acquire()

          local commits = self.query_func(self:commit_count())
          self.commits = util.merge(self.commits, commits)
          self.buffer.ui:render(unpack(ui.View(self.commits, self.remotes, self.internal_args)))

          permit:forget()
        end),
        ["<tab>"] = function()
          pcall(vim.cmd, "normal! za")
        end,
        ["j"] = function()
          if vim.v.count > 0 then
            vim.cmd("norm! " .. vim.v.count .. "j")
          else
            vim.cmd("norm! j")
          end

          while self.buffer:get_current_line()[1]:sub(1, 1) == " " do
            if vim.fn.line(".") == vim.fn.line("$") then
              break
            end

            vim.cmd("norm! j")
          end
        end,
        ["k"] = function()
          if vim.v.count > 0 then
            vim.cmd("norm! " .. vim.v.count .. "k")
          else
            vim.cmd("norm! k")
          end

          while self.buffer:get_current_line()[1]:sub(1, 1) == " " do
            if vim.fn.line(".") == 1 then
              break
            end

            vim.cmd("norm! k")
          end
        end,
      },
    },
    render = function()
      return ui.View(self.commits, self.remotes, self.internal_args)
    end,
    after = function(buffer)
      Watcher.instance(self.root):register(self)
      -- First line is empty, so move cursor to second line.
      buffer:move_cursor(2)
    end,
  }
end

return M
