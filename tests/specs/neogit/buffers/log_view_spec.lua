local async = require("neogit.lib.async")
local git_remote = require("neogit.lib.git.remote")
local subject = require("neogit.buffers.log_view")

local function wait_for(task)
  assert.is_true(vim.wait(1000, function()
    return task:done()
  end, 5))
end

local function fake_buffer()
  local buffer = {
    headers = {},
    renders = 0,
    valid = true,
  }

  buffer.ui = {
    get_commit_under_cursor = function()
      return nil
    end,
    find_component_by_oid = function()
      return nil
    end,
    render = function()
      buffer.renders = buffer.renders + 1
    end,
  }

  function buffer:is_valid()
    return self.valid
  end

  function buffer:win_call(callback)
    callback()
  end

  function buffer:save_view()
    return {}
  end

  function buffer:restore_view() end

  function buffer:update_header(header)
    table.insert(self.headers, header)
  end

  return buffer
end

local function log_view(buffer, query)
  return setmetatable({
    buffer = buffer,
    commits = {},
    header = "old header",
    internal_args = {},
    query_func = query,
    refresh_lock = async.control.Semaphore.new(1),
    remotes = {},
  }, subject)
end

describe("buffers.log_view redraw", function()
  local original_remote_list

  before_each(function()
    original_remote_list = git_remote.list
    git_remote.list = function()
      return {}
    end
  end)

  after_each(function()
    git_remote.list = original_remote_list
  end)

  it("requests uncached log data", function()
    local uncached
    local buffer = fake_buffer()
    local view = log_view(buffer, function(_, bypass_cache)
      uncached = bypass_cache
      return {}, "new header"
    end)

    local task = view:redraw()
    wait_for(task)

    assert.is_true(uncached)
    assert.are.equal("new header", view.header)
    assert.are.same({ "new header" }, buffer.headers)
    assert.are.equal(1, buffer.renders)
    assert.are.equal(1, view.refresh_lock.permits)
  end)

  it("releases its permit when closed during a query", function()
    local resume_query
    local suspend_query = async.wrap(function(callback)
      resume_query = callback
    end, 1)
    local buffer = fake_buffer()
    local view = log_view(buffer, function()
      suspend_query()
      return {}, "new header"
    end)

    local task = view:redraw()
    assert.is_function(resume_query)

    view.buffer = nil
    resume_query()
    wait_for(task)

    assert.are.equal(0, buffer.renders)
    assert.are.equal(1, view.refresh_lock.permits)
  end)
end)
